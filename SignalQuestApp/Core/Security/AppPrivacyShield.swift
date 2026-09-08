import SwiftUI
import UIKit
import Combine

enum AppPrivacyCoverMode: Equatable {
    case hidden, obscured, locked

    static func resolve(authenticated: Bool, enabled: Bool, locked: Bool,
                        sceneActive: Bool, appBackgrounded: Bool, sensitivePresented: Bool = false) -> Self {
        if authenticated && locked { return .locked }
        // A sensitive presentation protects its scene even when the user has
        // chosen not to lock the app. Other active scenes remain usable.
        if sensitivePresented && !sceneActive { return .obscured }
        guard authenticated else { return .hidden }
        return enabled && (!sceneActive || appBackgrounded) ? .obscured : .hidden
    }
}

/// Le pont reste dans la hiérarchie existante. La fenêtre indépendante couvre
/// aussi les sheets/fullScreenCover sans interrompre leurs tâches ni la collecte.
struct AppPrivacyShield: UIViewRepresentable {
    let lock: AppLockController
    let authenticated: Bool
    @AppStorage(AppLockSettings.enabledKey) private var enabled = false
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> AppPrivacyShieldCoordinator {
        AppPrivacyShieldCoordinator(lock: lock)
    }

    func makeUIView(context: Context) -> AppPrivacyWindowProbe {
        let view = AppPrivacyWindowProbe()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onWindow = { [weak coordinator = context.coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateUIView(_ uiView: AppPrivacyWindowProbe, context: Context) {
        context.coordinator.configure(authenticated: authenticated, enabled: enabled, colorScheme: colorScheme)
        if let window = uiView.window { context.coordinator.attach(to: window) }
    }

    static func dismantleUIView(_ uiView: AppPrivacyWindowProbe, coordinator: AppPrivacyShieldCoordinator) {
        uiView.onWindow = nil
        coordinator.detach()
    }
}

final class AppPrivacyWindowProbe: UIView {
    var onWindow: ((UIWindow) -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Un fullScreenCover peut retirer temporairement la vue présentatrice
        // de sa fenêtre. La protection doit survivre à ce retrait temporaire.
        if let window { onWindow?(window) }
    }
}

/// Attach to a sensitive presentation, not to the account's lock preference.
/// The marker survives temporary presenter removal (for example a full-screen
/// cover) and is released when SwiftUI dismantles this presentation.
struct AppSensitiveContentMarker: UIViewRepresentable {
    func makeCoordinator() -> AppSensitiveContentLease { AppSensitiveContentLease() }

    func makeUIView(context: Context) -> AppPrivacyWindowProbe {
        let view = AppPrivacyWindowProbe()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.accessibilityElementsHidden = true
        view.onWindow = { [weak lease = context.coordinator] window in lease?.attach(to: window) }
        return view
    }

    func updateUIView(_ view: AppPrivacyWindowProbe, context: Context) {
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    static func dismantleUIView(_ view: AppPrivacyWindowProbe, coordinator: AppSensitiveContentLease) {
        view.onWindow = nil
        coordinator.release()
    }
}

@MainActor
final class AppSensitiveContentLease {
    private let markerID = UUID()
    private var state: AppSensitiveSceneState?

    func attach(to window: UIWindow) {
        guard let scene = window.windowScene else { return }
        let next = AppSensitiveSceneState.shared(for: scene)
        guard state !== next else { return }
        release()
        state = next
        next.add(markerID)
    }

    func release() {
        state?.remove(markerID)
        state = nil
    }

    deinit {
        // Normal teardown is synchronous through dismantleUIView. This fallback
        // also releases a lease if a containing presentation is discarded early.
        let state = state
        let markerID = markerID
        Task { @MainActor in state?.remove(markerID) }
    }
}

/// One state per UIWindowScene. Weak registry entries retain neither a closed
/// scene nor its coordinator; multiple sheets/windows contribute separate IDs.
@MainActor
final class AppSensitiveSceneState {
    private struct WeakState { weak var value: AppSensitiveSceneState? }
    private struct WeakCoordinator { weak var value: AppPrivacyShieldCoordinator? }
    private static var states: [ObjectIdentifier: WeakState] = [:]
    private weak var scene: UIWindowScene?
    private var markers: Set<UUID> = []
    private var coordinators: [ObjectIdentifier: WeakCoordinator] = [:]
    var hasSensitiveContent: Bool { !markers.isEmpty }

    static func shared(for scene: UIWindowScene) -> AppSensitiveSceneState {
        states = states.filter { $0.value.value != nil }
        let key = ObjectIdentifier(scene)
        if let existing = states[key]?.value, existing.scene === scene { return existing }
        let state = AppSensitiveSceneState()
        state.scene = scene
        states[key] = WeakState(value: state)
        return state
    }

    func add(_ markerID: UUID) {
        guard markers.insert(markerID).inserted else { return }
        notify()
    }

    func remove(_ markerID: UUID) {
        guard markers.remove(markerID) != nil else { return }
        notify()
    }

    func observe(_ coordinator: AppPrivacyShieldCoordinator) {
        coordinators[ObjectIdentifier(coordinator)] = WeakCoordinator(value: coordinator)
        coordinator.sensitiveContentDidChange(hasSensitiveContent)
    }

    func removeObserver(_ coordinator: AppPrivacyShieldCoordinator) {
        coordinators.removeValue(forKey: ObjectIdentifier(coordinator))
    }

    private func notify() {
        coordinators = coordinators.filter { $0.value.value != nil }
        for coordinator in coordinators.values { coordinator.value?.sensitiveContentDidChange(hasSensitiveContent) }
    }
}

@MainActor
final class AppPrivacyShieldCoordinator {
    private let lock: AppLockController
    private let presentation = AppPrivacyPresentation()
    private weak var scene: UIWindowScene?
    private weak var previousKeyWindow: UIWindow?
    private var protectedWindows: [ObjectIdentifier: ProtectedWindowState] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
    private var authenticated = false
    private var enabled = false
    private var locked: Bool
    private var appBackgrounded: Bool
    private var sceneActive = false
    private var sensitiveContent = false
    private var sensitiveSceneState: AppSensitiveSceneState?
    private(set) var coverWindow: UIWindow?
    private(set) var mode: AppPrivacyCoverMode = .hidden

    init(lock: AppLockController) {
        self.lock = lock
        locked = lock.isLocked
        appBackgrounded = lock.isInBackground
        lock.$isLocked.sink { [weak self] value in
            self?.locked = value
            self?.refresh()
        }.store(in: &subscriptions)
        lock.$isInBackground.sink { [weak self] value in
            self?.appBackgrounded = value
            self?.refresh()
        }.store(in: &subscriptions)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func configure(authenticated: Bool, enabled: Bool, colorScheme: ColorScheme) {
        self.authenticated = authenticated
        self.enabled = enabled
        if presentation.colorScheme != colorScheme { presentation.colorScheme = colorScheme }
        coverWindow?.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        refresh()
    }

    func attach(to sourceWindow: UIWindow) {
        guard let scene = sourceWindow.windowScene, sourceWindow !== coverWindow else { return }
        guard self.scene !== scene else { refresh(); return }
        detach()
        self.scene = scene
        sceneActive = scene.activationState == .foregroundActive
        let cover = AppPrivacyWindow(windowScene: scene)
        cover.windowLevel = .alert + 1
        cover.backgroundColor = .systemBackground
        cover.isOpaque = true
        cover.accessibilityViewIsModal = true
        cover.overrideUserInterfaceStyle = presentation.colorScheme == .dark ? .dark : .light
        let host = AppPrivacyHostingController(rootView: AppPrivacyCover(presentation: presentation, lock: lock))
        host.view.backgroundColor = .systemBackground
        host.view.isOpaque = true
        host.view.accessibilityViewIsModal = true
        host.view.accessibilityIdentifier = "app-privacy-cover"
        cover.rootViewController = host
        coverWindow = cover
        sensitiveSceneState = AppSensitiveSceneState.shared(for: scene)
        sensitiveSceneState?.observe(self)
        observe(UIScene.willDeactivateNotification, object: scene) { $0.sceneWillDeactivate() }
        observe(UIScene.didEnterBackgroundNotification, object: scene) { $0.sceneWillDeactivate() }
        observe(UIScene.didActivateNotification, object: scene) { $0.sceneDidActivate() }
        observe(UIScene.didDisconnectNotification, object: scene) { $0.detach() }
        // Les présentations de certaines bibliothèques créent une autre fenêtre.
        // Appliquer aussi le masque d'accessibilité à ces nouvelles fenêtres.
        for name in [UIWindow.didBecomeVisibleNotification, UIWindow.didBecomeKeyNotification] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let window = notification.object as? UIWindow else { return }
                MainActor.assumeIsolated {
                    guard let self, window !== self.coverWindow, window.windowScene === self.scene,
                          self.mode != .hidden else { return }
                    self.protectUnderlyingWindows()
                    if window.isKeyWindow, let cover = self.coverWindow, window.windowLevel < cover.windowLevel {
                        self.previousKeyWindow = window
                        cover.makeKey()
                    }
                }
            }
            observers.append(observer)
        }
        refresh()
    }

    /// Appelé synchronement par willDeactivate, avant l'aperçu du sélecteur.
    /// Une interruption Face ID garde la même vue verrouillée et son invite.
    func sceneWillDeactivate() {
        sceneActive = false
        refresh()
    }

    func sceneDidActivate() {
        sceneActive = true
        refresh()
    }

    func sensitiveContentDidChange(_ presented: Bool) {
        sensitiveContent = presented
        refresh()
    }

    func detach() {
        sensitiveSceneState?.removeObserver(self)
        sensitiveSceneState = nil
        sensitiveContent = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        hideCover()
        coverWindow?.rootViewController = nil
        coverWindow = nil
        scene = nil
        mode = .hidden
    }

    private func observe(_ name: Notification.Name, object: AnyObject,
                         action: @escaping @MainActor (AppPrivacyShieldCoordinator) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        })
    }

    private func refresh() {
        guard let coverWindow, let scene else { return }
        let next = AppPrivacyCoverMode.resolve(authenticated: authenticated, enabled: enabled,
            locked: locked, sceneActive: sceneActive, appBackgrounded: appBackgrounded,
            sensitivePresented: sensitiveContent)
        let changed = mode != next
        mode = next
        if presentation.mode != next { presentation.mode = next }
        UIView.performWithoutAnimation {
            coverWindow.frame = scene.coordinateSpace.bounds
            if next == .hidden {
                hideCover()
            } else {
                protectUnderlyingWindows()
                if coverWindow.isHidden {
                    previousKeyWindow = scene.windows.first { $0 !== coverWindow && $0.isKeyWindow }
                    coverWindow.makeKeyAndVisible()
                }
                // Layout natif immédiat : aucune transition/fondu ne dévoile le
                // contenu pendant une capture effectuée à la fin du callback.
                coverWindow.rootViewController?.view.layoutIfNeeded()
                coverWindow.layoutIfNeeded()
            }
        }
        if changed, sceneActive {
            UIAccessibility.post(notification: .screenChanged,
                argument: next == .hidden ? previousKeyWindow?.rootViewController?.view : coverWindow.rootViewController?.view)
        }
    }

    private func protectUnderlyingWindows() {
        guard let scene, let coverWindow else { return }
        for window in scene.windows where window !== coverWindow && window.windowLevel < coverWindow.windowLevel {
            let id = ObjectIdentifier(window)
            if protectedWindows[id] == nil {
                protectedWindows[id] = ProtectedWindowState(window)
                // Ferme le clavier et retire le premier répondant privé ; les
                // textes saisis, contrôleurs et tâches restent intacts.
                window.endEditing(true)
            }
            window.isUserInteractionEnabled = false
            window.accessibilityElementsHidden = true
        }
    }

    private func hideCover() {
        let shouldRestoreKey = coverWindow?.isKeyWindow == true
        coverWindow?.isHidden = true
        for state in protectedWindows.values { state.restore() }
        protectedWindows.removeAll()
        if shouldRestoreKey, let previousKeyWindow, !previousKeyWindow.isHidden {
            previousKeyWindow.makeKey()
        }
    }

    @MainActor
    private struct ProtectedWindowState {
        weak var window: UIWindow?
        let interaction: Bool
        let accessibilityHidden: Bool

        init(_ window: UIWindow) {
            self.window = window
            interaction = window.isUserInteractionEnabled
            accessibilityHidden = window.accessibilityElementsHidden
        }

        func restore() {
            window?.isUserInteractionEnabled = interaction
            window?.accessibilityElementsHidden = accessibilityHidden
        }
    }
}

private final class AppPrivacyWindow: UIWindow {
    override var canBecomeKey: Bool { true }
    override func accessibilityPerformEscape() -> Bool { true }
    override func layoutSubviews() {
        if let windowScene, frame != windowScene.coordinateSpace.bounds {
            frame = windowScene.coordinateSpace.bounds
        }
        super.layoutSubviews()
    }
}

private final class AppPrivacyHostingController: UIHostingController<AppPrivacyCover> {
    override var prefersStatusBarHidden: Bool { true }
    override func accessibilityPerformEscape() -> Bool { true }
}

@MainActor
private final class AppPrivacyPresentation: ObservableObject {
    @Published var mode: AppPrivacyCoverMode = .hidden
    @Published var colorScheme: ColorScheme = .light
}

private struct AppPrivacyCover: View {
    @ObservedObject var presentation: AppPrivacyPresentation
    let lock: AppLockController

    var body: some View {
        ZStack {
            // Fond intégralement opaque, même avant le premier rendu SwiftUI.
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if presentation.mode == .locked {
                AppLockScreen(lock: lock)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 44))
                        .accessibilityHidden(true)
                    Text("SignalQuest").font(.title2.bold())
                    Text("Contenu masqué").font(.body)
                }
            }
        }
        .environment(\.colorScheme, presentation.colorScheme)
        .transaction { $0.animation = nil }
    }
}
