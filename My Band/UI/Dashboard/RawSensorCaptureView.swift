import SwiftUI

struct RawSensorCaptureView: View {

    @Environment(BandManager.self) private var band
    @Environment(RawSensorCaptureService.self) private var capture
    @Environment(\.dismiss) private var dismiss

    @State private var durationSeconds = 60
    @State private var resultText: String?
    @State private var resultIsError = false

    private var connected: Bool { band.connectionState.isConnected }

    var body: some View {
        NavigationStack {
            ZStack {
                MB.bgApp.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: MB.Space.x6) {
                        statusSection
                        captureSection
                        exportsSection
                    }
                    .padding(.horizontal, MB.Space.screenPad)
                    .padding(.vertical, MB.Space.x6)
                }
            }
            .navigationTitle("Raw motion")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { capture.refreshCaptures() }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            sectionHeader(
                "Capture raw motion",
                subtitle: "Accelerometer and gyroscope samples from the band."
            )
            HStack(spacing: MB.Space.x3) {
                Image(systemName: capture.isCapturing ? "waveform.path.ecg" : "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(capture.isCapturing ? MB.ok : MB.accent)
                    .frame(width: 42, height: 42)
                    .background((capture.isCapturing ? MB.ok : MB.accent).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: MB.Radius.md))
                VStack(alignment: .leading, spacing: 2) {
                    Text(capture.isCapturing ? "Capturing…" : "Ready to capture")
                        .font(.mbHeadline)
                        .foregroundStyle(MB.textPrimary)
                    Text(capture.isCapturing
                         ? "\(capture.sampleCount) samples received"
                         : "The session is saved locally as CSV.")
                        .font(.mbFootnote)
                        .foregroundStyle(MB.textTertiary)
                }
                Spacer()
            }
            .padding(MB.Space.x4)
            .background(MB.surfaceCard, in: RoundedRectangle(cornerRadius: MB.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: MB.Radius.lg)
                    .stroke(MB.hairline, lineWidth: 1)
            )
        }
    }

    private var captureSection: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            sectionHeader("New session", subtitle: connected ? "Keep the app open while capturing." : "Connect your band first.")
            Picker("Duration", selection: $durationSeconds) {
                Text("15 seconds").tag(15)
                Text("30 seconds").tag(30)
                Text("60 seconds").tag(60)
            }
            .pickerStyle(.segmented)
            .disabled(capture.isCapturing)

            MBButton(
                title: capture.isCapturing ? "Stop capture" : "Start capture",
                variant: capture.isCapturing ? .destructive : .primary,
                size: .lg,
                icon: capture.isCapturing ? "stop.fill" : "record.circle",
                block: true,
                glow: !capture.isCapturing,
                loading: false,
                disabled: !connected && !capture.isCapturing
            ) {
                if capture.isCapturing {
                    capture.stopCapture()
                } else {
                    startCapture()
                }
            }
            if let resultText {
                Text(resultText)
                    .font(.mbFootnote)
                    .foregroundStyle(resultIsError ? MB.danger : MB.ok)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var exportsSection: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            sectionHeader("Export CSV", subtitle: "Share a capture with Files, Mail or another app.")
            if capture.captureURLs.isEmpty {
                Text("No captures yet.")
                    .font(.mbFootnote)
                    .foregroundStyle(MB.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MB.Space.x4)
                    .background(MB.surfaceCard, in: RoundedRectangle(cornerRadius: MB.Radius.lg))
            } else {
                ForEach(capture.captureURLs, id: \.self) { url in
                    HStack(spacing: MB.Space.x3) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(MB.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.mbCallout)
                                .foregroundStyle(MB.textPrimary)
                                .lineLimit(1)
                            Text(url.lastPathComponent)
                                .font(.mbMonoSm)
                                .foregroundStyle(MB.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer()
                        ShareLink(item: url, subject: Text("Raw motion capture")) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundStyle(MB.accent200)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Export CSV")
                    }
                    .padding(.leading, MB.Space.x4)
                    .padding(.trailing, MB.Space.x2)
                    .background(MB.surfaceCard, in: RoundedRectangle(cornerRadius: MB.Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: MB.Radius.lg)
                            .stroke(MB.hairline, lineWidth: 1)
                    )
                }
            }
        }
    }

    private func startCapture() {
        do {
            try capture.startCapture(duration: .seconds(durationSeconds))
            resultText = "Capturing for \(durationSeconds) seconds."
            resultIsError = false
        } catch {
            resultText = error.localizedDescription
            resultIsError = true
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.mbHeadline).foregroundStyle(MB.textPrimary)
            Text(subtitle).font(.mbFootnote).foregroundStyle(MB.textTertiary)
        }
    }
}
