import SwiftUI

struct IncomingCallView: View {
    let call: CallSession
    let callsService: CallsServicing
    var onAccepted: (CallSession) -> Void
    var onRejected: () -> Void

    @State private var isBusy = false

    var body: some View {
        ZStack {
            ringBackground
            VStack(spacing: SQSpace.xxl + 2) {
                Spacer()
                Text("Appel entrant")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.64))
                centralAvatar
                if let participant = call.participants?.first {
                    Text(participant)
                        .font(SQType.display)
                        .foregroundStyle(.white)
                }
                Image(systemName: call.mode == "video" ? "video.fill" : "phone.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(SQGradient.signal)
                    .symbolEffectPulseCompat()
                Spacer()
                HStack(spacing: SQSpace.huge - 4) {
                    Button {
                        Task { await reject() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(SQColor.danger, in: Circle())
                            .shadow(color: SQColor.danger.opacity(0.45), radius: 16, y: 7)
                    }
                    .accessibilityLabel("Refuser l'appel")
                    Button {
                        Task { await accept() }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(SQColor.success, in: Circle())
                            .shadow(color: SQColor.success.opacity(0.45), radius: 16, y: 7)
                    }
                    .accessibilityLabel("Accepter l'appel")
                }
                .padding(.bottom, SQSpace.huge)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Déclinaison sombre du fond DA (mêmes teintes que le hero dark).
    private var ringBackground: some View {
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

    /// Gros avatar central entouré du SQStoryRing animé pendant la sonnerie.
    private var centralAvatar: some View {
        SQAvatar(url: nil, name: call.participants?.first ?? "?", size: 132)
            .padding(8)
            .overlay { SQStoryRing(lineWidth: 4) }
            .shadow(color: SQBrand.signatureStart.opacity(0.35), radius: 30, y: 12)
    }

    private func accept() async {
        isBusy = true
        defer { isBusy = false }
        if let updated = try? await callsService.answer(callId: call.id) {
            Haptics.success()
            onAccepted(updated)
        }
    }

    private func reject() async {
        isBusy = true
        defer { isBusy = false }
        try? await callsService.reject(callId: call.id)
        onRejected()
    }
}
