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

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var session: AuthSessionViewModel

    @State private var title: String
    @State private var participants: [ConversationParticipant]
    @State private var searchQuery = ""
    @State private var searchResults: [MessageSearchUser] = []
    @State private var photoItem: PhotosPickerItem?
    @State private var showAvatarPicker = false
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var confirmLeave = false
    /// URL de la photo de groupe courante (mise à jour après upload).
    @State private var groupPhotoURL: URL?
    /// Aperçu local immédiat de la photo choisie (optimiste, avant l'aller-retour réseau).
    @State private var pickedPreview: UIImage?

    init(conversation: MessageConversation, service: MessagesServicing, e2ee: E2EEServicing?) {
        self.conversation = conversation
        self.service = service
        self.e2ee = e2ee
        _title = State(initialValue: conversation.title ?? "")
        _participants = State(initialValue: conversation.participants)
        _groupPhotoURL = State(initialValue: conversation.groupPhotoUrl)
    }

    private var currentUserId: String? {
        if case .authenticated(let user) = session.state { return user.id }
        return nil
    }

    private var isAdmin: Bool {
        participants.first { $0.userId == currentUserId }?.role == "admin"
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
                                Text(participant.user.displayName)
                                    .font(SQType.body)
                                    .foregroundStyle(SQColor.label)
                                if participant.role == "admin" {
                                    Text("Admin")
                                        .font(SQType.micro)
                                        .foregroundStyle(SQColor.brandRed)
                                }
                            }
                            Spacer()
                            if isAdmin && participant.userId != currentUserId {
                                Menu {
                                    Button {
                                        Task { await changeRole(participant, to: participant.role == "admin" ? "member" : "admin") }
                                    } label: {
                                        Label(
                                            participant.role == "admin" ? "Rétrograder" : "Promouvoir admin",
                                            systemImage: participant.role == "admin" ? "person.badge.minus" : "person.badge.shield.checkmark"
                                        )
                                    }
                                    Button(role: .destructive) {
                                        Task { await remove(participant) }
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

                Section {
                    Button(role: .destructive) {
                        confirmLeave = true
                    } label: {
                        Label("Quitter le groupe", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(SQType.body.weight(.medium))
                            .foregroundStyle(SQColor.danger)
                    }
                }
                .listRowBackground(SQColor.dangerSoft)

                if let errorMessage {
                    Section { Text(errorMessage).font(SQType.caption).foregroundStyle(SQColor.danger) }
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
            .onChangeCompat(of: searchQuery) { _, _ in
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    await search()
                }
            }
            .onChangeCompat(of: photoItem) { _, newValue in
                guard let newValue else { return }
                Task { await uploadPhoto(item: newValue) }
            }
        }
    }

    /// En-tête de section : Figtree casse normale (pas de majuscules trackées).
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
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
        searchResults = (try? await service.searchUsers(query: trimmed)) ?? []
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
            try await service.updateConversation(id: conversation.id, title: nil, addUserIds: [user.id], removeUserIds: [])
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
            // Nouveau membre d'un groupe chiffré : il lui faut la clé wrappée.
            if conversation.e2eeEnabled == true, let e2ee {
                await e2ee.shareConversationKeyIfNeeded(conversationId: conversation.id)
            }
        }
    }

    private func remove(_ participant: ConversationParticipant) async {
        await run {
            try await service.updateConversation(id: conversation.id, title: nil, addUserIds: [], removeUserIds: [participant.userId])
            participants.removeAll { $0.userId == participant.userId }
        }
    }

    private func changeRole(_ participant: ConversationParticipant, to role: String) async {
        await run {
            try await service.changeRole(conversationId: conversation.id, userId: participant.userId, role: role)
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
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: raw),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        // Aperçu optimiste immédiat, puis upload ; on confirme avec l'URL renvoyée.
        // On conserve l'aperçu local en cas de succès (il EST la photo uploadée)
        // pour éviter un flash le temps que l'image distante se charge.
        withAnimation(.snappy) { pickedPreview = image }
        await run {
            if let uploadedURL = try await service.uploadGroupPhoto(conversationId: conversation.id, data: jpeg) {
                groupPhotoURL = uploadedURL
            }
        }
        // En cas d'échec, on retire l'aperçu pour revenir à l'état réel.
        if errorMessage != nil { withAnimation { pickedPreview = nil } }
    }

    private func leave() async {
        await run {
            try await service.leaveConversation(id: conversation.id)
            dismiss()
        }
    }

    private func run(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            errorMessage = nil
            Haptics.success()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
