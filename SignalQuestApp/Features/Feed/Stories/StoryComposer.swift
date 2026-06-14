import SwiftUI
import PhotosUI

@MainActor
final class StoryComposerViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var selectedItem: PhotosPickerItem?
    @Published var previewImage: UIImage?
    @Published var isSending = false
    @Published var errorMessage: String?
    @Published var didPublish = false
    /// Durée d'affichage de la story (autorisée : 5/10/15 s).
    @Published var displayDuration: Int = 10

    /// Données JPEG de l'image choisie, prêtes à téléverser.
    private var pickedImageData: Data?
    private let service: StoriesServicing
    init(service: StoriesServicing) { self.service = service }

    func loadPickerImage() async {
        guard let item = selectedItem else { return }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                previewImage = image
                // On normalise en JPEG pour l'upload (le picker peut fournir HEIC).
                pickedImageData = image.jpegData(compressionQuality: 0.85) ?? data
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func publish() async {
        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard caption != nil || pickedImageData != nil else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            // 1) Téléversement du média s'il y en a un → URLs renvoyées par le backend.
            var mediaUrl: URL?
            var thumbnailUrl: URL?
            if let data = pickedImageData {
                let upload = try await service.uploadMedia(data: data)
                mediaUrl = upload.url
                thumbnailUrl = upload.thumbnailUrl
            }
            // 2) Création de la story avec le média téléversé.
            _ = try await service.create(
                text: caption,
                mediaUrl: mediaUrl,
                thumbnailUrl: thumbnailUrl,
                mediaKind: mediaUrl != nil ? "image" : nil,
                displayDurationSeconds: displayDuration
            )
            didPublish = true
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}

struct StoryComposer: View {
    @StateObject private var model: StoryComposerViewModel
    @Environment(\.dismiss) private var dismiss

    init(service: StoriesServicing) {
        _model = StateObject(wrappedValue: StoryComposerViewModel(service: service))
    }

    var body: some View {
        let previewImage = model.previewImage
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: SQSpace.lg + 2) {
                    SQSheetHandle()
                    Text("Nouvelle story")
                        .sqKicker()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    PhotosPicker(selection: $model.selectedItem, matching: .images) {
                        ZStack {
                            if let image = previewImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Rectangle()
                                    .fill(SQColor.surfaceMuted)
                                VStack(spacing: SQSpace.sm) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 40))
                                    Text("Ajouter un média")
                                        .font(SQType.subhead)
                                }
                                .foregroundStyle(SQColor.labelSecondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous)
                                .stroke(SQColor.separator, lineWidth: 1.5)
                        }
                    }
                    .buttonStyle(SQPressButtonStyle())
                    .onChange(of: model.selectedItem) { _, _ in
                        Task { await model.loadPickerImage() }
                    }

                    TextField("Une légende ?", text: $model.text, axis: .vertical)
                        .lineLimit(2...6)
                        .textFieldStyle(SQTextFieldStyle())

                    HStack(spacing: SQSpace.sm) {
                        Label("Durée", systemImage: "timer")
                            .font(SQType.subhead)
                            .foregroundStyle(SQColor.labelSecondary)
                        Spacer()
                        Picker("Durée d'affichage", selection: $model.displayDuration) {
                            ForEach([5, 10, 15], id: \.self) { seconds in
                                Text("\(seconds)s").tag(seconds)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(SQColor.danger)
                    }

                    GradientButton("Publier", systemImage: "paperplane.fill", isBusy: model.isSending) {
                        Task {
                            await model.publish()
                            if model.didPublish { dismiss() }
                        }
                    }
                }
                .padding(SQSpace.xl)
            }
            .signalQuestBackground()
            .navigationTitle("Nouvelle story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Annuler") { dismiss() }
                        .tint(SQColor.brandRed)
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
