import AVFoundation
import SwiftUI
import UIKit

/// Lecteur du QR v3 qu'affiche un appareil à approuver (§2.3), navigateur
/// compris : la caméra ne sert qu'à lire ce code, rien n'est enregistré. Sans
/// caméra ou sans autorisation, l'écran le dit, et la saisie du contenu du
/// code reste possible sur l'écran des appareils.
struct E2EEV2ApprovalScannerView: View {
    enum CameraAccess: Equatable {
        case checking
        case granted
        case denied
        case unavailable
    }

    let onCode: (String) -> Void
    @State private var access: CameraAccess = .checking
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .checking:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .granted:
                    E2EEV2QRCameraView(
                        onCode: { code in
                            onCode(code)
                            dismiss()
                        },
                        onUnavailable: { access = .unavailable }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("Vise le code affiché sur l’appareil à approuver.")
                            .font(SQType.body)
                            .foregroundStyle(SQColor.label)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(SQSpace.md)
                            .background(SQColor.surface, in: Capsule(style: .continuous))
                            .padding(SQSpace.lg)
                    }
                case .denied:
                    unavailableMessage(
                        String(localized: "SignalQuest n’a pas accès à la caméra. Autorise-la dans les Réglages d’iOS, ou colle le contenu du code sur l’écran des appareils."),
                        showsSettings: true
                    )
                case .unavailable:
                    unavailableMessage(
                        String(localized: "Aucune caméra n’est disponible. Colle le contenu du code sur l’écran des appareils."),
                        showsSettings: false
                    )
                }
            }
            .navigationTitle(Text("Approuver un appareil"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Annuler")) { dismiss() }
                }
            }
        }
        .task { access = await Self.cameraAccess() }
    }

    private func unavailableMessage(_ message: String, showsSettings: Bool) -> some View {
        VStack(spacing: SQSpace.lg) {
            Label(message, systemImage: "camera.fill")
                .font(SQType.body)
                .foregroundStyle(SQColor.label)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("approvalScanner.unavailable")
            if showsSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                GradientButton(String(localized: "Ouvrir les Réglages"), style: .secondary) { openURL(url) }
            }
        }
        .padding(SQSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Demande l'accès au premier usage seulement ; un refus renvoie aux Réglages.
    static func cameraAccess() async -> CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: return .denied
        }
    }
}

private struct E2EEV2QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> E2EEV2QRScannerController {
        let controller = E2EEV2QRScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: E2EEV2QRScannerController, context: Context) {}
}

/// Session de capture limitée aux QR. Démarrée et arrêtée hors du fil
/// principal, comme le demande AVFoundation ; le premier code lu est rendu une
/// seule fois.
@MainActor
final class E2EEV2QRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    /// AVCaptureSession se pilote depuis une file dédiée.
    private struct Session: @unchecked Sendable {
        let capture = AVCaptureSession()
    }

    var onCode: ((String) -> Void)?
    var onUnavailable: (() -> Void)?
    private let session = Session()
    private let sessionQueue = DispatchQueue(label: "fr.signalquest.approval-scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let capture = session.capture
        let output = AVCaptureMetadataOutput()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              capture.canAddInput(input) else {
            reportUnavailable()
            return
        }
        capture.addInput(input)
        guard capture.canAddOutput(output) else {
            reportUnavailable()
            return
        }
        capture.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: capture)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        sessionQueue.async { if !session.capture.isRunning { session.capture.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        sessionQueue.async { if session.capture.isRunning { session.capture.stopRunning() } }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let value = metadataObjects
            .compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
            .first else { return }
        // Délégué posé sur la file principale.
        MainActor.assumeIsolated { deliver(value) }
    }

    private func deliver(_ value: String) {
        guard !delivered else { return }
        delivered = true
        Haptics.success()
        onCode?(value)
    }

    /// Hors de la mise à jour de la vue SwiftUI qui a créé ce contrôleur.
    private func reportUnavailable() {
        Task { @MainActor [weak self] in self?.onUnavailable?() }
    }
}

/// Ce que l'aperçu d'approbation dit d'un navigateur (§2.7). Sa plateforme vient
/// du QR v3 ; le nom qu'il se donne n'est qu'un nom, ramené à une ligne courte
/// pour qu'il ne puisse rien glisser d'autre sous le titre.
enum E2EEV2ApprovalCopy {
    static let maxNameLength = 60

    static func quotedName(platform: String, label: String?, bundle: Bundle = .main) -> String? {
        guard platform == "web", let label else { return nil }
        let flattened = String(label.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : Character($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return nil }
        let name = String(flattened.prefix(maxNameLength))
        return String(localized: "« \(name) »", bundle: bundle)
    }

    static func browserNotice(bundle: Bundle = .main) -> String {
        String(localized: "Ce navigateur pourra lire tes conversations chiffrées et y participer, sauf celles qui excluent les navigateurs. Il ne détient pas la clé de ton compte : tu pourras le révoquer depuis ce téléphone.", bundle: bundle)
    }
}
