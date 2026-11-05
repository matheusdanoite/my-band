import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// MARK: - DiagnosticsView
//
// Exports DiagnosticLog. The export file is snapshotted when the sheet opens: ShareLink needs a
// finished file, and lines written while the sheet is up don't belong to the sync being reported.
// Also takes an exported log back in: its `raw …` lines are the band's sleep files, re-read through
// the current parser and rewritten to Apple Health (BandSyncer.importSleepFiles).

struct DiagnosticsView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSyncer.self) private var syncer
    @Environment(\.dismiss) private var dismiss

    @State private var sizeBytes = 0
    @State private var exportURL: URL?
    @State private var confirmClear = false
    @State private var pickingLog = false
    @State private var importing = false
    @State private var importResult: String?

    var body: some View {
        NavigationStack {
            ZStack {
                MB.bgApp.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: MB.Space.x6) {
                        about
                        actions
                    }
                    .padding(.horizontal, MB.Space.screenPad)
                    .padding(.vertical, MB.Space.x6)
                }
            }
            .navigationTitle("Diagnóstico")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluir") { dismiss() }
                }
            }
            .fileImporter(isPresented: $pickingLog, allowedContentTypes: [.plainText, .text]) { result in
                if case .success(let url) = result { importLog(url) }
            }
            .confirmationDialog("Apagar o log?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Apagar log", role: .destructive) { clear() }
            } message: {
                Text("As conexões e sincronizações registradas até agora deixam de poder ser exportadas.")
            }
        }
        .preferredColorScheme(.dark)
        .task { await refresh() }
    }

    // MARK: - Sections

    private var about: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Log de diagnóstico").font(.mbTitle3).foregroundStyle(MB.textPrimary)
                Text("O My Band registra cada conexão e sincronização com a pulseira, inclusive as que acontecem em segundo plano durante a noite. Exporte o log depois de uma sincronização que falhou ou de uma noite de sono que não chegou ao Apple Health.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
            HStack {
                Text("Tamanho").font(.mbSubheadEmph).foregroundStyle(MB.textSecondary)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file))
                    .font(.mbSubhead.monospacedDigit()).foregroundStyle(MB.textPrimary)
            }
            .padding(MB.Space.x4)
            .background(MB.surfaceCard)
            .overlay(
                RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous)
                    .strokeBorder(MB.hairline, lineWidth: 1)
            )
            .mbCornerRadius(MB.Radius.lg)
            Text("O arquivo fica só neste iPhone até você exportá-lo. Ele inclui horários, fases de sono e o conteúdo bruto dos arquivos de sono da pulseira — nunca o AuthKey.")
                .font(.mbFootnote).foregroundStyle(MB.textTertiary)
        }
    }

    private var actions: some View {
        VStack(spacing: MB.Space.x3) {
            if let exportURL {
                ShareLink(item: exportURL, preview: SharePreview("Log do My Band")) {
                    exportLabel
                }
                .buttonStyle(.plain)
            } else {
                MBButton(title: "Preparando…", variant: .primary, size: .lg,
                         icon: "square.and.arrow.up", block: true, loading: true) {}
            }
            MBButton(title: "Apagar log", variant: .destructive, size: .lg, icon: "trash",
                     block: true, disabled: sizeBytes == 0) {
                confirmClear = true
            }
            MBButton(title: "Reprocessar sono de um log", variant: .secondary, size: .lg,
                     icon: "arrow.clockwise", block: true, loading: importing) {
                pickingLog = true
            }
            Text(importResult ?? "Relê as noites guardadas num log exportado com a leitura atual e as regrava no Apple Health.")
                .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// ShareLink can't wrap MBButton (a button inside a button), so the primary look is rebuilt here.
    private var exportLabel: some View {
        HStack(spacing: MB.Space.x2) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 17, weight: .semibold))
            Text("Exportar log").font(.system(size: 17, weight: .semibold)).tracking(-0.17)
        }
        .foregroundStyle(MB.textOnAccent)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(MB.accent)
        .mbCornerRadius(MB.Radius.lg)
        .shadow(color: MB.accentGlow, radius: 12)
    }

    // MARK: - Actions

    private func refresh() async {
        exportURL = await DiagnosticLog.shared.makeExport(header: header())
        sizeBytes = await DiagnosticLog.shared.sizeInBytes()
    }

    private func importLog(_ url: URL) {
        importing = true
        importResult = nil
        Task {
            defer { importing = false }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let result = try await syncer.importSleepFiles(fromLog: text)
                importResult = result.files == 0
                    ? "Nenhum arquivo de sono neste log."
                    : "\(result.files) arquivo(s) de sono relido(s), \(result.nights) noite(s) regravada(s) no Apple Health."
            } catch {
                importResult = "Não foi possível reprocessar: \(error.localizedDescription)"
            }
        }
    }

    private func clear() {
        exportURL = nil
        Task {
            await DiagnosticLog.shared.clear()
            AppLogger(category: "App").notice("Diagnostic log cleared by the user")
            await refresh()
        }
    }

    /// What the lines themselves don't carry. English, like the log.
    private func header() -> String {
        var lines = [
            "My Band diagnostic log",
            "Exported: \(Date().logStamp) (\(TimeZone.current.identifier))",
            "App: \(DiagnosticLog.appVersion)",
            "Device: \(DiagnosticLog.deviceModel), \(systemVersion)",
            "Band: \(syncer.currentDevice?.name ?? "none paired"), link \(String(describing: band.connectionState))",
            "Last Apple Health sync: \(syncer.lastHealthSync?.logStamp ?? "never")",
        ]
        if let sleep = syncer.mostRecentSleepSession() {
            lines.append("Latest stored sleep session: \(sleep.startDate.logStamp) → \(sleep.endDate.logStamp), \(sleep.phases.count) phase(s)")
        }
        return lines.joined(separator: "\n")
    }

    private var systemVersion: String {
        #if canImport(UIKit)
        "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #else
        ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
