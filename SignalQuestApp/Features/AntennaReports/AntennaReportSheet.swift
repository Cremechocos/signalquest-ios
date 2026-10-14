import SwiftUI

/// Formulaire d'émission d'un signalement sur une antenne, présenté depuis la
/// fiche antenne (`AntennaDetailSheet`) : sections Halo, envoi en bouton
/// principal en bas.
struct AntennaReportSheet: View {
    let siteId: String
    let siteLabel: String
    /// Azimuts connus du site (degrés arrondis) proposés comme « secteur concerné ».
    let availableSectors: [Int]
    let service: AntennaReportsServicing
    /// Site partagé (Crozon, zone blanche) : seul cas où « opérateur porteur
    /// incorrect » a un sens, avec la liste des opérateurs possibles.
    let leaderReport: AntennaLeaderReport?
    /// Réseau affiché sur la fiche : donne la numérotation des secteurs (« Secteur 2 · 120° »).
    let operatorName: String?

    @Environment(\.dismiss) private var dismiss

    @State private var reportType: AntennaReportType
    @State private var suggestedLeader: String?
    @State private var reason: String = ""
    @State private var currentValue: String = ""
    @State private var suggestedValue: String = ""
    @State private var sector: Int?
    @State private var isBusy = false
    @State private var error: String?
    @State private var duplicateMessage: String?
    /// Identité de cette feuille pour l'idempotence : stable d'un envoi à l'autre.
    @State private var submissionID = UUID()

    init(
        siteId: String,
        siteLabel: String,
        availableSectors: [Int],
        service: AntennaReportsServicing,
        leaderReport: AntennaLeaderReport? = nil,
        operatorName: String? = nil,
        initialType: AntennaReportType = .other
    ) {
        self.siteId = siteId
        self.siteLabel = siteLabel
        self.availableSectors = availableSectors
        self.service = service
        self.leaderReport = leaderReport
        self.operatorName = operatorName
        _reportType = State(initialValue: leaderReport == nil && initialType == .incorrectLeader ? .other : initialType)
    }

    private var availableTypes: [AntennaReportType] {
        AntennaReportType.allCases.filter { $0 != .incorrectLeader || leaderReport != nil }
    }

    private var isLeaderReport: Bool { reportType == .incorrectLeader && leaderReport != nil }

    /// « Autre problème » n'a aucun champ qui le décrive : la précision est le seul contenu.
    private var needsReason: Bool {
        reportType == .other && reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        !isBusy && !needsReason && !(isLeaderReport && suggestedLeader == nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MapSheetHeader(
                    title: String(localized: "Signaler un problème"),
                    subtitle: String(localized: "Site \(siteLabel)"),
                    closeIdentifier: "antennaReport.form.close"
                ) { dismiss() }

                formSection("Problème", footer: "Ton signalement part à l’équipe de modération, qui pourra te répondre.") {
                    pickerRow("Type", value: reportType.label, identifier: "antennaReport.form.type") {
                        Picker(selection: $reportType) {
                            ForEach(availableTypes) { type in
                                Label(type.label, systemImage: type.systemImage).tag(type)
                            }
                        } label: {
                            Text("Type de problème")
                        }
                    }
                }

                if isLeaderReport, let leaderReport {
                    formSection(
                        "Opérateur porteur",
                        footer: leaderReport.sharingKind == "crozon"
                            ? "Site partagé entre SFR et Bouygues Telecom : l’un des deux le porte pour l’autre."
                            : "Site en zone blanche : un seul opérateur le porte pour tous les autres."
                    ) {
                        if let current = leaderReport.currentLeader {
                            HStack {
                                Text("Opérateur affiché").foregroundStyle(SQColor.label)
                                Spacer(minLength: SQSpace.sm)
                                Text(verbatim: AntennaLeaderReport.displayName(current))
                                    .foregroundStyle(SQColor.labelSecondary)
                            }
                            .font(SQType.body)
                            .padding(.horizontal, SQSpace.md)
                            .frame(minHeight: 48)
                            Divider().overlay(SQColor.separator).padding(.leading, SQSpace.md)
                        }
                        pickerRow("Opérateur qui porte le site",
                                  value: suggestedLeader.map(AntennaLeaderReport.displayName) ?? String(localized: "À choisir"),
                                  identifier: "antennaReport.form.leader") {
                            Picker(selection: $suggestedLeader) {
                                Text("À choisir").tag(String?.none)
                                ForEach(leaderReport.choices, id: \.self) { key in
                                    Text(verbatim: AntennaLeaderReport.displayName(key)).tag(String?.some(key))
                                }
                            } label: {
                                Text("Opérateur qui porte le site")
                            }
                        }
                    }
                }

                if reportType.suggestsValues {
                    formSection("Correction proposée · facultatif") {
                        fieldRow("Valeur actuelle affichée", text: $currentValue, identifier: "antennaReport.form.current")
                        Divider().overlay(SQColor.separator).padding(.leading, SQSpace.md)
                        fieldRow("Valeur correcte selon toi", text: $suggestedValue, identifier: "antennaReport.form.suggested")
                    }
                }

                if !availableSectors.isEmpty {
                    formSection("Secteur concerné · facultatif") {
                        pickerRow("Secteur", value: selectedSectorLabel, identifier: "antennaReport.form.sector") {
                            Picker(selection: $sector) {
                                Text("Non précisé").tag(Int?.none)
                                ForEach(Array(availableSectors.enumerated()), id: \.element) { index, deg in
                                    Text(sectorLabel(index: index, azimuth: deg)).tag(Int?.some(deg))
                                }
                            } label: {
                                Text("Secteur")
                            }
                        }
                    }
                }

                formSection(reportType == .other ? "Précisions · obligatoire" : "Précisions · facultatif") {
                    TextField("Décris ce qui ne va pas", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.label)
                        .padding(SQSpace.md)
                        .frame(minHeight: 84, alignment: .topLeading)
                        .accessibilityIdentifier("antennaReport.form.reason")
                }

                if let duplicateMessage {
                    Label(duplicateMessage, systemImage: "checkmark.circle")
                        .font(SQType.caption)
                        .foregroundStyle(OutageTint.resolvedInk)
                        .padding(SQSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sqSurface(SQColor.successSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .accessibilityIdentifier("antennaReport.form.duplicate")
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .padding(SQSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sqSurface(SQColor.dangerSoft, in: RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                        .accessibilityIdentifier("antennaReport.form.error")
                }
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.lg)
            .padding(.bottom, SQSpace.xl)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            GradientButton(String(localized: "Envoyer le signalement"), systemImage: "paperplane.fill", isBusy: isBusy) {
                Task { await send() }
            }
            .disabled(!canSend)
            .accessibilityIdentifier("antennaReport.form.send")
            .padding(.horizontal, SQSpace.lg)
            .padding(.top, SQSpace.sm)
            .padding(.bottom, SQSpace.sm)
            .background(SQColor.surface.ignoresSafeArea(edges: .bottom))
        }
        .background(SQColor.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// « Secteur 2 · 120° » : le numéro suit la convention du réseau affiché ;
    /// sans réseau connu, seul l'azimut est sûr.
    private func sectorLabel(index: Int, azimuth: Int) -> String {
        guard let operatorName else { return String(localized: "Secteur \(azimuth)°") }
        let number = SectorNumbering.displayValue(index: index, operatorName: operatorName)
        return String(localized: "Secteur \(number) · \(azimuth)°")
    }

    private var selectedSectorLabel: String {
        guard let sector, let index = availableSectors.firstIndex(of: sector) else { return String(localized: "Non précisé") }
        return sectorLabel(index: index, azimuth: sector)
    }

    private func formSection<Content: View>(_ title: LocalizedStringKey, footer: LocalizedStringKey? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: SQSpace.sm) {
            Text(title).sqKicker().accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .sqCardBackground(SQColor.bg, cornerRadius: SQRadius.lg, elevation: .rest)
            if let footer {
                Text(footer)
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Ligne « libellé … valeur ⌃⌄ » : toute la ligne ouvre le menu, qui garde
    /// les icônes et la coche ; la ligne ne montre que la valeur, sur une ligne.
    private func pickerRow<P: View>(_ title: LocalizedStringKey, value: String, identifier: String,
                                    @ViewBuilder picker: () -> P) -> some View {
        Menu {
            picker().pickerStyle(.inline)
        } label: {
            HStack(spacing: SQSpace.sm) {
                Text(title)
                    .foregroundStyle(SQColor.label)
                Spacer(minLength: SQSpace.sm)
                Text(value)
                    .foregroundStyle(SQColor.labelSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            .font(SQType.body)
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }

    private func fieldRow(_ placeholder: LocalizedStringKey, text: Binding<String>, identifier: String) -> some View {
        TextField(placeholder, text: text, axis: .vertical)
            .lineLimit(1...3)
            .font(SQType.body)
            .foregroundStyle(SQColor.label)
            .padding(.horizontal, SQSpace.md)
            .padding(.vertical, SQSpace.sm2)
            .frame(minHeight: 48)
            .accessibilityIdentifier(identifier)
    }

    private func send() async {
        isBusy = true
        error = nil
        duplicateMessage = nil
        defer { isBusy = false }
        do {
            let result = try await service.submit(
                siteId: siteId,
                reportType: reportType,
                // Les valeurs saisies sous un autre type restent dans les champs
                // cachés : seules celles du type choisi partent.
                currentValue: isLeaderReport ? leaderReport?.currentLeader : (reportType.suggestsValues ? currentValue : nil),
                suggestedValue: isLeaderReport ? suggestedLeader : (reportType.suggestsValues ? suggestedValue : nil),
                reason: reason,
                sector: sector,
                submissionID: submissionID
            )
            Haptics.success()
            if result.duplicate == true {
                // Déjà signalé ce type pour ce site (HTTP 200) : on le dit sans
                // fermer, pour que l'utilisateur sache que c'est bien pris en compte.
                duplicateMessage = result.message ?? String(localized: "Tu avais déjà signalé ce problème pour ce site. Merci !")
            } else {
                dismiss()
            }
        } catch {
            if error.isCancellation { return }
            self.error = error.userFacingMessage
            Haptics.error()
        }
    }
}
