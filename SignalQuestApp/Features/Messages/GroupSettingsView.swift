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
    var onRenamed: (String) -> Void = { _ in }
    /// Appelé quand le nombre de membres change (ajout, retrait) : l'en-tête de
    /// la conversation garde sinon l'ancien compte.
    var onMembersChanged: (Int) -> Void = { _ in }
    /// Dernier nom enregistré pendant cette ouverture.
    @State private var renamedTo: String?

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
    /// Recherche en vol, dernière requête dont la réponse est arrivée, et échec
    /// éventuel (dit près du champ, sans toucher à `errorMessage` des actions).
    @State private var isSearching = false
    @State private var searchedQuery = ""
    @State private var searchError: String?
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
    /// « Ajouter des membres » touché : le champ de recherche remplace la ligne.
    @State private var showsAddField = false
    @FocusState private var addFieldFocused: Bool

    init(conversation: MessageConversation, service: MessagesServicing, e2ee: E2EEServicing?,
         onRenamed: @escaping (String) -> Void = { _ in },
         onMembersChanged: @escaping (Int) -> Void = { _ in },
         onLeft: @escaping () -> Void = {}) {
        self.conversation = conversation
        self.service = service
        self.e2ee = e2ee
        self.onRenamed = onRenamed
        self.onMembersChanged = onMembersChanged
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
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                HStack {
                    // Le nom ne partait qu'avec la touche Retour : « Fermer » le
                    // perdait sans prévenir (AF-MSG-13).
                    MapChipIconButton(systemImage: "xmark", label: "Fermer", identifier: "group.close") {
                        Task {
                            if hasPendingRename {
                                await rename()
                                // Renommage refusé : on rétablit l'ancien nom (l'erreur
                                // reste affichée) pour que « Fermer » ne soit pas bloqué
                                // au prochain appui.
                                if errorMessage != nil {
                                    title = renamedTo ?? conversation.title ?? ""
                                    return
                                }
                            }
                            dismiss()
                        }
                    }
                    Spacer()
                    if isBusy { SQSpinner() }
                }

                identityHeader

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    Text("Membres")
                        .sqKicker()
                        .padding(.leading, SQSpace.xs)
                    membersCard
                }

                if successorNeed == .frozen {
                    Label("Ce groupe n’a plus d’admin : ses membres et ses rôles ne peuvent plus changer. Les messages et les appels continuent.",
                          systemImage: "lock")
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(SQSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                }

                GradientButton(String(localized: "Quitter le groupe"), systemImage: "rectangle.portrait.and.arrow.right", style: .destructive) {
                    // Relu au moment du départ : membres et admins ont pu changer.
                    refreshChainRoles()
                    if case .mustName = successorNeed {
                        showsSuccessorPicker = true
                    } else {
                        confirmLeave = true
                    }
                }
            }
            .padding(SQSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .sqSheet(background: SQColor.bg)
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
            // `String(localized:)` : un titre calculé en `String` ne passe pas par le catalogue.
            participantToRemove.map { String(localized: "Retirer \($0.user.displayName) du groupe ?") }
                ?? String(localized: "Retirer du groupe ?"),
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
        .onChangeCompat(of: participants.count) { _, count in onMembersChanged(count) }
        .onDisappear { searchTask?.cancel() }
        .onChangeCompat(of: photoItem) { _, newValue in
            guard let newValue else { return }
            Task { await uploadPhoto(item: newValue) }
        }
    }

    /// La photo en grand, le nom modifiable dessous, puis le nombre de membres.
    private var identityHeader: some View {
        VStack(spacing: SQSpace.sm) {
            if isAdmin {
                adminAvatarPicker
            } else {
                groupAvatar
            }
            HStack(spacing: SQSpace.xs) {
                // Le texte masqué donne sa largeur au champ : le crayon suit le
                // nom au lieu de partir au bord de l'écran.
                Text(verbatim: title.isEmpty ? String(localized: "Nom du groupe") : title)
                    .font(SQFont.display(24, .bold, relativeTo: .title))
                    .lineLimit(1)
                    .padding(.trailing, 2)
                    .hidden()
                    .overlay {
                        // Le serveur réserve le renommage aux admins : les autres
                        // lisent le nom, sans champ grisé.
                        if isAdmin {
                            TextField("Nom du groupe", text: $title)
                                .font(SQFont.display(24, .bold, relativeTo: .title))
                                .foregroundStyle(SQColor.label)
                                .multilineTextAlignment(.center)
                                .onSubmit { Task { await rename() } }
                        } else {
                            Text(verbatim: title.isEmpty ? String(localized: "Nom du groupe") : title)
                                .font(SQFont.display(24, .bold, relativeTo: .title))
                                .foregroundStyle(SQColor.label)
                                .lineLimit(1)
                        }
                    }
                if isAdmin {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .accessibilityHidden(true)
                }
            }
            Text("Groupe · \(participants.count) membres")
                .font(SQType.callout)
                .foregroundStyle(SQColor.labelSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Les membres sur une seule carte ; un admin ajoute depuis la dernière ligne.
    private var membersCard: some View {
        VStack(spacing: 0) {
            ForEach(participants) { participant in
                if participant.id != participants.first?.id { Divider().padding(.leading, 64) }
                memberRow(participant)
            }
            if isAdmin {
                Divider().padding(.leading, 64)
                if showsAddField {
                    addMembersSection
                } else {
                    Button {
                        showsAddField = true
                    } label: {
                        HStack(spacing: SQSpace.md) {
                            Image(systemName: "plus")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(SQColor.label)
                                .frame(width: 36, height: 36)
                                .background(SQColor.chip, in: Circle())
                            Text("Ajouter des membres")
                                .font(SQType.body(.semibold))
                                .foregroundStyle(SQColor.label)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, SQSpace.md)
                        .frame(minHeight: 56)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("group.addMembers")
                }
            }
        }
        .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
    }

    private func memberRow(_ participant: ConversationParticipant) -> some View {
        HStack(spacing: SQSpace.md) {
            SQAvatar(url: participant.user.avatarUrl, name: participant.user.displayName, size: 36)
                .accessibilityHidden(true)
            HStack(spacing: 5) {
                Text(participant.user.displayName)
                    .font(SQType.body(.semibold))
                    .foregroundStyle(SQColor.label)
                    .sqSingleLine()
                // Dans un GROUPE, c'est ici que le badge a un
                // sens : à côté du membre qu'il qualifie. Le
                // poser à côté du nom du groupe ne dirait rien
                // de personne.
                SQUserBadges(badges: participant.user.badges, size: 12)
            }
            Spacer(minLength: SQSpace.sm)
            if isAdminMember(participant) {
                Text("Admin")
                    .font(SQType.micro.weight(.semibold))
                    .foregroundStyle(SQColor.chipInk)
                    .padding(.horizontal, SQSpace.sm)
                    .padding(.vertical, 3)
                    .background(SQColor.chip, in: Capsule())
            }
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
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(SQColor.labelSecondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Options de \(participant.user.displayName)")
            }
        }
        .padding(.leading, SQSpace.md)
        .padding(.trailing, SQSpace.xs)
        .frame(minHeight: 56)
    }

    /// Le champ de recherche et ses résultats, à la place de la ligne « Ajouter ».
    private var addMembersSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: SQSpace.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(SQColor.labelSecondary)
                    .accessibilityHidden(true)
                TextField("Nom, handle ou email", text: $searchQuery)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.label)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($addFieldFocused)
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 52)
            Group {
                if isSearching {
                    UserSearchStatusRow(isSearching: true)
                } else if let searchError {
                    SQInlineError(message: searchError)
                } else if showsNoSearchResult {
                    UserSearchStatusRow(isSearching: false)
                }
            }
            .padding(.horizontal, SQSpace.md)
            .padding(.bottom, SQSpace.sm)
            ForEach(searchResults.filter { result in !participants.contains(where: { $0.userId == result.id }) }) { user in
                Divider().padding(.leading, 64)
                Button {
                    Task { await add(user) }
                } label: {
                    HStack(spacing: SQSpace.md) {
                        SQAvatar(url: user.avatarUrl, name: user.displayName, size: 36)
                            .accessibilityHidden(true)
                        Text(user.displayName)
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(SQColor.success)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { addFieldFocused = true }
    }

    private func search() async {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            searchedQuery = ""
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        do {
            let results = try await service.searchUsers(query: trimmed)
            guard !Task.isCancelled else { return }
            searchResults = results
            searchedQuery = trimmed
            searchError = nil
        } catch {
            guard !error.isCancellation, !Task.isCancelled else { return }
            // Une recherche en échec ne doit pas passer pour « aucun résultat ».
            searchResults = []
            searchError = error.userFacingMessage
        }
        isSearching = false
    }

    private var showsNoSearchResult: Bool {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tous les résultats déjà membres reviennent à ne rien pouvoir ajouter.
        return !trimmed.isEmpty && searchedQuery == trimmed
            && searchResults.allSatisfy { result in participants.contains(where: { $0.userId == result.id }) }
    }

    /// Nom saisi mais pas encore enregistré.
    private var hasPendingRename: Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (renamedTo ?? conversation.title)
    }

    private func rename() async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasPendingRename else { return }
        await run {
            try await service.updateConversation(id: conversation.id, title: trimmed, addUserIds: [], removeUserIds: [])
        }
        if errorMessage == nil {
            renamedTo = trimmed
            // La conversation ouverte garde sinon l'ancien titre (AF-MSG-13).
            onRenamed(trimmed)
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
            refreshChainRoles()
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
                .frame(width: 76, height: 76)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            SQAvatar(url: groupPhotoURL, name: title.isEmpty ? "Groupe" : title, size: 76)
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
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SQColor.onInk)
                        .frame(width: 28, height: 28)
                        .background(SQColor.label, in: Circle())
                        .overlay(Circle().stroke(SQColor.bg, lineWidth: 2.5))
                        .offset(x: 4, y: 4)
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
        guard let raw = try? await item.loadTransferable(type: Data.self) else {
            errorMessage = String(localized: "La photo n’a pas pu être lue. Choisis-en une autre.")
            Haptics.error()
            return
        }
        // La photo d'un groupe s'affiche en petit : on la décode réduite, hors du
        // fil principal, au lieu de l'image pleine taille (SOC-33).
        let prepared = await Task.detached(priority: .userInitiated) {
            ImagePipeline.downsample(data: raw, maxPixel: 1024)?.jpegData(compressionQuality: 0.85)
        }.value
        guard let jpeg = prepared, let image = UIImage(data: jpeg) else {
            errorMessage = String(localized: "La photo n’a pas pu être lue. Choisis-en une autre.")
            Haptics.error()
            return
        }
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
            refreshChainRoles()
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
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(
                    title: "Nomme un admin avant de partir",
                    subtitle: String(localized: "Tu es le seul admin de ce groupe chiffré. Le membre choisi pourra ajouter, retirer et nommer d’autres admins."),
                    closeIdentifier: "group.successor.cancel"
                ) { dismiss() }
                if candidates.isEmpty {
                    Text("Aucun autre membre n’est disponible. Ferme cet écran et réessaie.")
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(candidates) { participant in
                            if participant.id != candidates.first?.id { Divider().padding(.leading, 64) }
                            candidateRow(participant)
                        }
                    }
                    .sqSurface(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
                }
            }
            .padding(SQSpace.lg)
        }
        .safeAreaInset(edge: .bottom) {
            GradientButton(String(localized: "Nommer admin et quitter"), systemImage: "rectangle.portrait.and.arrow.right", style: .primary) {
                if let selection { onConfirm(selection) }
            }
            .disabled(selection == nil)
            .padding(SQSpace.lg)
            .accessibilityIdentifier("group.successor.confirm")
        }
        .sqSheet(background: SQColor.bg)
        .onAppear { if selection == nil { selection = candidates.first?.userId } }
    }

    private func candidateRow(_ participant: ConversationParticipant) -> some View {
        let selected = selection == participant.userId
        return Button {
            selection = participant.userId
        } label: {
            HStack(spacing: SQSpace.md) {
                SQAvatar(url: participant.user.avatarUrl, name: participant.user.displayName, size: 36)
                    .accessibilityHidden(true)
                Text(participant.user.displayName)
                    .font(SQType.body(.semibold))
                    .foregroundStyle(SQColor.label)
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? SQColor.brandRed : SQColor.labelSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, SQSpace.md)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Réglages « conversation protégée » : verrouillage à l'ouverture, alerte de
/// capture d'écran et suppression automatique des messages envoyés. Personnels
/// au compte : le serveur les garde par conversation et par membre.
struct ProtectedConversationSheet: View {
    let conversationId: String
    var subtitle: String? = nil
    let service: MessagesServicing
    let initial: ConversationSecretPolicy
    /// Réglage enregistré, et vrai quand l'appareil vient d'authentifier le propriétaire.
    let onChange: (ConversationSecretPolicy, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var policy: ConversationSecretPolicy
    @State private var isBusy = false
    @State private var errorMessage: String?

    /// Délais proposés pour la suppression automatique, en secondes.
    static let autoDeleteOptions = [3_600, 86_400, 604_800]

    init(
        conversationId: String,
        subtitle: String? = nil,
        service: MessagesServicing,
        initial: ConversationSecretPolicy,
        onChange: @escaping (ConversationSecretPolicy, Bool) -> Void
    ) {
        self.conversationId = conversationId
        self.subtitle = subtitle
        self.service = service
        self.initial = initial
        self.onChange = onChange
        _policy = State(initialValue: initial)
    }

    /// « 1 h », « 24 h », « 7 jours » : la durée d'un message éphémère.
    static func durationLabel(_ seconds: Int) -> String {
        switch seconds {
        case 3_600: return "1 h"
        case 86_400: return "24 h"
        case 604_800: return String(localized: "7 jours")
        default: return CallThreadEvent.durationLabel(seconds)
        }
    }

    private var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous) }
    private var canLock: Bool { BiometricAuth.canAuthenticateDeviceOwner }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SQSpace.lg) {
                MessageSheetHeader(
                    title: "Conversation protégée",
                    subtitle: subtitle,
                    closeIdentifier: "protection.close"
                ) { dismiss() }

                VStack(spacing: 0) {
                    Toggle(isOn: Binding(
                        get: { policy.requireBiometric },
                        set: { value in Task { await setLock(value) } }
                    )) {
                        Label("Verrouillage à l’ouverture", systemImage: BiometricAuth.kind.systemImage)
                            .font(SQType.body(.semibold))
                            .foregroundStyle(SQColor.label)
                    }
                    .tint(SQColor.brandRed)
                    .disabled(isBusy || (!canLock && !policy.requireBiometric))
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 56)
                    .accessibilityIdentifier("protection.lock")
                    Divider().padding(.leading, SQSpace.md)
                    Toggle(isOn: Binding(
                        get: { policy.blockScreenshots },
                        set: { value in Task { await update { $0.blockScreenshots = value } } }
                    )) {
                        Label("Alerte de capture d’écran", systemImage: "camera.viewfinder")
                            .font(SQType.body(.semibold))
                            .foregroundStyle(SQColor.label)
                    }
                    .tint(SQColor.brandRed)
                    .disabled(isBusy)
                    .padding(.horizontal, SQSpace.md)
                    .frame(minHeight: 56)
                    .accessibilityIdentifier("protection.capture")
                    Divider().padding(.leading, SQSpace.md)
                    autoDeleteRow
                }
                .sqSurface(SQColor.surface, in: cardShape)

                VStack(alignment: .leading, spacing: SQSpace.sm) {
                    note(canLock
                         ? "Le fil reste masqué tant que tu ne l’as pas déverrouillé avec Face ID ou ton code, et dès que tu quittes l’app."
                         : "Cet appareil n’a ni Face ID ni code : le verrouillage n’est pas disponible.")
                    note("Une bannière t’avertit quand tu fais une capture d’écran de cette conversation, et le fil se masque pendant un enregistrement d’écran. iOS ne permet pas de bloquer une capture.")
                    note("Les messages que tu envoies depuis cet appareil disparaissent après le délai choisi.")
                }
                .padding(.horizontal, SQSpace.xs)

                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("protection.error")
                }
            }
            .padding(SQSpace.lg)
        }
        .sqSheet(background: SQColor.bg)
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(SQType.caption)
            .foregroundStyle(SQColor.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var autoDeleteRow: some View {
        HStack(spacing: SQSpace.md) {
            Label("Suppression automatique", systemImage: "timer")
                .font(SQType.body(.semibold))
                .foregroundStyle(SQColor.label)
            Spacer(minLength: SQSpace.sm)
            Menu {
                Button { Task { await setAutoDelete(nil) } } label: {
                    Label("Désactivée", systemImage: policy.outgoingTTLSeconds == 0 ? "checkmark" : "")
                }
                ForEach(Self.autoDeleteOptions, id: \.self) { seconds in
                    Button { Task { await setAutoDelete(seconds) } } label: {
                        Label(Self.durationLabel(seconds), systemImage: policy.outgoingTTLSeconds == seconds ? "checkmark" : "")
                    }
                }
            } label: {
                Text(verbatim: policy.outgoingTTLSeconds > 0
                     ? Self.durationLabel(policy.outgoingTTLSeconds)
                     : String(localized: "Désactivée"))
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .disabled(isBusy)
            .accessibilityIdentifier("protection.autoDelete")
        }
        .padding(.horizontal, SQSpace.md)
        .frame(minHeight: 56)
    }

    private func setAutoDelete(_ seconds: Int?) async {
        await update {
            $0.autoDeleteSeconds = seconds
            // Les messages éphémères deviennent le réglage par défaut avec un délai choisi.
            $0.ephemeralDefault = (seconds ?? 0) > 0
        }
    }

    /// Activer le verrou demande d'abord de s'authentifier : on ne s'enferme pas dehors.
    private func setLock(_ enabled: Bool) async {
        guard !isBusy else { return }
        var authenticated = false
        if enabled {
            authenticated = await BiometricAuth.authenticate(
                reason: String(localized: "Confirme pour protéger cette conversation."),
                allowPasscode: true
            )
            guard authenticated else { return }
        }
        await update(authenticated: authenticated) { $0.requireBiometric = enabled }
    }

    private func update(authenticated: Bool = false, _ change: (inout ConversationSecretPolicy) -> Void) async {
        guard !isBusy else { return }
        var next = policy
        change(&next)
        let previous = policy
        policy = next
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let saved = try await service.saveSecretPolicy(next, conversationId: conversationId)
            policy = saved
            Haptics.success()
            onChange(saved, authenticated)
        } catch {
            policy = previous
            if !error.isCancellation { errorMessage = String(localized: "Le réglage n’a pas pu être enregistré.") }
            Haptics.error()
        }
    }
}
