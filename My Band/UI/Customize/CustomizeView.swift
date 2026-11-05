import SwiftUI
import UniformTypeIdentifiers

// MARK: - CustomizeView
//
// Manage watch faces and quick apps on the band: list / set active / delete, and install a new
// one from a file (Files), a URL, or a shared file (handled in the app via onOpenURL).

struct CustomizeView: View {

    @Environment(BandManager.self) private var band
    @Environment(CustomizationManager.self) private var customization
    @Environment(\.dismiss) private var dismiss

    @State private var showFileImporter = false
    @State private var urlText = ""

    private var connected: Bool { band.connectionState.isConnected }

    var body: some View {
        NavigationStack {
            ZStack {
                MB.bgApp.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: MB.Space.x6) {
                        if !connected { disconnectedNote }
                        resultBanner
                        importSection
                        facesSection
                        appsSection
                    }
                    .padding(.horizontal, MB.Space.screenPad)
                    .padding(.vertical, MB.Space.x6)
                }
                if customization.isInstalling { installOverlay }
            }
            .navigationTitle("Customize")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if connected { customization.refresh() } }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await customization.installFromFile(url) }
            }
        }
    }

    // MARK: - Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            sectionHeader("Install", subtitle: "Watch face (.bin) or app (.rpk)")
            MBButton(title: "Choose file", variant: .primary, size: .lg,
                     icon: "folder", block: true, disabled: !connected || customization.isInstalling) {
                showFileImporter = true
            }
            HStack(spacing: MB.Space.x2) {
                TextField("https://…", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.mbMonoSm)
                    .foregroundStyle(MB.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, MB.Space.x4)
                    .padding(.vertical, MB.Space.x3)
                    .background(MB.surfaceControl, in: RoundedRectangle(cornerRadius: MB.Radius.md))
                MBButton(title: "Download", variant: .secondary, size: .md,
                         disabled: !connected || customization.isInstalling || downloadURL == nil) {
                    if let url = downloadURL {
                        urlText = ""
                        Task { await customization.installFromURL(url) }
                    }
                }
            }
        }
    }

    private var downloadURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    // MARK: - Watch faces

    private var facesSection: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            sectionHeader("Watch faces", subtitle: faceSubtitle)
            if customization.watchfaces.faces.isEmpty {
                emptyRow("No watch faces listed")
            } else {
                ForEach(customization.watchfaces.faces) { face in
                    row(title: face.name, subtitle: face.id,
                        active: face.active, canDelete: face.canDelete,
                        onTap: { customization.watchfaces.setActive(face.id) },
                        onDelete: { customization.watchfaces.delete(face.id) })
                }
            }
        }
    }

    private var faceSubtitle: String {
        connected ? "tap to activate" : "connect your band"
    }

    // MARK: - Apps

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            sectionHeader("Apps", subtitle: connected ? "installed quick apps" : "connect your band")
            if customization.apps.apps.isEmpty {
                emptyRow("No apps listed")
            } else {
                ForEach(customization.apps.apps) { app in
                    row(title: app.name, subtitle: app.id,
                        active: false, canDelete: true,
                        onTap: nil,
                        onDelete: { customization.apps.delete(app) })
                }
            }
        }
    }

    // MARK: - Reusable bits

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.mbHeadline).foregroundStyle(MB.textPrimary)
            Text(subtitle).font(.mbFootnote).foregroundStyle(MB.textTertiary)
        }
    }

    private func row(title: String, subtitle: String, active: Bool, canDelete: Bool,
                     onTap: (() -> Void)?, onDelete: @escaping () -> Void) -> some View {
        HStack(spacing: MB.Space.x3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mbCallout).foregroundStyle(MB.textPrimary).lineLimit(1)
                Text(subtitle).font(.mbMonoSm).foregroundStyle(MB.textTertiary).lineLimit(1)
            }
            Spacer()
            if active {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(MB.ok)
            }
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(MB.danger)
                }
                .buttonStyle(.plain)
                .disabled(!connected || customization.isInstalling)
            }
        }
        .padding(MB.Space.x4)
        .background(MB.surfaceCard, in: RoundedRectangle(cornerRadius: MB.Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: MB.Radius.lg).stroke(MB.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if connected, !customization.isInstalling { onTap?() } }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(MB.Space.x4)
            .background(MB.surfaceCard, in: RoundedRectangle(cornerRadius: MB.Radius.lg))
    }

    @ViewBuilder private var resultBanner: some View {
        if let result = customization.lastResult {
            Text(result.message)
                .font(.mbFootnote)
                .foregroundStyle(result.isError ? MB.danger : MB.ok)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MB.Space.x4)
                .background((result.isError ? MB.danger : MB.ok).opacity(0.12),
                           in: RoundedRectangle(cornerRadius: MB.Radius.md))
        }
    }

    private var disconnectedNote: some View {
        Text("Connect your band to manage and install.")
            .font(.mbFootnote).foregroundStyle(MB.warn)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var installOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: MB.Space.x4) {
                ProgressView(value: customization.progress ?? 0)
                    .tint(MB.accent)
                    .frame(width: 200)
                Text("Sending… \(Int((customization.progress ?? 0) * 100))%")
                    .font(.mbSubhead).foregroundStyle(MB.textSecondary)
            }
            .padding(MB.Space.x7)
            .background(MB.surfaceRaised, in: RoundedRectangle(cornerRadius: MB.Radius.lg))
        }
    }
}
