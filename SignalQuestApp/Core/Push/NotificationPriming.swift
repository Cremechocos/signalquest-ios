import SwiftUI
import UIKit
import UserNotifications

/// Demande des notifications au bon moment (TRX-01) : jamais au lancement,
/// seulement après une action qui leur donne un sens — un message envoyé, un
/// post publié, une alerte d'antenne activée — et une seule fois par
/// installation. Une feuille explique d'abord ; la question système ne vient
/// qu'après « Activer les notifications ».
@MainActor
final class NotificationPrimingCoordinator {
    enum Reason: String, Sendable {
        case messageSent
        case postPublished
        case antennaAlert
    }

    static let shownKey = "notificationPriming.shown.v1"

    private let defaults: UserDefaults
    private let isEnabled: @MainActor () -> Bool
    private let authorizationStatus: @Sendable () async -> UNAuthorizationStatus
    private let presentSheet: @MainActor (Reason) -> Bool
    private var isPresenting = false

    init(
        defaults: UserDefaults = .standard,
        isEnabled: @escaping @MainActor () -> Bool = { !AppEnvironment.usesDemoData },
        authorizationStatus: @escaping @Sendable () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        presentSheet: @escaping @MainActor (Reason) -> Bool
    ) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.authorizationStatus = authorizationStatus
        self.presentSheet = presentSheet
    }

    /// Propose les notifications après `reason`, si iOS ne les a encore jamais
    /// demandées et si la feuille n'a pas déjà été montrée sur cet appareil.
    /// Renvoie `true` quand la feuille a été présentée (tests).
    @discardableResult
    func considerPriming(after reason: Reason) async -> Bool {
        guard isEnabled(), !isPresenting, !defaults.bool(forKey: Self.shownKey) else { return false }
        isPresenting = true
        defer { isPresenting = false }
        guard await authorizationStatus() == .notDetermined else { return false }
        // Une feuille qui se ferme (compositeur…) bloque toute présentation :
        // on réessaie quelques fois plutôt que de perdre le moment.
        for attempt in 0..<6 {
            if attempt > 0 {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return false }
            }
            if presentSheet(reason) {
                defaults.set(true, forKey: Self.shownKey)
                return true
            }
        }
        return false
    }
}

/// Présente une vue SwiftUI en feuille au-dessus du contrôleur visible, y
/// compris quand une autre feuille est déjà ouverte. Renvoie `false` sans rien
/// présenter si une transition est en cours : l'appelant réessaie.
enum TopSheetPresenter {
    @MainActor
    static func present<Content: View>(_ makeContent: (_ dismiss: @escaping () -> Void) -> Content) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first,
              var presenter = window.rootViewController else { return false }
        while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
        guard !presenter.isBeingPresented, !presenter.isBeingDismissed,
              presenter.presentedViewController == nil,
              !(presenter is UIAlertController) else { return false }
        let host = UIHostingController<AnyView>(rootView: AnyView(EmptyView()))
        host.rootView = AnyView(makeContent { [weak host] in host?.dismiss(animated: true) })
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.detents = [.medium(), .large()]
        presenter.present(host, animated: true)
        return true
    }
}

/// Explication avant la question système des notifications (modèle :
/// `LocationPrimingSheet`).
struct NotificationPrimingSheet: View {
    let reason: NotificationPrimingCoordinator.Reason
    let onAllow: () -> Void
    let onSkip: () -> Void

    var body: some View {
        // En grand texte, le contenu dépasse la demi-hauteur : il défile.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .signalQuestBackground()
    }

    private var content: some View {
        VStack(spacing: SQSpace.lg) {
            SQSheetHandle()
            Spacer(minLength: 0)
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(SQColor.brandRed)
                .frame(width: 96, height: 96)
                .background(SQColor.accentSoft, in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: SQSpace.sm) {
                Text(title)
                    .font(SQType.title)
                    .foregroundStyle(SQColor.label)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(SQType.body)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tu choisis ensuite quoi recevoir dans Profil › Réglages › Notifications.")
                    .font(SQType.caption)
                    .foregroundStyle(SQColor.labelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            VStack(spacing: SQSpace.sm) {
                GradientButton("Activer les notifications", systemImage: "bell.fill") { onAllow() }
                    .accessibilityIdentifier("notificationPriming.allow")
                Button("Plus tard") { onSkip() }
                    .font(SQFont.archivo(15, .semibold, relativeTo: .subheadline))
                    .tint(SQColor.labelSecondary)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("notificationPriming.later")
            }
        }
        .padding(SQSpace.xl)
    }

    private var title: LocalizedStringKey {
        switch reason {
        case .messageSent: return "Être prévenu des réponses ?"
        case .postPublished: return "Être prévenu des réactions ?"
        case .antennaAlert: return "Recevoir l’alerte de panne ?"
        }
    }

    private var message: LocalizedStringKey {
        switch reason {
        case .messageSent:
            return "SignalQuest peut te prévenir quand on te répond ou qu’on t’appelle, même app fermée."
        case .postPublished:
            return "SignalQuest peut te prévenir quand on commente ou aime ta publication, même app fermée."
        case .antennaAlert:
            return "Pour t’alerter d’une panne sur une antenne que tu suis, SignalQuest a besoin des notifications."
        }
    }
}
