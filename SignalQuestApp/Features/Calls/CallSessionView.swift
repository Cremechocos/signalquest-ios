import SwiftUI
#if canImport(LiveKit)
import LiveKit
#endif
#if os(iOS)
import UIKit
#endif

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
            VStack(spacing: SQSpace.lg) {
                callHeader
                if callManager.activeCall?.hasVideo == true {
                    videoStage
                } else {
                    Spacer(minLength: SQSpace.lg)
                    centralAvatar
                    Spacer(minLength: SQSpace.lg)
                }
                if let error = liveKit.mediaErrorMessage {
                    Text(error)
                        .font(SQType.caption)
                        .foregroundStyle(SQColor.danger)
                        .multilineTextAlignment(.center)
                }
                controls
                Text("Audio et vidéo transportés par LiveKit.")
                    .font(SQType.micro)
                    .foregroundStyle(SQColor.labelTertiary)
                    .accessibilityLabel("Les appels utilisent le transport LiveKit")
            }
            .padding(.horizontal, SQSpace.lg)
            .padding(.vertical, SQSpace.xl)
        }
        .preferredColorScheme(.dark)
    }

    private var callHeader: some View {
        VStack(spacing: SQSpace.sm) {
            if let handle = callManager.activeCall?.handle, !handle.isEmpty {
                Text(handle)
                    .font(SQType.display)
                    .foregroundStyle(SQColor.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            HStack(spacing: SQSpace.sm) {
                statusGlyph
                statusText
            }
            .font(SQFont.body(14, .semibold))
            .foregroundStyle(SQColor.labelSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Fond nuit chaude de la DA Crème : l'écran est forcé en sombre, `SQColor.bg`
    /// y résout le brun nuit — plus de dégradé décoratif.
    private var callBackground: some View {
        SQColor.bg.ignoresSafeArea()
    }

    private var centralAvatar: some View {
        let handle = callManager.activeCall?.handle
        return SQAvatar(url: nil, name: (handle?.isEmpty == false ? handle! : "?"), size: 120)
            .padding(6)
            .overlay {
                Circle().stroke(SQColor.brandRed, lineWidth: 3)
            }
    }

    @ViewBuilder
    private var videoStage: some View {
#if canImport(LiveKit)
        ZStack(alignment: .topTrailing) {
            if liveKit.remoteVideos.count > 1 {
                remoteVideoGrid
            } else if let remote = liveKit.remoteVideos.first {
                videoTile(remote)
            } else {
                VStack(spacing: SQSpace.lg) {
                    centralAvatar
                    Text(liveKit.state == .connected ? "En attente de la caméra distante" : "Connexion vidéo…")
                        .font(SQType.subhead)
                        .foregroundStyle(SQColor.labelSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let local = liveKit.localVideoTrack, liveKit.isCameraOn {
                SwiftUIVideoView(local, layoutMode: .fill, mirrorMode: .mirror)
                    .frame(width: 104, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: SQRadius.md, style: .continuous))
                    .sqShadowCard()
                    .padding(SQSpace.sm)
                    .accessibilityLabel("Aperçu de ta caméra")
            }

#if os(iOS)
            PictureInPictureSourceView { view in
                liveKit.configurePictureInPicture(sourceView: view)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SQColor.surfaceMuted, in: RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: SQRadius.xl, style: .continuous))
        .accessibilityElement(children: .contain)
#else
        centralAvatar
#endif
    }

#if canImport(LiveKit)
    private var remoteVideoGrid: some View {
        GeometryReader { geometry in
            let columnCount = liveKit.remoteVideos.count > 4 ? 3 : 2
            let rowCount = max(1, (liveKit.remoteVideos.count + columnCount - 1) / columnCount)
            let spacing: CGFloat = 6
            let availableHeight = geometry.size.height - (CGFloat(rowCount - 1) * spacing) - 12
            let tileHeight = max(60, availableHeight / CGFloat(rowCount))
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: spacing),
                count: columnCount
            )

            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(liveKit.remoteVideos) { remote in
                    videoTile(remote)
                        .frame(height: tileHeight)
                }
            }
            .padding(6)
        }
    }

    private func videoTile(_ remote: LiveKitClient.RemoteVideo) -> some View {
        ZStack(alignment: .bottomLeading) {
            SwiftUIVideoView(remote.track, layoutMode: remote.isScreenShare ? .fit : .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            Text(remote.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.black.opacity(0.66), in: Capsule())
                .padding(8)
        }
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vidéo de \(remote.displayName)")
    }
#endif

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

    /// CALL-SESSION-23 : pendant l'établissement (idle/connexion), on montre un
    /// indicateur de progression au lieu d'une icône statique — l'attente réseau
    /// (initiate + handshake LiveKit) n'est pas instantanée. iOS-16-safe.
    @ViewBuilder
    private var statusGlyph: some View {
        switch liveKit.state {
        case .idle, .connecting:
            ProgressView()
                .controlSize(.small)
                .tint(SQColor.label)
                .accessibilityHidden(true)
        default:
            Image(systemName: (callManager.activeCall?.hasVideo ?? false) ? "video.fill" : "phone.fill")
                .foregroundStyle(SQColor.brandRed)
                .accessibilityHidden(true)
        }
    }

    private var controls: some View {
        VStack(spacing: SQSpace.md) {
            HStack(spacing: SQSpace.lg) {
                controlButton(systemImage: liveKit.isMicMuted ? "mic.slash.fill" : "mic.fill", tint: liveKit.isMicMuted ? SQColor.danger : SQColor.label) {
                    callManager.setMuted(!liveKit.isMicMuted)
                }
                .accessibilityLabel(liveKit.isMicMuted ? "Réactiver le micro" : "Couper le micro")

                controlButton(systemImage: liveKit.isSpeakerOn ? "speaker.wave.3.fill" : "speaker.fill", tint: liveKit.isSpeakerOn ? SQColor.success : SQColor.label) {
                    liveKit.toggleSpeaker()
                }
                .accessibilityLabel(liveKit.isSpeakerOn ? "Désactiver le haut-parleur" : "Activer le haut-parleur")

                if callManager.activeCall?.hasVideo == true {
                    controlButton(systemImage: liveKit.isCameraOn ? "video.fill" : "video.slash.fill", tint: liveKit.isCameraOn ? SQColor.success : SQColor.label) {
                        liveKit.toggleCamera()
                    }
                    .accessibilityLabel(liveKit.isCameraOn ? "Couper la caméra" : "Activer la caméra")
                }

                // Raccrocher : danger plein, icône crème (DA Crème).
                controlButton(systemImage: "phone.down.fill", tint: SQColor.onAccent, fill: SQColor.danger, large: true) {
                    callManager.endActiveCall()
                }
                .accessibilityLabel("Raccrocher")
            }

            if callManager.activeCall?.hasVideo == true {
                HStack(spacing: SQSpace.xl) {
                    controlButton(systemImage: "arrow.triangle.2.circlepath.camera", tint: SQColor.label) {
                        liveKit.switchCamera()
                    }
                    .disabled(!liveKit.isCameraOn || !liveKit.canSwitchCamera)
                    .opacity(liveKit.isCameraOn && liveKit.canSwitchCamera ? 1 : 0.4)
                    .accessibilityLabel("Changer de caméra")

                    controlButton(
                        systemImage: liveKit.isPictureInPictureActive ? "pip.exit" : "pip.enter",
                        tint: liveKit.isPictureInPictureActive ? SQColor.success : SQColor.label
                    ) {
                        liveKit.togglePictureInPicture()
                    }
                    .disabled(!liveKit.canStartPictureInPicture && !liveKit.isPictureInPictureActive)
                    .opacity(liveKit.canStartPictureInPicture || liveKit.isPictureInPictureActive ? 1 : 0.4)
                    .accessibilityLabel(liveKit.isPictureInPictureActive ? "Quitter l’image dans l’image" : "Activer l’image dans l’image")
                }
            }
        }
    }

    private func controlButton(systemImage: String, tint: Color, fill: Color = SQColor.surface, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: large ? 26 : 21, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: large ? 64 : 56, height: large ? 64 : 56)
                .background(fill, in: Circle())
                .sqShadowSoft()
        }
        .buttonStyle(SQPressButtonStyle())
    }
}

#if os(iOS)
private struct PictureInPictureSourceView: UIViewRepresentable {
    let onResolve: @MainActor (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        onResolve(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        onResolve(uiView)
    }
}
#endif
