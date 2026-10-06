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
            if callManager.activeCall == nil, let notice = callManager.endNotice {
                endStage(notice)
            } else {
                callStage
            }
        }
        .preferredColorScheme(.dark)
    }

    private var callStage: some View {
        VStack(spacing: SQSpace.lg) {
            topBar
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
            ForEach(callManager.peerNetworks.keys.sorted(), id: \.self) { identity in
                if let network = callManager.peerNetworks[identity], !network.packet.isEmpty {
                    PeerNetworkCard(
                        name: callManager.peerNetworks.count == 1 ? callManager.activeCall?.handle : nil,
                        packet: network.packet
                    )
                }
            }
            controls
            encryptionNote
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.xl)
    }

    /// Réduire : l'appel continue et un bandeau en haut de l'app permet d'y
    /// revenir. Sans ce bouton, impossible de lire un message pendant un appel.
    private var topBar: some View {
        HStack {
            if callManager.activeCall != nil {
                Button {
                    Haptics.light()
                    callManager.minimizeCallScreen()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(SQColor.label)
                        .frame(width: 44, height: 44)
                        .background(SQColor.surface, in: Circle())
                }
                .buttonStyle(SQPressButtonStyle())
                .accessibilityLabel("Réduire l’appel")
                .accessibilityHint("L’appel continue. Touche le bandeau en haut de l’écran pour revenir.")
                .accessibilityIdentifier("call.minimize")
            }
            Spacer()
        }
    }

    /// Ce que protège l'appel, dit simplement. Aucun appel n'est encore
    /// chiffré de bout en bout, même dans une conversation chiffrée (E2E-02) ;
    /// le pied de page parlait du transport « LiveKit » (SOC-13).
    private var encryptionNote: some View {
        let title: LocalizedStringKey = liveKit.isE2EEVerified
            ? "Appel chiffré de bout en bout"
            : "Appel non chiffré de bout en bout"
        return HStack(spacing: 0) {
            Label(title, systemImage: liveKit.isE2EEVerified ? "lock.fill" : "lock.open")
                .font(SQType.caption)
                .foregroundStyle(SQColor.labelSecondary)
            SQInfoButton(term: .endToEndEncryption)
        }
        .accessibilityIdentifier("call.encryption")
    }

    /// Fin d'appel expliquée : pas de réponse, ou échec dit en clair, avec
    /// « Rappeler » (SOC-13). L'écran se fermait sans rien dire.
    private func endStage(_ notice: CallManager.EndNotice) -> some View {
        VStack(spacing: SQSpace.lg) {
            Spacer(minLength: SQSpace.lg)
            SQAvatar(url: nil, name: notice.handle.isEmpty ? "?" : notice.handle, size: 120)
                .accessibilityHidden(true)
            VStack(spacing: SQSpace.sm) {
                if !notice.handle.isEmpty {
                    Text(notice.handle)
                        .font(SQType.display)
                        .foregroundStyle(SQColor.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Text(notice.title)
                    .font(SQType.heading)
                    .foregroundStyle(SQColor.label)
                if let message = notice.message {
                    Text(message)
                        .font(SQType.body)
                        .foregroundStyle(SQColor.labelSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("call.end.notice")
            Spacer(minLength: SQSpace.lg)
            HStack(alignment: .top, spacing: SQSpace.xxl) {
                labeledControl("Fermer", identifier: "call.end.close", systemImage: "xmark", tint: SQColor.label) {
                    callManager.dismissEndNotice()
                }
                if notice.conversationId != nil {
                    labeledControl(
                        "Rappeler",
                        identifier: "call.end.redial",
                        systemImage: notice.hasVideo ? "video.fill" : "phone.fill",
                        tint: SQColor.onAccent,
                        fill: SQColor.brandRed
                    ) {
                        callManager.redial()
                    }
                }
            }
        }
        .padding(.horizontal, SQSpace.lg)
        .padding(.vertical, SQSpace.xl)
        .onAppear {
#if os(iOS)
            let announcement = [notice.title, notice.message].compactMap { $0 }.joined(separator: ". ")
            UIAccessibility.post(notification: .announcement, argument: announcement)
#endif
        }
    }

    private func labeledControl(
        _ title: LocalizedStringKey,
        identifier: String,
        systemImage: String,
        tint: Color,
        fill: Color = SQColor.surface,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: SQSpace.xs) {
            controlButton(systemImage: systemImage, tint: tint, fill: fill, action: action)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
            Text(title)
                .font(SQType.micro)
                .foregroundStyle(SQColor.labelSecondary)
                .accessibilityHidden(true)
                .accessibilityIdentifier("call.end.caption")
        }
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

    /// « En appel » n'apparaît qu'une fois quelqu'un connecté, avec la durée ;
    /// avant, c'est la sonnerie. Le message brut du transport n'est plus
    /// affiché (SOC-13).
    @ViewBuilder
    private var statusText: some View {
        switch liveKit.state {
        case .idle: Text("Préparation…")
        case .connecting: Text("Connexion…")
        case .connected:
            if liveKit.isReconnecting {
                Text("Reconnexion…")
            } else if let joinedAt = liveKit.remoteJoinedAt {
                Text("En appel") + Text(verbatim: " · ") + Text(joinedAt, style: .timer).monospacedDigit()
            } else if callManager.activeCall?.isOutgoing == true {
                Text("Sonnerie…")
            } else {
                Text("Connexion…")
            }
        case .failed: Text("Appel interrompu")
        case .ended: Text("Appel terminé")
        }
    }

    private var isWaiting: Bool {
        switch liveKit.state {
        case .idle, .connecting: return true
        case .connected: return liveKit.isReconnecting || liveKit.remoteJoinedAt == nil
        case .failed, .ended: return false
        }
    }

    /// CALL-SESSION-23 : pendant l'établissement (idle/connexion), on montre un
    /// indicateur de progression au lieu d'une icône statique — l'attente réseau
    /// (initiate + handshake LiveKit) n'est pas instantanée. iOS-16-safe.
    @ViewBuilder
    private var statusGlyph: some View {
        if isWaiting {
            ProgressView()
                .controlSize(.small)
                .tint(SQColor.label)
                .accessibilityHidden(true)
        } else {
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

            HStack(spacing: SQSpace.xl) {
                // D.11 : volontaire, coupé par défaut ; seulement une fois l'appel
                // connecté (et vérifié, s'il est chiffré).
                let canShare = liveKit.state == .connected && (callManager.activeCall?.requiresE2EE != true || liveKit.isE2EEVerified)
                controlButton(
                    systemImage: "antenna.radiowaves.left.and.right",
                    tint: callManager.isSharingNetwork ? SQColor.success : SQColor.label
                ) {
                    callManager.toggleNetworkSharing()
                }
                .disabled(!canShare && !callManager.isSharingNetwork)
                .opacity(canShare || callManager.isSharingNetwork ? 1 : 0.4)
                .accessibilityLabel(callManager.isSharingNetwork ? "Arrêter de partager mon réseau" : "Partager mon réseau")
                .accessibilityValue(callManager.isSharingNetwork ? "Partagé" : "Non partagé")
                .accessibilityIdentifier("call.shareNetwork")

                if callManager.activeCall?.hasVideo == true {
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

/// Réseau qu'un autre participant partage (D.11) : seulement les champs reçus.
struct PeerNetworkCard: View {
    let name: String?
    let packet: CallRadioPacket

    var body: some View {
        VStack(alignment: .leading, spacing: SQSpace.xs) {
            Text(name.map { String(localized: "Réseau de \($0), en direct") } ?? String(localized: "Réseau d’un participant, en direct"))
                .font(SQType.caption.weight(.semibold))
                .foregroundStyle(SQColor.labelSecondary)
            ForEach(lines, id: \.label) { line in
                HStack(spacing: SQSpace.sm) {
                    Text(line.label)
                        .foregroundStyle(SQColor.labelSecondary)
                    Spacer(minLength: SQSpace.sm)
                    Text(verbatim: line.value)
                        .foregroundStyle(SQColor.label)
                        .monospacedDigit()
                }
                .font(SQType.caption)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(SQSpace.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SQColor.surface, in: RoundedRectangle(cornerRadius: SQRadius.lg, style: .continuous))
        .accessibilityIdentifier("call.peerNetwork")
    }

    private struct Line { let label: String; let value: String }

    private var lines: [Line] {
        var lines: [Line] = []
        if let operatorName = packet.operatorName { lines.append(Line(label: String(localized: "Opérateur"), value: operatorName)) }
        let bands = packet.nrBands.map { "n\($0)" } + packet.lteBands.map { "B\($0)" }
        let technology = ([packet.technology].compactMap { $0 } + bands).joined(separator: " · ")
        if !technology.isEmpty { lines.append(Line(label: String(localized: "Techno"), value: technology)) }
        if let rsrp = packet.rsrp { lines.append(Line(label: "RSRP", value: "\(rsrp.replacingOccurrences(of: "-", with: "−")) dBm")) }
        if let quality = packet.qualityLevel.flatMap(Self.qualityLabel) { lines.append(Line(label: String(localized: "Qualité"), value: quality)) }
        let node = [packet.gnb.map { "gNB \($0)" } ?? packet.enb.map { "eNB \($0)" }, packet.pci.map { "PCI \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        if !node.isEmpty { lines.append(Line(label: String(localized: "Cellule"), value: node)) }
        return lines
    }

    private static func qualityLabel(_ level: String) -> String? {
        switch level {
        case "EXCELLENT": return String(localized: "Excellent")
        case "GOOD": return String(localized: "Bon")
        case "FAIR": return String(localized: "Moyen")
        case "POOR": return String(localized: "Faible")
        case "NO_SIGNAL": return String(localized: "Aucun signal")
        default: return nil
        }
    }
}

/// Bandeau « Appel en cours » quand l'écran d'appel est réduit (SOC-13).
struct ActiveCallBanner: View {
    @ObservedObject var callManager: CallManager
    @ObservedObject var liveKit: LiveKitClient

    init(callManager: CallManager) {
        _callManager = ObservedObject(wrappedValue: callManager)
        _liveKit = ObservedObject(wrappedValue: callManager.liveKit)
    }

    var body: some View {
        if let call = callManager.activeCall, !callManager.showCallScreen, call.isOutgoing || call.isAnswered {
            Button {
                Haptics.light()
                callManager.restoreCallScreen()
            } label: {
                HStack(spacing: SQSpace.sm) {
                    Image(systemName: call.hasVideo ? "video.fill" : "phone.fill")
                    Text(verbatim: call.handle)
                        .lineLimit(1)
                    if let joinedAt = liveKit.remoteJoinedAt {
                        Text(joinedAt, style: .timer)
                            .monospacedDigit()
                    } else {
                        Text("Sonnerie…")
                    }
                }
                .font(SQType.subhead.weight(.semibold))
                .foregroundStyle(SQColor.onAccent)
                .padding(.horizontal, SQSpace.lg)
                .frame(minHeight: 44)
                .background(SQColor.brandRed, in: Capsule(style: .continuous))
                .sqShadowSoft()
            }
            .buttonStyle(SQPressButtonStyle())
            .padding(.horizontal, SQSpace.lg)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Appel en cours avec \(call.handle)"))
            .accessibilityHint("Revenir à l’appel")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("call.banner")
            .transition(.move(edge: .top).combined(with: .opacity))
        }
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
