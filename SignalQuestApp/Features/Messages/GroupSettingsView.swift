import SwiftUI
import PhotosUI
import UIKit

/// Réglages d'un groupe : renommage, photo, membres (ajout/retrait/rôle),
/// quitter. Après tout ajout de membre dans un groupe E2EE, la clé de
/// conversation est re-partagée aux nouveaux venus.
struct GroupSettingsView: View {
    let conversation: MessageConversation
    let service: MessagesServicing
    let e2ee: E2EEServicing?
    /// Appelé après un départ réussi : la conversation quittée se ferme aussi.
    var onLeft: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: AuthSessionViewModel
    @EnvironmentObject private var services: AppServices

    /// Conversation v2 : les membres changent par la chaîne signée (D.4).
    private var usesV2: Bool {
        EncryptedConversationSurfaces.isV2(conversation) && services.e2eeV2Messaging.writesEnabled
    }

    @State private var title: String
    @State private var participants: [ConversationParticipant]
    @State private var searchQuery = ""
    @State private var searchResults: [MessageSearchUser] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var photoItem: PhotosPickerItem?
    @State private var showAvatarPicker = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var confirmLeave = false
    /// Membre en attente de confirmation de retrait (UX-4 : pas de retrait d'un tap).
    @State private var participantToRemove: ConversationParticipant?
    /// URL de la photo de groupe courante (mise à jour après upload).
    @State private var groupPhotoURL: URL?
    /// Aperçu local immédiat de la photo choisie (optimiste, avant l'aller-retour réseau).
    @State private var pickedPreview: UIImage?
    /// Groupe v2 : admins d'après la chaîne signée, et ce qu'exige un départ (D.4).
    @State private var chainAdmins: Set<String>?
    @State private var successorNeed: E2EEV2MessagingRuntime.SuccessorNeed = .none
    @State private var showsSuccessorPicker = false

    init(conversation: MessageConversation, service: MessagesServicing, e2ee: E2EEServicing?,
         onLeft: @escaping () -> Void = {}) {
        self.conversation = conversation
        self.service = service
        self.e2ee = e2ee
        self.onLeft = onLeft
        _title = State(initialValue: conversation.title ?? "")
        _participants = State(initialValue: conversation.participants)
        _groupPhotoURL = State(initialValue: conversation.groupPhotoUrl)
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }

    /// Le créateur du groupe (`owner`) a tous les droits d'un admin ; il les
    /// perdait ici alors que la conversation, elle, les lui reconnaissait (SOC-10).
    private var isAdmin: Bool {
        // v2 : la chaîne fait foi, pas le rôle servi.
        if let chainAdmins { return currentUserId.map(chainAdmins.contains) ?? false }
        let role = participants.first { $0.userId == currentUserId }?.role
        return role == "owner" || role == "admin"
    }

    /// En v1, le serveur réserve les rôles au créateur ; en v2, à tout admin.
    private var canChangeRoles: Bool {
        if chainAdmins != nil { return isAdmin }
        return participants.first { $0.userId == currentUserId }?.role == "owner"
    }

    private func isAdminMember(_ participant: ConversationParticipant) -> Bool {
        if let chainAdmins { return chainAdmins.contains(participant.userId) }
        return participant.role == "admin"
    }

    private func refreshChainRoles() {
        guard usesV2 else { return }
        chainAdmins = services.e2eeV2Messaging.groupAdmins(conversationId: conversation.id)
        successorNeed = services.e2eeV2Messaging.successorNeed(conversationId: conversation.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: SQSpace.md) {
                        if isAdmin {
                            adminAvatarPicker
                        } else {
                            groupAvatar
                        }
                        TextField("Nom du groupe", text: $title)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .onSubmit { Task { await rename() } }
                    }
                } header: {
                    sectionHeader("Groupe")
                }
                .listRowBackground(SQColor.surface)
                .listRowSeparatorTint(SQColor.separator)

                Section {
                    ForEach(participants) { participant in
                        HStack {
                            SQAvatar(url: participant.user.avatarUrl, name: participant.user.displayName, size: 34)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading) {
                                HStack(spacing: 5) {
                                    Text(participant.user.displayName)
                                        .font(SQType.body)
                                        .foregroundStyle(SQColor.label)
                                        .lineLimit(1)
                                    // Dans un GROUPE, c'est ici que le badge a un
                                    // sens : à côté du membre qu'il qualifie. Le
                                    // poser à côté du nom du groupe ne dirait rien
                                    // de personne.
                                    SQUserBadges(badges: participant.user.badges, size: 12)
                                }
                                if isAdminMember(participant) {
                                    Text("Admin")
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.brandRed)
                                }
                            }
                            Spacer()
                            if isAdmin && participant.userId != currentUserId {
                                Menu {
                                    if canChangeRoles {
                                        let admin = isAdminMember(participant)
                                        Button {
                                            Task { await changeRole(participant, to: admin ? "member" : "admin") }
                                        } label: {
                                            Label(
                                                admin ? "Rétrograder" : "Promouvoir admin",
                                                systemImage: admin ? "person.badge.minus" : "person.badge.shield.checkmark"
                                            )
                                        }
                                    }
                                    Button(role: .destructive) {
                                        // Confirmer avant de retirer (comme « Quitter le
                                        // groupe ») : évite un retrait accidentel d'un tap (UX-4).
                                        participantToRemove = participant
                                    } label: {
                                        Label("Retirer du groupe", systemImage: "person.fill.xmark")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .foregroundStyle(SQColor.labelSecondary)
                                }
                                .accessibilityLabel("Options de \(participant.user.displayName)")
                            }
                        }
                    }
                } header: {
                    sectionHeader("Membres (\(participants.count))")
                }
                .listRowBackground(SQColor.surface)
                .listRowSeparatorTint(SQColor.separator)

                if isAdmin {
                    Section {
                        TextField("Nom, handle ou email", text: $searchQuery)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        ForEach(searchResults.filter { result in !participants.contains(where: { $0.userId == result.id }) }) { user in
                            Button {
                                Task { await add(user) }
                            } label: {
                                HStack {
                                    SQAvatar(url: user.avatarUrl, name: user.displayName, size: 34)
                                        .accessibilityHidden(true)
                                    Text(user.displayName)
                                        .font(SQType.body)
                                        .foregroundStyle(SQColor.label)
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundStyle(SQColor.success)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                    } header: {
                        sectionHeader("Ajouter des membres")
                    }
                    .listRowBackground(SQColor.surface)
                    .listRowSeparatorTint(SQColor.separator)
                }

                if successorNeed == .frozen {
                    Section {
                        Label("Ce groupe n’a plus d’admin : ses membres et ses rôles ne peuvent plus changer. Les messages et les appels continuent.",
                              systemImage: "lock")
                            .font(SQType.caption)
                            .foregroundStyle(SQColor.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .listRowBackground(SQColor.surface)
                }

                Section {
                    Button(role: .destructive) {
                        if case .mustName = successorNeed {
                            showsSuccessorPicker = true
                        } else {
                            confirmLeave = true
                        }
                    } label: {
                        Label("Quitter le groupe", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(SQType.body.weight(.medium))
                            .foregroundStyle(SQColor.dangerInk)
                    }
                }
                .listRowBackground(SQColor.dangerSoft)

                if let errorMessage {
                    Section { Text(errorMessage).font(SQType.caption).foregroundStyle(SQColor.dangerInk) }
                        .listRowBackground(SQColor.dangerSoft)
                }
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Réglages du groupe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }.tint(SQColor.brandRed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isBusy { ProgressView() }
                }
            }
            .confirmationDialog("Quitter le groupe ?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Quitter", role: .destructive) { Task { await leave() } }
            }
            .sheet(isPresented: $showsSuccessorPicker) {
                if case .mustName(let candidates) = successorNeed {
                    SuccessorPickerSheet(
                        candidates: candidates.compactMap { id in participants.first { $0.userId == id } }
                    ) { successor in
                        showsSuccessorPicker = false
                        Task { await leave(naming: successor) }
                    }
                }
            }
            .task { refreshChainRoles() }
            .confirmationDialog(
                participantToRemove.map { "Retirer \($0.user.displayName) du groupe ?" } ?? "Retirer du groupe ?",
                isPresented: Binding(get: { participantToRemove != nil }, set: { if !$0 { participantToRemove = nil } }),
                titleVisibility: .visible
            ) {
                Button("Retirer", role: .destructive) {
                    if let participant = participantToRemove {
                        participantToRemove = nil
                        Task { await remove(participant) }
                    }
                }
            }
            .onChangeCompat(of: searchQuery) { _, _ in
                // Une frappe annule la recherche précédente : sans cela, une
                // réponse lente pour « al » pouvait remplacer celle d'« alex ».
                searchTask?.cancel()
                searchTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await search()
                }
            }
            .onDisappear { searchTask?.cancel() }
            .onChangeCompat(of: photoItem) { _, newValue in
                guard let newValue else { return }
                Task { await uploadPhoto(item: newValue) }
            }
        }
    }

    /// En-tête de section : Figtree casse normale (pas de majuscules trackées).
    private func sectionHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(SQType.subhead)
            .foregroundStyle(SQColor.labelSecondary)
            .textCase(nil)
    }

    private func search() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        let results = (try? await service.searchUsers(query: trimmed)) ?? []
        guard !Task.isCancelled else { return }
        searchResults = results
    }

    private func rename() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != conversation.title else { return }
        await run {
            try await service.updateConversation(id: conversation.id, title: trimmed, addUserIds: [], removeUserIds: [])
        }
    }

    private func add(_ user: MessageSearchUser) async {
        await run {
            if usesV2 {
                try await services.e2eeV2Messaging.apply(.add(userId: user.id), to: conversation)
            } else {
                try await service.updateConversation(id: conversation.id, title: nil, addUserIds: [user.id], removeUserIds: [])
            }
            participants.append(
                ConversationParticipant(
                    userId: user.id,
                    role: "member",
                    joinedAt: Date(),
                    lastReadAt: nil,
                    user: MessageUser(id: user.id, name: user.name, email: user.email, avatarUrl: user.avatarUrl),
                    presence: nil
                )
            )
            // Nouveau membre d'un groupe chiffré v1 : il lui faut la clé wrappée.
            if !usesV2, conversation.e2eeEnabled == true, let e2ee {
                await e2ee.shareConversationKeyIfNeeded(conversationId: conversation.id)
            }
        }
    }

    private func remove(_ participant: ConversationParticipant) async {
        await run {
            if usesV2 {
                try await services.e2eeV2Messaging.apply(.remove(userId: participant.userId), to: conversation)
            } else {
                try await service.updateConversation(id: conversation.id, title: nil, addUserIds: [], removeUserIds: [participant.userId])
            }
            participants.removeAll { $0.userId == participant.userId }
        }
    }

    private func changeRole(_ participant: ConversationParticipant, to role: String) async {
        await run {
            if usesV2 {
                try await services.e2eeV2Messaging.apply(
                    role == "admin" ? .promote(userId: participant.userId) : .demote(userId: participant.userId), to: conversation
                )
                refreshChainRoles()
            } else {
                try await service.changeRole(conversationId: conversation.id, userId: participant.userId, role: role)
            }
            if let index = participants.firstIndex(where: { $0.userId == participant.userId }) {
                participants[index] = ConversationParticipant(
                    userId: participant.userId,
                    role: role,
                    joinedAt: participant.joinedAt,
                    lastReadAt: participant.lastReadAt,
                    user: participant.user,
                    presence: participant.presence
                )
            }
        }
    }

    /// Avatar du groupe : aperçu local immédiat si une photo vient d'être
    /// choisie, sinon l'image distante courante.
    @ViewBuilder
    private var groupAvatar: some View {
        if let pickedPreview {
            Image(uiImage: pickedPreview)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            SQAvatar(url: groupPhotoURL, name: title.isEmpty ? "Groupe" : title, size: 52)
                .accessibilityHidden(true)
        }
    }

    /// Sélecteur d'avatar (admin) : un `Button` + `.photosPicker(isPresented:)`
    /// (label MainActor classique) au lieu de `PhotosPicker { label }` dont le
    /// closure est `@Sendable` et interdit de référencer l'état / capturer une View.
    private var adminAvatarPicker: some View {
        Button { showAvatarPicker = true } label: {
            groupAvatar
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SQColor.label)
                        .padding(5)
                        .background(SQColor.surface, in: Circle())
                        .sqShadowSoft()
                        .accessibilityHidden(true)
                }
                .opacity(isBusy && pickedPreview != nil ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Changer la photo du groupe")
        .photosPicker(isPresented: $showAvatarPicker, selection: $photoItem, matching: .images)
    }

    private func uploadPhoto(item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self) else { return }
        // La photo d'un groupe s'affiche en petit : on la décode réduite, hors du
        // fil principal, au lieu de l'image pleine taille (SOC-33).
        let prepared = await Task.detached(priority: .userInitiated) {
            ImagePipeline.downsample(data: raw, maxPixel: 1024)?.jpegData(compressionQuality: 0.85)
        }.value
        guard let jpeg = prepared, let image = UIImage(data: jpeg) else { return }
        // Aperçu optimiste immédiat, puis upload ; on confirme avec l'URL renvoyée.
        // On conserve l'aperçu local en cas de succès (il EST la photo uploadée)
        // pour éviter un flash le temps que l'image distante se charge.
        withAnimation(SQMotion.resolve(.snappy, reduceMotion)) { pickedPreview = image }
        await run {
            if let uploadedURL = try await service.uploadGroupPhoto(conversationId: conversation.id, data: jpeg) {
                groupPhotoURL = uploadedURL
            }
        }
        // En cas d'échec, on retire l'aperçu pour revenir à l'état réel.
        if errorMessage != nil { withAnimation(SQMotion.resolve(.default, reduceMotion)) { pickedPreview = nil } }
    }

    private func leave(naming successor: String? = nil) async {
        await run {
            if usesV2 {
                try await services.e2eeV2Messaging.leave(conversation, naming: successor)
            } else {
                try await service.leaveConversation(id: conversation.id)
            }
            dismiss()
            onLeft()
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            // §12 : une conversation v2 ne change jamais de membres par la voie v1.
            if EncryptedConversationSurfaces.isV2(conversation) && !usesV2 {
                throw E2EEV2MessagingError(String(localized: "Cette conversation chiffrée n’est pas disponible dans cette version de SignalQuest."))
            }
            try await work()
            errorMessage = nil
            Haptics.success()
        } catch {
            errorMessage = error.userFacingMessage
            Haptics.error()
        }
    }
}

/// Dernier admin d'un groupe chiffré : un successeur avant de partir (D.4).
/// Les membres viennent du plus ancien au plus récent.
struct SuccessorPickerSheet: View {
    let candidates: [ConversationParticipant]
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { participant in
                        Button {
                            selection = participant.userId
                        } label: {
                            HStack(spacing: SQSpace.md) {
                                SQAvatar(url: participant.user.avatarUrl, name: participant.user.displayName, size: 34)
                                    .accessibilityHidden(true)
                                Text(participant.user.displayName)
                                    .font(SQType.body)
                                    .foregroundStyle(SQColor.label)
                                Spacer()
                                if selection == participant.userId {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(SQColor.brandRed)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityAddTraits(selection == participant.userId ? .isSelected : [])
                    }
                } footer: {
                    Text("Tu es le seul admin de ce groupe chiffré. Le membre choisi pourra ajouter, retirer et nommer d’autres admins.")
                        .font(SQType.caption)
                }
                .listRowBackground(SQColor.surface)
            }
            .scrollContentBackground(.hidden)
            .signalQuestBackground()
            .navigationTitle("Nomme un admin avant de partir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                GradientButton(String(localized: "Nommer admin et quitter"), systemImage: "rectangle.portrait.and.arrow.right", style: .primary) {
                    if let selection { onConfirm(selection) }
                }
                .disabled(selection == nil)
                .padding(SQSpace.lg)
                .accessibilityIdentifier("group.successor.confirm")
            }
            .onAppear { if selection == nil { selection = candidates.first?.userId } }
        }
    }
}
