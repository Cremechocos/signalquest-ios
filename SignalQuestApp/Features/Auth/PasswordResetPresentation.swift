import SwiftUI

/// Lien reçu au lancement ou pendant une feuille d'inscription/récupération :
/// présenter au-dessus du contrôleur visible sans fermer son brouillon.
struct PasswordResetPresentation: UIViewRepresentable {
    let route: PasswordResetRoute?
    let canPresent: Bool
    let mustDismiss: Bool
    let session: AuthSessionViewModel
    let locale: Locale
    let onClose: (UUID) -> Void
    let onSuccess: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.isUserInteractionEnabled = false
        anchor.accessibilityElementsHidden = true
        context.coordinator.anchor = anchor
        anchor.onWindowChanged = { [weak coordinator = context.coordinator] in coordinator?.refresh() }
        return anchor
    }
    func updateUIView(_ uiView: Anchor, context: Context) {
        context.coordinator.configuration = self
        context.coordinator.refresh()
    }
    static func dismantleUIView(_ uiView: Anchor, coordinator: Coordinator) { coordinator.detach() }

    final class Anchor: UIView {
        var onWindowChanged: (() -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onWindowChanged?() }
    }

    @MainActor
    private final class Host: UIHostingController<AnyView> {
        var onDisappeared: (() -> Void)?
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            onDisappeared?()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        weak var anchor: Anchor?
        var configuration: PasswordResetPresentation?
        private var host: Host?
        private var routeID: UUID?
        private var dismissingRouteID: UUID?
        private var retry: Task<Void, Never>?

        func refresh() {
            retry?.cancel()
            retry = nil
            guard let config = configuration else { return }
            guard let route = config.route, !config.mustDismiss else { dismissHost(); return }
            if let host {
                routeID = route.id
                host.rootView = content(route: route, config: config)
                if let root = anchor?.window?.rootViewController, contains(host, in: root) {
                    if host.isBeingDismissed { scheduleRefresh() }
                    return
                }
                // UIKit peut conserver temporairement le lien de présentation
                // pendant la fermeture d'un ancêtre. Attendre la fin réelle.
                if host.isBeingPresented || host.isBeingDismissed || host.presentingViewController != nil {
                    scheduleRefresh()
                    return
                }
            }
            guard config.canPresent, let window = anchor?.window,
                  window.windowScene?.activationState == .foregroundActive,
                  var presenter = window.rootViewController else { return }
            while let next = presenter.presentedViewController, !next.isBeingDismissed { presenter = next }
            guard !presenter.isBeingPresented, !presenter.isBeingDismissed,
                  presenter.presentedViewController == nil, !(presenter is UIAlertController) else {
                scheduleRefresh()
                return
            }
            // Réutiliser le host détaché garde les @State du brouillon. Une
            // nouvelle route conserve son .id distinct et remplace ce brouillon.
            let controller = host ?? Host(rootView: content(route: route, config: config))
            controller.onDisappeared = { [weak self] in self?.scheduleRefresh() }
            controller.modalPresentationStyle = .pageSheet
            host = controller
            routeID = route.id
            controller.presentationController?.delegate = self
            presenter.present(controller, animated: true)
        }

        private func contains(_ target: UIViewController, in controller: UIViewController) -> Bool {
            if controller === target { return true }
            if let presented = controller.presentedViewController, contains(target, in: presented) { return true }
            return controller.children.contains { contains(target, in: $0) }
        }

        private func scheduleRefresh() {
            retry?.cancel()
            retry = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                self?.refresh()
            }
        }

        private func content(route: PasswordResetRoute, config: PasswordResetPresentation) -> AnyView {
            AnyView(PasswordResetScreen(route: route, onClose: { config.onClose(route.id) },
                onSuccess: { config.onSuccess(route.id) })
                .environmentObject(config.session)
                .environment(\.locale, config.locale)
                .id(route.id))
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === host else { return }
            dismissingRouteID = routeID
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard presentationController.presentedViewController === host else { return }
            let closed = dismissingRouteID ?? routeID
            host = nil
            routeID = nil
            dismissingRouteID = nil
            if let closed { configuration?.onClose(closed) }
            refresh()
        }

        private func dismissHost() {
            let old = host
            host = nil
            routeID = nil
            dismissingRouteID = nil
            old?.onDisappeared = nil
            old?.dismiss(animated: false)
        }

        func detach() {
            retry?.cancel()
            retry = nil
            configuration = nil
            dismissHost()
        }
    }
}
