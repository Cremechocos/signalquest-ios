import WidgetKit
import SwiftUI
import ActivityKit

/// Live Activity affichée pendant un test de débit (écran verrouillé + Dynamic
/// Island). Alimentée par l'app via `SpeedtestLiveActivityController`.
@available(iOS 16.1, *)
struct SpeedtestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SpeedtestActivityAttributes.self) { context in
            LockScreenSpeedtestActivity(state: context.state, attributes: context.attributes)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .activityBackgroundTint(Color(.systemBackground))
                .activitySystemActionForegroundColor(speedColor(context.state.downloadMbps))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandMetric(
                        value: Int(context.state.downloadMbps.rounded()),
                        label: "Réception",
                        unit: "Mbps",
                        tint: speedColor(context.state.downloadMbps),
                        icon: "arrow.down"
                    )
                    .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    IslandMetric(
                        value: Int(context.state.uploadMbps.rounded()),
                        label: "Envoi",
                        unit: "Mbps",
                        tint: SpeedtestLiveStyle.upload,
                        icon: "arrow.up"
                    )
                    .padding(.trailing, 2)
                }

                DynamicIslandExpandedRegion(.center) {
                    IslandStatus(state: context.state)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        LiveProgressBar(
                            progress: clamped(context.state.progress),
                            tint: context.state.finished ? SpeedtestLiveStyle.success : speedColor(context.state.downloadMbps),
                            track: .white.opacity(0.16)
                        )
                        .frame(height: 5)

                        if context.state.isBurst {
                            Text("Rafale \(context.state.runIndex)/\(context.state.runTotal)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(SpeedtestLiveStyle.warning)
                                .monospacedDigit()
                                .stableNumericTransition(Double(context.state.runIndex))
                        }
                    }
                    .padding(.horizontal, 2)
                }
            } compactLeading: {
                CompactGlyph(state: context.state)
            } compactTrailing: {
                Text("\(Int(context.state.downloadMbps.rounded()))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(speedColor(context.state.downloadMbps))
                    .monospacedDigit()
                    .stableNumericTransition(context.state.downloadMbps)
                    .frame(maxWidth: 34, alignment: .trailing)
            } minimal: {
                CompactGlyph(state: context.state)
            }
            .keylineTint(context.state.finished ? SpeedtestLiveStyle.success : speedColor(context.state.downloadMbps))
        }
    }
}

@available(iOS 16.1, *)
private struct LockScreenSpeedtestActivity: View {
    let state: SpeedtestActivityAttributes.ContentState
    let attributes: SpeedtestActivityAttributes

    private var downloadValue: Int { Int(state.downloadMbps.rounded()) }
    private var uploadValue: Int { Int(state.uploadMbps.rounded()) }
    private var pingValue: Int { Int(state.pingMs.rounded()) }
    private var progress: Double { clamped(state.progress) }
    private var tint: Color { state.finished ? SpeedtestLiveStyle.success : speedColor(state.downloadMbps) }

    // En mots (MES-12) : « UL / DL / Sync » ne disaient rien à un débutant.
    private var compactPhaseLabel: LocalizedStringKey {
        if state.finished { return "Terminé" }
        let label = state.phaseLabel.lowercased()
        if label.contains("ping") { return "Latence" }
        if label.contains("upload") || label.contains("envoi") { return "Envoi" }
        if label.contains("download") || label.contains("réception") || label.contains("reception") { return "Réception" }
        if label.contains("sauvegarde") || label.contains("saving") || label.contains("sync") { return "Enregistrement" }
        if state.isBurst { return "Test \(state.runIndex)/\(state.runTotal)" }
        return "Test"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AnimatedNumber(value: downloadValue, size: 40, tint: tint)
                Text("Mbps")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .stableNumericTransition(progress)
            }

            LiveProgressBar(progress: progress, tint: tint, track: Color.primary.opacity(0.12))
                .frame(height: 7)

            HStack(spacing: 14) {
                InlineMetric(label: "Envoi", value: "\(uploadValue)", numericValue: Double(uploadValue), unit: "Mbps", icon: "arrow.up", tint: SpeedtestLiveStyle.upload)
                InlineMetric(label: "Latence", value: state.pingMs > 0 ? "\(pingValue)" : "-", numericValue: Double(pingValue), unit: "ms", icon: "bolt.fill", tint: SpeedtestLiveStyle.ping)

                if state.isBurst {
                    InlineMetric(label: "Rafale", value: "\(state.runIndex)", numericValue: Double(state.runIndex), unit: "/\(state.runTotal)", icon: "repeat", tint: SpeedtestLiveStyle.warning)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: state.finished ? "checkmark.seal.fill" : "speedometer")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(state.phaseLabel)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(attributes.network)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var subtitle: String {
        if state.isBurst {
            return "Speedtest en rafale \(state.runIndex)/\(state.runTotal)"
        }
        return attributes.serverName.isEmpty ? "Speedtest" : attributes.serverName
    }
}

@available(iOS 16.1, *)
private struct LiveProgressBar: View {
    let progress: Double
    let tint: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width * progress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(track)

                Capsule()
                    .fill(tint)
                    .frame(width: width)
                    .animation(.easeInOut(duration: 0.25), value: progress)
            }
        }
        .accessibilityLabel("Progression")
        .accessibilityValue("\(Int((progress * 100).rounded())) %")
    }
}

@available(iOS 16.1, *)
private struct InlineMetric: View {
    let label: LocalizedStringKey
    let value: String
    let numericValue: Double
    let unit: LocalizedStringKey
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                        .stableNumericTransition(numericValue)
                    Text(unit)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.1, *)
private struct AnimatedNumber: View {
    let value: Int
    let size: CGFloat
    let tint: Color

    var body: some View {
        Text("\(value)")
            .font(.system(size: size, weight: .black, design: .rounded))
            .foregroundStyle(tint)
            .monospacedDigit()
            .minimumScaleFactor(0.74)
            .lineLimit(1)
            .stableNumericTransition(Double(value))
    }
}

@available(iOS 16.1, *)
private struct IslandMetric: View {
    let value: Int
    /// Lu par VoiceOver ; la flèche dit déjà le sens à l'écran.
    let label: LocalizedStringKey
    let unit: LocalizedStringKey
    let tint: Color
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(value)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(tint)
                        .monospacedDigit()
                        .stableNumericTransition(Double(value))
                    Text(unit)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(label))
    }
}

@available(iOS 16.1, *)
private struct IslandStatus: View {
    let state: SpeedtestActivityAttributes.ContentState

    private var tint: Color { state.finished ? SpeedtestLiveStyle.success : speedColor(state.downloadMbps) }

    // En mots (MES-12) : « UL / DL / Sync » ne disaient rien à un débutant.
    private var compactPhaseLabel: LocalizedStringKey {
        if state.finished { return "Terminé" }
        let label = state.phaseLabel.lowercased()
        if label.contains("ping") { return "Latence" }
        if label.contains("upload") || label.contains("envoi") { return "Envoi" }
        if label.contains("download") || label.contains("réception") || label.contains("reception") { return "Réception" }
        if label.contains("sauvegarde") || label.contains("saving") || label.contains("sync") { return "Enregistrement" }
        if state.isBurst { return "Test \(state.runIndex)/\(state.runTotal)" }
        return "Test"
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                Text(compactPhaseLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityLabel(state.phaseLabel)
            }

            if state.pingMs > 0 {
                Text("\(Int(state.pingMs.rounded())) ms")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                    .stableNumericTransition(state.pingMs)
            }
        }
        .frame(maxWidth: 92)
    }
}

@available(iOS 16.1, *)
private struct CompactGlyph: View {
    let state: SpeedtestActivityAttributes.ContentState

    private var tint: Color { state.finished ? SpeedtestLiveStyle.success : speedColor(state.downloadMbps) }

    var body: some View {
        Image(systemName: state.finished ? "checkmark.circle.fill" : "speedometer")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }
}

@available(iOS 16.1, *)
private enum SpeedtestLiveStyle {
    // Mêmes jetons que l'app et le widget (MES-12) : encre d'accent pour
    // l'envoi, ocre pour la latence et la rafale, vert olive pour « terminé ».
    static let upload = WidgetPalette.brandDeep
    static let ping = WidgetPalette.latency
    static let warning = WidgetPalette.latency
    static let success = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0xA3 / 255, green: 0xB3 / 255, blue: 0x7A / 255, alpha: 1)
            : UIColor(red: 0x60 / 255, green: 0x6B / 255, blue: 0x46 / 255, alpha: 1)
    })
}

@available(iOS 16.1, *)
private extension View {
    @ViewBuilder
    func stableNumericTransition(_ value: Double) -> some View {
        if #available(iOS 17.0, *) {
            self.contentTransition(.numericText(value: value))
        } else {
            self
        }
    }
}

@available(iOS 16.1, *)
private func clamped(_ value: Double) -> Double {
    max(0, min(1, value))
}
