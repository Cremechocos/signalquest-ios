import XCTest
import UIKit
@testable import SignalQuest

final class AppPrivacyCoverPolicyTests: XCTestCase {
    func testLockedContentStaysCoveredDuringTheBiometricSystemInterruption() {
        for active in [false, true] {
            XCTAssertEqual(AppPrivacyCoverMode.resolve(authenticated: true, enabled: true, locked: true,
                sceneActive: active, appBackgrounded: false), .locked)
        }
    }

    func testInactiveSceneIsObscuredEvenWhenGraceHasNotLockedTheApp() {
        XCTAssertEqual(AppPrivacyCoverMode.resolve(authenticated: true, enabled: true, locked: false,
            sceneActive: false, appBackgrounded: false), .obscured)
    }

    func testForegroundWaitsForTheControllerToEvaluateTheBackgroundDeadline() {
        XCTAssertEqual(AppPrivacyCoverMode.resolve(authenticated: true, enabled: true, locked: false,
            sceneActive: true, appBackgrounded: true), .obscured)
        XCTAssertEqual(AppPrivacyCoverMode.resolve(authenticated: true, enabled: true, locked: true,
            sceneActive: true, appBackgrounded: false), .locked)
    }

    func testNormalUnlockedContentAndLoginRemainAccessible() {
        XCTAssertEqual(AppPrivacyCoverMode.resolve(authenticated: true, enabled: true, locked: false,
            sceneActive: true, appBackgrounded: false), .hidden)
        XCTAssertEqual(AppPrivacyCoverMode.resolve(authenticated: true, enabled: false, locked: false,
            sceneActive: false, appBackgrounded: true), .hidden)
        XCTAssertEqual(AppPrivacyCoverMode.resolve(authenticated: false, enabled: true, locked: true,
            sceneActive: false, appBackgrounded: true), .hidden)
    }
}

@MainActor
final class AppPrivacyShieldTests: XCTestCase {
    func testLockCoversPresentedSheetWithoutRemovingItsControllerOrDraft() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let sheet = UIViewController()
        sheet.modalPresentationStyle = .pageSheet
        let draft = UITextField(frame: CGRect(x: 20, y: 20, width: 200, height: 44))
        draft.text = "synthetic-private-draft"
        sheet.view.addSubview(draft)
        await fixture.present(sheet)
        fixture.lock.lockOnActivationIfNeeded()

        let cover = try XCTUnwrap(fixture.coordinator.coverWindow)
        XCTAssertFalse(cover.isHidden)
        XCTAssertGreaterThan(cover.windowLevel, fixture.window.windowLevel)
        XCTAssertTrue(cover.isOpaque)
        XCTAssertEqual(cover.frame, fixture.window.windowScene?.coordinateSpace.bounds)
        XCTAssertFalse(fixture.window.isUserInteractionEnabled)
        XCTAssertTrue(fixture.window.accessibilityElementsHidden)
        XCTAssertTrue(cover.accessibilityViewIsModal)
        XCTAssertTrue(cover.rootViewController?.view.accessibilityViewIsModal == true)
        XCTAssertTrue(fixture.host.presentedViewController === sheet)
        XCTAssertEqual(draft.text, "synthetic-private-draft")

        fixture.lock.reset()
        XCTAssertTrue(cover.isHidden)
        XCTAssertTrue(fixture.window.isUserInteractionEnabled)
        XCTAssertFalse(fixture.window.accessibilityElementsHidden)
        XCTAssertTrue(fixture.host.presentedViewController === sheet)
        XCTAssertEqual(draft.text, "synthetic-private-draft")
    }

    func testFullScreenPresentationRemainsMountedBelowTheLockWindow() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let fullScreen = UIViewController()
        fullScreen.modalPresentationStyle = .fullScreen
        await fixture.present(fullScreen)
        fixture.lock.lockOnActivationIfNeeded()

        XCTAssertEqual(fixture.coordinator.mode, .locked)
        XCTAssertFalse(try XCTUnwrap(fixture.coordinator.coverWindow).isHidden)
        XCTAssertTrue(fixture.host.presentedViewController === fullScreen)
        XCTAssertFalse(fixture.window.isHidden, "La fenêtre et les tâches privées restent montées")
        fixture.lock.reset()
        XCTAssertTrue(fixture.host.presentedViewController === fullScreen)
    }

    func testWillDeactivateSynchronouslyObscuresSnapshotDuringGrace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertEqual(fixture.coordinator.mode, .hidden)
        fixture.coordinator.sceneWillDeactivate()
        XCTAssertEqual(fixture.coordinator.mode, .obscured)
        XCTAssertFalse(try XCTUnwrap(fixture.coordinator.coverWindow).isHidden)
        XCTAssertFalse(fixture.window.isUserInteractionEnabled)
        XCTAssertTrue(fixture.window.accessibilityElementsHidden)
        XCTAssertFalse(fixture.lock.isLocked, "Masquer un aperçu ne doit pas supprimer la grâce")
        fixture.coordinator.sceneDidActivate()
        XCTAssertEqual(fixture.coordinator.mode, .hidden)
        XCTAssertTrue(fixture.window.isUserInteractionEnabled)
    }

    func testDetachRestoresExistingWindowFlagsExactly() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.window.isUserInteractionEnabled = false
        fixture.window.accessibilityElementsHidden = true
        fixture.lock.lockOnActivationIfNeeded()
        fixture.coordinator.detach()
        XCTAssertNil(fixture.coordinator.coverWindow)
        XCTAssertFalse(fixture.window.isUserInteractionEnabled)
        XCTAssertTrue(fixture.window.accessibilityElementsHidden)
    }

    func testWindowCreatedWhileLockedIsAlsoBlockedAndRestored() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.lock.lockOnActivationIfNeeded()
        let extra = UIWindow(windowScene: try XCTUnwrap(fixture.window.windowScene))
        extra.rootViewController = UIViewController()
        extra.windowLevel = .normal + 1
        extra.makeKeyAndVisible()
        defer { extra.isHidden = true }
        XCTAssertFalse(extra.isUserInteractionEnabled)
        XCTAssertTrue(extra.accessibilityElementsHidden)
        XCTAssertTrue(fixture.coordinator.coverWindow?.isKeyWindow == true)
        fixture.lock.reset()
        XCTAssertTrue(extra.isUserInteractionEnabled)
        XCTAssertFalse(extra.accessibilityElementsHidden)
    }

    @MainActor
    private final class Fixture {
        let lock: AppLockController
        let coordinator: AppPrivacyShieldCoordinator
        let window: UIWindow
        let host = UIViewController()
        private weak var originalKeyWindow: UIWindow?

        init() throws {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                throw XCTSkip("Une UIWindowScene active du runner est requise pour la recette de présentation UIKit")
            }
            originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
            lock = AppLockController(settings: { .init(enabled: true, lockGrace: 60, autoLogout: 0) },
                authenticate: { _, _ in false })
            coordinator = AppPrivacyShieldCoordinator(lock: lock)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            host.view.backgroundColor = .systemBackground
            window.makeKeyAndVisible()
            coordinator.configure(authenticated: true, enabled: true, colorScheme: .light)
            coordinator.attach(to: window)
        }

        func present(_ viewController: UIViewController) async {
            await withCheckedContinuation { continuation in
                host.present(viewController, animated: false) { continuation.resume() }
            }
        }

        func close() {
            coordinator.detach()
            host.dismiss(animated: false)
            window.isHidden = true
            if let originalKeyWindow, !originalKeyWindow.isHidden { originalKeyWindow.makeKey() }
        }
    }
}
