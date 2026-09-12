import XCTest
import SwiftUI
@testable import SignalQuest

@MainActor
final class PasswordResetPresentationTests: XCTestCase {
    private func settle(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testRecoveryOpensAboveAnExistingSheetWithoutDestroyingItsDraft() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let existing = UIViewController()
        let draft = UITextField()
        draft.text = "synthetic draft to retain"
        existing.view.addSubview(draft)
        fixture.root.present(existing, animated: false)
        let route = PasswordResetRoute(request: PasswordResetRequest(token: "synthetic-token"))
        fixture.configure(route: route)
        try await settle { existing.presentedViewController != nil && fixture.isSettled }
        XCTAssertTrue(fixture.root.presentedViewController === existing)
        XCTAssertEqual(draft.text, "synthetic draft to retain")
        fixture.configure(route: nil)
        try await settle { existing.presentedViewController == nil && fixture.isSettled }
        XCTAssertTrue(fixture.root.presentedViewController === existing)
        XCTAssertEqual(draft.text, "synthetic draft to retain")
    }

    func testPendingRecoveryWaitsForTheInitialPresentationGate() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let route = PasswordResetRoute(content: .invalid)
        fixture.configure(route: route, canPresent: false)
        XCTAssertNil(fixture.root.presentedViewController)
        fixture.configure(route: route, canPresent: true)
        try await settle { fixture.root.presentedViewController != nil && fixture.isSettled }
    }

    func testPrivacyLockKeepsAnExistingDraftMountedButForcedUpdateDismissesRecovery() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let route = PasswordResetRoute(request: PasswordResetRequest(token: "synthetic-token"))
        fixture.configure(route: route)
        try await settle { fixture.root.presentedViewController != nil && fixture.isSettled }
        let presented = fixture.root.presentedViewController
        fixture.configure(route: route, canPresent: false)
        XCTAssertTrue(fixture.root.presentedViewController === presented)
        fixture.configure(route: route, canPresent: false, mustDismiss: true)
        try await settle { fixture.root.presentedViewController == nil && fixture.isSettled }
        XCTAssertTrue(fixture.closedIDs.isEmpty, "A mandatory gate must not consume the pending link")
    }

    func testMandatoryGateDuringRecoveryAppearanceRetainsThePendingLink() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let route = PasswordResetRoute(content: .invalid)
        fixture.configure(route: route)
        let host = try XCTUnwrap(fixture.root.presentedViewController)
        XCTAssertTrue(host.isBeingPresented || host.transitionCoordinator != nil,
                      "The mandatory gate must arrive during the presentation, without an intervening await")
        fixture.configure(route: route, canPresent: false, mustDismiss: true)
        try await settle { fixture.root.presentedViewController == nil && fixture.isSettled }
        XCTAssertTrue(fixture.closedIDs.isEmpty)
        XCTAssertEqual(fixture.coordinator.configuration?.route?.id, route.id)
    }

    func testDelayedDismissalCannotConsumeAnIncomingDifferentLink() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let old = PasswordResetRoute(request: PasswordResetRequest(token: "synthetic-old"))
        fixture.configure(route: old)
        try await settle { fixture.root.presentedViewController != nil && fixture.isSettled }
        let host = try XCTUnwrap(fixture.root.presentedViewController)
        let presentation = try XCTUnwrap(host.presentationController)
        fixture.coordinator.presentationControllerWillDismiss(presentation)
        let incoming = PasswordResetRoute(request: PasswordResetRequest(token: "synthetic-new"))
        fixture.configure(route: incoming)
        host.dismiss(animated: false)
        fixture.coordinator.presentationControllerDidDismiss(presentation)
        XCTAssertEqual(fixture.closedIDs, [old.id])
        try await settle { fixture.root.presentedViewController != nil && fixture.isSettled }
    }

    func testRecoveryReappearsAfterItsChallengeAncestorIsDismissedProgrammatically() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let challenge = UIViewController()
        fixture.root.present(challenge, animated: false)
        let route = PasswordResetRoute(request: PasswordResetRequest(token: "synthetic-token"))
        fixture.configure(route: route)
        try await settle { challenge.presentedViewController != nil && fixture.isSettled }
        let host = try XCTUnwrap(challenge.presentedViewController)
        let fields = textFields(in: host.view)
        XCTAssertGreaterThanOrEqual(fields.filter(\.isSecureTextEntry).count, 2)
        let password = try XCTUnwrap(fields.first(where: \.isSecureTextEntry))
        password.text = "synthetic-draft-password"
        password.sendActions(for: .editingChanged)
        fixture.root.dismiss(animated: false)
        // No explicit refresh: an ancestor can disappear without a route/state mutation.
        try await settle { fixture.root.presentedViewController === host && host.view.window != nil && fixture.isSettled }
        XCTAssertTrue(fixture.closedIDs.isEmpty)
        XCTAssertEqual(fixture.coordinator.configuration?.route?.id, route.id)
        XCTAssertEqual(textFields(in: host.view).first(where: \.isSecureTextEntry)?.text, "synthetic-draft-password")
    }

    func testNewRecoveryLinkSurvivesProgrammaticAncestorDismissal() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        let challenge = UIViewController()
        fixture.root.present(challenge, animated: false)
        fixture.configure(route: PasswordResetRoute(request: PasswordResetRequest(token: "synthetic-old")))
        try await settle { challenge.presentedViewController != nil && fixture.isSettled }
        fixture.root.dismiss(animated: true)
        let incoming = PasswordResetRoute(request: PasswordResetRequest(token: "synthetic-new"))
        fixture.configure(route: incoming)
        try await settle {
            guard let shown = fixture.root.presentedViewController else { return false }
            return shown !== challenge && shown.view.window != nil && fixture.isSettled
        }
        XCTAssertEqual(fixture.coordinator.configuration?.route?.id, incoming.id)
        XCTAssertTrue(fixture.closedIDs.isEmpty, "An old dismissal cannot consume either pending route")
    }

    func testCoveringRecoveryWithAnotherControllerDoesNotDetachIt() async throws {
        let fixture = try Fixture()
        addTeardownBlock { await fixture.close() }
        fixture.configure(route: PasswordResetRoute(content: .invalid))
        try await settle { fixture.root.presentedViewController != nil && fixture.isSettled }
        let host = try XCTUnwrap(fixture.root.presentedViewController)
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        host.present(cover, animated: false)
        fixture.coordinator.refresh()
        XCTAssertTrue(fixture.root.presentedViewController === host)
        XCTAssertTrue(host.presentedViewController === cover)
        XCTAssertTrue(fixture.closedIDs.isEmpty)
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    @MainActor
    private final class Fixture {
        let window: UIWindow
        let root = UIViewController()
        let anchor = PasswordResetPresentation.Anchor()
        let coordinator = PasswordResetPresentation.Coordinator()
        let session = AuthSessionViewModel(service: MockAuthService())
        var closedIDs: [UUID] = []
        private weak var previousKeyWindow: UIWindow?

        init() throws {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
                throw XCTSkip("Une scène UIKit active est nécessaire pour la recette du présentateur")
            }
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = root
            window.makeKeyAndVisible()
            root.view.addSubview(anchor)
            coordinator.anchor = anchor
        }

        func configure(route: PasswordResetRoute?, canPresent: Bool = true, mustDismiss: Bool = false) {
            coordinator.configuration = PasswordResetPresentation(route: route, canPresent: canPresent,
                mustDismiss: mustDismiss, session: session, locale: Locale(identifier: "en"),
                onClose: { [weak self] in self?.closedIDs.append($0) }, onSuccess: { _ in })
            coordinator.refresh()
        }

        var isSettled: Bool { Self.hierarchy(root).allSatisfy { Self.hasFinishedTransition($0) } }

        private static func hierarchy(_ controller: UIViewController) -> [UIViewController] {
            [controller] + controller.children.flatMap { hierarchy($0) }
                + (controller.presentedViewController.map { hierarchy($0) } ?? [])
        }

        private static func hasFinishedTransition(_ controller: UIViewController) -> Bool {
            !controller.isBeingPresented && !controller.isBeingDismissed && controller.transitionCoordinator == nil
        }

        private func awaitTransitions(_ controllers: [UIViewController]) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !controllers.allSatisfy({ Self.hasFinishedTransition($0) }), ContinuousClock.now < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertTrue(controllers.allSatisfy { Self.hasFinishedTransition($0) }, "Fixture cleanup must finish every active transition")
        }

        func close() async {
            // Teardown runs even after a throwing assertion. Stop route-driven
            // re-presentation, then let any animation already in flight finish.
            coordinator.configuration = nil
            let controllers = Self.hierarchy(root)
            await awaitTransitions(controllers)
            coordinator.detach()
            await awaitTransitions(controllers)
            if root.presentedViewController != nil {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    root.dismiss(animated: false) { continuation.resume() }
                }
            }
            await awaitTransitions(controllers)
            window.isHidden = true
            window.rootViewController = nil
            if let previousKeyWindow, !previousKeyWindow.isHidden { previousKeyWindow.makeKey() }
        }
    }
}
