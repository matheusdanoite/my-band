import SwiftUI

// MARK: - DashboardView
//
// Minimal first dashboard: live band status, battery, last Apple Health sync, and a
// "Sync with Apple Health" action. Sleep/activity detail comes in a later phase.

struct DashboardView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSyncer.self) private var syncer
    var onForget: () -> Void

    @State private var syncing = false
    @State private var resultText: String?
    @State private var resultIsError = false
    @State private var showCustomize = false
    @State private var showProfile = false

    private var connected: Bool { band.connectionState.isConnected }
    /// Mid-handshake (or scanning) — a reconnect is already under way, so the button waits.
    private var connecting: Bool {
        switch band.connectionState {
        case .connecting, .discoveringServices, .sessionConfig, .authenticating, .scanning,
             .awaitingPairingConfirmation: true
        default: false
        }
    }

    var body: some View {
        ZStack {
            MB.bgApp.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: MB.Space.x5) {
                    header
                    metrics
                    syncSection
                    MBButton(title: "Customize", variant: .secondary, size: .lg,
                             icon: "square.grid.2x2", block: true, disabled: !connected) {
                        showCustomize = true
                    }
                    MBButton(title: "Profile", variant: .secondary, size: .lg,
                             icon: "person.text.rectangle", block: true) {
                        showProfile = true
                    }
                    Spacer(minLength: MB.Space.x6)
                    MBButton(title: "Forget band", variant: .ghost, size: .md, block: true,
                             action: onForget)
                }
                .padding(.horizontal, MB.Space.screenPad)
                .padding(.top, MB.Space.x6)
                .padding(.bottom, MB.Space.x10)
            }
        }
        .sheet(isPresented: $showCustomize) { CustomizeView() }
        .sheet(isPresented: $showProfile) { ProfileView() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(syncer.currentDevice?.name ?? "Mi Band 10")
                    .font(.mbTitle1).tracking(-0.02 * 28)
                    .foregroundStyle(MB.textPrimary)
                Text("Your band").font(.mbSubhead).foregroundStyle(MB.textTertiary)
            }
            Spacer()
            MBStatusPill(text: band.connectionState.pillLabel,
                         tone: band.connectionState.pillTone,
                         pulse: band.connectionState.pillPulses)
                .padding(.top, 6)
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        HStack(spacing: MB.Space.x3) {
            MBMetricTile(
                icon: batteryIcon, tint: batteryTint, tintSoft: batteryTintSoft,
                label: "Battery",
                value: band.batteryLevel.map(String.init) ?? "—",
                unit: band.batteryLevel != nil ? "%" : nil,
                foot: band.batteryCharging ? "Charging" : nil
            )
            MBMetricTile(
                icon: "heart.fill", tint: MB.hr, tintSoft: MB.hrSoft,
                label: "Apple Health",
                value: lastSyncText,
                foot: "last sync"
            )
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        VStack(spacing: MB.Space.x3) {
            MBButton(title: syncing ? "Syncing…" : "Sync with Apple Health",
                     variant: .primary, size: .lg, icon: "arrow.triangle.2.circlepath",
                     block: true, glow: true, loading: syncing, disabled: !connected || syncing) {
                runSync()
            }
            if !connected {
                MBButton(title: connecting ? "Connecting…" : "Reconnect",
                         variant: .secondary, size: .lg,
                         icon: "antenna.radiowaves.left.and.right",
                         block: true, loading: connecting, disabled: connecting) {
                    reconnect()
                }
            }
            if let resultText {
                Text(resultText)
                    .font(.mbFootnote)
                    .foregroundStyle(resultIsError ? MB.danger : MB.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if !connected {
                Text("Connect your band to sync.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func reconnect() {
        if let id = syncer.currentDevice?.peripheralIdentifier {
            band.reconnectToKnownDevice(identifier: id)
        } else {
            band.startScan()
        }
    }

    private func runSync() {
        syncing = true
        resultText = nil
        Task {
            do {
                // Funnel through the same coalesced entry point as the background/intent triggers,
                // so a manual tap can't race a sync already in flight.
                let outcome = try await BackgroundSyncManager.shared.syncNow()
                resultIsError = false
                resultText = "Synced · \(outcome.healthSamplesWritten) samples in Apple Health"
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
            }
            syncing = false
        }
    }

    // MARK: Derived

    private var lastSyncText: String {
        guard let date = syncer.lastHealthSync else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private var batteryIcon: String {
        guard let level = band.batteryLevel else { return "battery.0" }
        if band.batteryCharging { return "battery.100.bolt" }
        switch level {
        case ..<15: return "battery.25"
        case ..<55: return "battery.50"
        case ..<85: return "battery.75"
        default:    return "battery.100"
        }
    }
    private var batteryTint: Color {
        guard let level = band.batteryLevel else { return MB.textTertiary }
        if level < 15 { return MB.danger }
        if level < 30 { return MB.warn }
        return MB.steps
    }
    private var batteryTintSoft: Color {
        guard let level = band.batteryLevel else { return MB.surfaceFill }
        if level < 15 { return MB.dangerSoft }
        if level < 30 { return MB.warnSoft }
        return MB.stepsSoft
    }
}
