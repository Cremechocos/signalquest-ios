import SwiftUI

/// In-call screen, driven by `CallManager`. Presented app-wide while a call is
/// active (outgoing or an answered incoming call). The system CallKit UI handles
/// the incoming ring; this screen is the in-app connected experience.
struct CallScreen: View {
    @ObservedObject var callManager: CallManager
    @ObservedObject var liveKit: LiveKitClient

    init(callManager: CallManager) {
        _callManager = ObservedObject(wrappedValue: callManager)
        _liveKit = ObservedObject(wrappedValue: callManager.liveKit)
    }

    var body: some View {
        ZStack {
            callBackground
            VStack(spacing: SQSpace.xxl) {
                Spacer()
                centralAvatar
                if let handle = callManager.activeCall?.handle, !handle.isEmpty {
                    Text(handle)
                        .font(SQType.display)
                        .foregroundStyle(.white)
                }
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: (callManager.activeCall?.hasVideo ?? false) ? "video.fill" : "phone.fill")
                        .foregroundStyle(SQGradient.signal)
                        .accessibilityHidden(true)
                    statusText
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
                Spacer()
                controls
            }
            .padding(SQSpace.xxl)
        }
        .preferredColorScheme(.dark)
    }

    /// Déclinaison sombre du fond DA (mêmes teintes que le hero dark).
    private var callBackground: some View {
        LinearGradient(
            colors: [
                Color(hex: 0x08080F),
                Color(hex: 0x150E1E),
                Color(hex: 0x1C0F18)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var centralAvatar: some View {
        let handle = callManager.activeCall?.handle
        return SQAvatar(url: nil, name: (handle?.isEmpty == false ? handle! : "?"), size: 120)
            .padding(6)
            .overlay {
                Circle().stroke(SQGradient.signal, lineWidth: 3)
            }
            .shadow(color: SQBrand.signatureStart.opacity(0.35), radius: 28, y: 10)
    }

    @ViewBuilder
    private var statusText: some View {
        switch liveKit.state {
        case .idle: Text("Préparation…")
        case .connecting: Text("Connexion…")
        case .connected: Text("En appel")
        case .failed(let message): Text("Erreur : \(message)")
        case .ended: Text("Appel terminé")
        }
    }

    private var controls: some View {
        HStack(spacing: SQSpace.xl + 2) {
            controlButton(systemImage: liveKit.isMicMuted ? "mic.slash.fill" : "mic.fill", tint: liveKit.isMicMuted ? SQColor.danger : .white) {
                callManager.setMuted(!liveKit.isMicMuted)
            }
            .accessibilityLabel(liveKit.isMicMuted ? "Réactiver le micro" : "Couper le micro")

            if callManager.activeCall?.hasVideo == true {
                controlButton(systemImage: liveKit.isCameraOn ? "video.fill" : "video.slash.fill", tint: liveKit.isCameraOn ? SQColor.success : .white) {
                    liveKit.toggleCamera()
                }
                .accessibilityLabel(liveKit.isCameraOn ? "Couper la caméra" : "Activer la caméra")
            }

            controlButton(systemImage: "phone.down.fill", tint: SQColor.danger, large: true) {
                callManager.endActiveCall()
            }
            .accessibilityLabel("Raccrocher")
        }
    }

    /// Pastille glass des contrôles in-call.
    private func controlButton(systemImage: String, tint: Color, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: large ? 28 : 22, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: large ? 78 : 62, height: large ? 78 : 62)
                .background(.ultraThinMaterial, in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.14), lineWidth: 1) }
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }
}
