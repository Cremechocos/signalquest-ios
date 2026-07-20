import SwiftUI
import UniformTypeIdentifiers

/// Écran d'import de logs radio (« eNB Analytics » CSV / NetMonster `.ntm`) :
/// sélection d'un fichier → résolution des cellules contre les sites connus →
/// l'utilisateur enregistre les identifications rattachables. Le compte étant partagé,
/// elles apparaissent aussi dans « Mes identifications » sur Android.
struct RadioLogImportView: View {
    @StateObject private var model: RadioLogImportViewModel
    @State private var showPicker = false

    init(service: RadioLogImportServicing) {
        _model = StateObject(wrappedValue: RadioLogImportViewModel(service: service))
    }

    /// Types acceptés : CSV + texte brut (le `.ntm` déclaré dans Info.plist conforme à
    /// `public.plain-text` est ainsi proposé) + le type importé explicite en filet de sécurité.
    private var allowedTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .plainText, .text]
        if let ntm = UTType("fr.signalquest.ntm") { types.append(ntm) }
        return types
    }

    var body: some View {
        List {
            Section {
                Button {
                    showPicker = true
                } label: {
                    Label("Choisir un fichier (.csv, .ntm)", systemImage: "square.and.arrow.down")
                }
                .disabled(model.isBusy)
            } footer: {
                Text("Exports « eNB Analytics » (CSV ExportV5) ou NetMonster (.ntm). Les cellules reconnues sont rattachées aux antennes connues, puis identifiées automatiquement (ECI/PCI).")
            }

            switch model.phase {
            case .idle:
                EmptyView()
            case .working(let label):
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(label)
                    }
                }
            case .preview(let preview):
                previewSection(preview)
            case .done(let outcome):
                Section {
                    Label("\(outcome.submitted) identification(s) enregistrée(s)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    if outcome.failed > 0 {
                        Label("\(outcome.failed) échec(s)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            case .error(let message):
                Section {
                    Label(message, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Importer des logs")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: allowedTypes) { result in
            model.handlePicked(result)
        }
    }

    @ViewBuilder
    private func previewSection(_ preview: RadioLogImportPreview) -> some View {
        Section {
            LabeledContent("Fichier", value: preview.fileName)
            LabeledContent("Cellules uniques", value: "\(preview.parsedRows)")
            LabeledContent("Rattachables à un site", value: "\(preview.matchedCount)")
            if preview.unmatchedCount > 0 {
                LabeledContent("Sans site connu", value: "\(preview.unmatchedCount)")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Aperçu")
        } footer: {
            Text("Seules les cellules rattachées à un site connu sont enregistrées. Les autres restent à identifier ultérieurement.")
        }

        if !preview.writableRows.isEmpty {
            Section {
                Button {
                    model.confirm(preview.writableRows)
                } label: {
                    Label("Enregistrer \(preview.writableRows.count) identification(s)", systemImage: "checkmark.circle.fill")
                }
                .disabled(model.isBusy)
            }
        }
    }
}

@MainActor
final class RadioLogImportViewModel: ObservableObject {
    enum Phase {
        case idle
        case working(String)
        case preview(RadioLogImportPreview)
        case done(RadioLogImportOutcome)
        case error(String)
    }

    @Published private(set) var phase: Phase = .idle

    var isBusy: Bool { if case .working = phase { return true } else { return false } }

    private let service: RadioLogImportServicing

    init(service: RadioLogImportServicing) {
        self.service = service
    }

    func handlePicked(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            phase = .error(error.localizedDescription)
        case .success(let url):
            resolve(url: url)
        }
    }

    private func resolve(url: URL) {
        phase = .working("Lecture et résolution du fichier…")
        Task {
            do {
                let (fileName, content) = try Self.readFile(url)
                let preview = try await service.resolve(fileName: fileName, content: content)
                phase = .preview(preview)
            } catch {
                // APIError conforme à LocalizedError → message déjà localisé (FR).
                phase = .error(error.localizedDescription)
            }
        }
    }

    func confirm(_ rows: [ResolvedRadioLogRow]) {
        phase = .working("Enregistrement des identifications…")
        Task {
            let outcome = await service.confirm(rows: rows)
            phase = .done(outcome)
        }
    }

    // MARK: - Lecture fichier

    private static func readFile(_ url: URL) throws -> (name: String, content: String) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        // Les exports peuvent être en UTF-8 ou en Latin-1 (accents FR) → on tente les deux.
        let content = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        return (url.lastPathComponent, content)
    }
}
