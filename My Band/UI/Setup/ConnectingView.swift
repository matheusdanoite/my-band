import Combine
import SwiftUI

// MARK: - ConnectingView
//
// Port of the `Connecting` component in ui_kits/app/Setup.jsx, driven by the REAL
// BandManager.connectionState instead of a timed mock. Pulsing accent ring while
// connecting; settles to a mint check on success. Surfaces errors with a retry.

struct ConnectingView: View {

    @Environment(BandManager.self) private var band
    var onConnected: () -> Void
    var onRetry: () -> Void
    var onReconfigure: () -> Void

    @State private var ringAnimating = false
    @State private var now = Date.now

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var done: Bool { band.connectionState == .connected }
    private var failed: Bool { band.connectionState.isError }

    var body: some View {
        VStack(spacing: MB.Space.x7) {
            Spacer()

            ZStack {
                if !done && !failed {
                    Circle()
                        .stroke(MB.accent, lineWidth: 2)
                        .frame(width: 132, height: 132)
                        .scaleEffect(ringAnimating ? 1.1 : 0.72)
                        .opacity(ringAnimating ? 0 : 0.9)
                }

                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(tileBackground)
                    .frame(width: 92, height: 92)
                    .overlay(
                        Image(systemName: tileIcon)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(tileForeground)
                    )
                    .shadow(color: glowColor, radius: 18)
            }
            .frame(width: 132, height: 132)

            VStack(spacing: 6) {
                Text(title)
                    .font(.mbTitle2)
                    .foregroundStyle(MB.textPrimary)
                Text(pairing ? pairingSubtitle : band.connectionState.handshakeStep)
                    .font(pairing ? .mbBody : .mbMono)
                    .foregroundStyle(failed ? MB.danger : MB.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MB.Space.x8)
            }

            if pairing { pairingChecklist }

            Spacer()

            if failed {
                VStack(spacing: MB.Space.x3) {
                    MBButton(title: "Try again", variant: .primary, size: .lg,
                             icon: "arrow.clockwise", block: true, glow: true) {
                        onRetry()
                    }
                    MBButton(title: "Use a different AuthKey", variant: .ghost, size: .lg,
                             icon: "key.fill", block: true) {
                        onReconfigure()
                    }
                }
                .padding(.horizontal, MB.Space.x7)
                .padding(.bottom, MB.Space.x10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MB.bgApp)
        .onReceive(tick) { now = $0 }
        .onAppear {
            startRing()
            // Already connected on entry (e.g. CoreBluetooth state restoration) — advance.
            if band.connectionState == .connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { onConnected() }
            }
        }
        .onChange(of: band.connectionState) { _, new in
            if new == .connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { onConnected() }
            }
        }
    }

    private func startRing() {
        guard !done && !failed else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            ringAnimating = true
        }
    }

    private var pairing: Bool { band.connectionState == .awaitingPairingConfirmation }

    /// The two confirmation prompts, in the order the user meets them. Showing both up front is the
    /// point: the band's dialog and the iOS Bluetooth sheet can be a minute apart, and a user who
    /// only knows about the one in front of them reads the gap as the app having hung.
    private var pairingChecklist: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            pairingStep(
                index: 1,
                title: "Accept pairing on the band",
                detail: "The band shows the request on its screen. Tap to accept.",
                stage: .band
            )
            pairingStep(
                index: 2,
                title: "Confirm on iPhone",
                detail: "iOS opens the Bluetooth sheet. It can take a few seconds after you accept on the band.",
                stage: .phone
            )
            if let remaining = remainingSeconds {
                Text("Waiting for you — \(remaining)s")
                    .font(.mbMonoSm)
                    .foregroundStyle(MB.textTertiary)
                    .padding(.top, MB.Space.x1)
            }
        }
        .padding(MB.Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous)
                .fill(MB.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                )
        )
        .padding(.horizontal, MB.Space.x5)
    }

    @ViewBuilder
    private func pairingStep(index: Int, title: String, detail: String, stage: PairingStage) -> some View {
        let state = stepState(stage)
        HStack(alignment: .top, spacing: MB.Space.x3) {
            ZStack {
                Circle()
                    .fill(state == .done ? MB.okSoft : (state == .active ? MB.accentSoft : MB.surfaceControl))
                    .frame(width: 26, height: 26)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(MB.ok)
                } else {
                    Text("\(index)")
                        .font(.mbMonoSm)
                        .foregroundStyle(state == .active ? MB.accent200 : MB.textTertiary)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mbBody)
                    .foregroundStyle(state == .pending ? MB.textTertiary : MB.textPrimary)
                if state == .active {
                    Text(detail)
                        .font(.mbCaption)
                        .foregroundStyle(MB.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private enum StepState { case done, active, pending }

    private func stepState(_ stage: PairingStage) -> StepState {
        guard let current = band.pairingStage else { return .pending }
        if current == stage { return .active }
        // The stage only moves forward, so anything behind the current one is settled.
        return (stage == .band && current == .phone) ? .done : .pending
    }

    private var pairingSubtitle: String {
        band.pairingStage == .phone
            ? "Confirm the pairing sheet on your iPhone."
            : "The band is asking for your confirmation."
    }

    private var remainingSeconds: Int? {
        guard let end = band.pairingWaitEndsAt else { return nil }
        let left = Int(end.timeIntervalSince(now).rounded())
        return left > 0 ? left : nil
    }

    private var title: String {
        if done { return "Band connected" }
        if failed { return "Couldn't connect" }
        if pairing { return "Confirm pairing" }
        return "Connecting…"
    }
    private var tileIcon: String {
        if done { return "checkmark" }
        if failed { return "exclamationmark.triangle.fill" }
        if pairing { return "hand.tap.fill" }
        return "dot.radiowaves.left.and.right"
    }
    private var tileBackground: Color { done ? MB.okSoft : (failed ? MB.dangerSoft : MB.accentSoft) }
    private var tileForeground: Color { done ? MB.ok : (failed ? MB.danger : MB.accent200) }
    private var glowColor: Color {
        if done { return MB.ok.opacity(0.45) }
        if failed { return .clear }
        return MB.accentGlow
    }
}
