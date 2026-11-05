import SwiftUI

// MARK: - XiaomiLoginView
//
// Guided AuthKey extraction via Xiaomi Cloud login (XiaomiCloudAuth). The user types their
// Xiaomi account credentials — the same ones used by Mi Home / Mi Fitness — directly here, and
// we walk whatever extra steps Xiaomi asks for (captcha, emailed 2FA code) before pulling the
// band's beaconkey and handing it back through `onExtracted`, which feeds the same connect path
// as manual entry.
//
// This replaces the previous QR-based flow, which never had the user type a password into the
// app at all (only Xiaomi's own page saw it). That property is intentionally traded away here for
// not depending on a second device or a fragile long-poll — see CLAUDE.md's Xiaomi Cloud section.
// The password lives only in `XiaomiCloudAuth`'s in-memory login call, never persisted or logged.

struct XiaomiLoginView: View {

    let onExtracted: (String) -> String?   // returns an inline error, or nil on success
    let onManual: () -> Void
    let onBack: () -> Void

    @State private var auth = XiaomiCloudAuth()
    @State private var selectionError: String?
    @State private var username = ""
    @State private var password = ""
    @State private var captchaCode = ""
    @State private var twoFACode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MBIconButton(icon: "arrow.left", variant: .plain, accessibilityLabelText: "Back") {
                auth.cancel()
                onBack()
            }
            .padding(.bottom, 18)

            content
        }
        .padding(.horizontal, MB.Space.x7)
        .padding(.top, 70)
        .padding(.bottom, MB.Space.x10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MB.bgApp)
        .onAppear { if auth.phase == .idle { auth.start() } }
        .onDisappear { auth.cancel() }
        .animation(.easeOut(duration: MB.Motion.durBase), value: auth.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch auth.phase {
        case .idle:
            progress(title: "Preparing", subtitle: "One moment…")
        case .enteringCredentials:
            credentialsStep
        case .authenticating:
            progress(title: "Signing in", subtitle: "Verifying username and password…")
        case .awaitingCaptcha(let imageURL):
            captchaStep(imageURL)
        case .awaiting2FA:
            twoFAStep
        case .confirmingLogin:
            progress(title: "Confirming login", subtitle: "Validating the session with Xiaomi…")
        case .fetchingDevices:
            progress(title: "Finding band", subtitle: "Reading the key from your account…")
        case .done:
            deviceStep
        case .failed(let message):
            failure(message)
        }
    }

    // MARK: - Credentials

    private var credentialsStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: "Sign in to your Xiaomi account",
                   subtitle: "Use the same username and password as the Xiaomi Home or Mi Fitness app. The password is only used to authenticate with Xiaomi — it is never saved.")

            VStack(spacing: 14) {
                MBTextField(label: "Username", text: $username, icon: "person",
                            placeholder: "Email, phone or Xiaomi ID")
                MBTextField(label: "Password", text: $password, icon: "lock",
                            placeholder: "Password", secure: true)
            }

            Spacer()

            MBButton(title: "Sign in", variant: .primary, size: .lg,
                     icon: "arrow.right.circle", block: true, glow: true,
                     disabled: username.isEmpty || password.isEmpty) {
                auth.submitCredentials(username: username, password: password)
            }
            manualLink
        }
    }

    // MARK: - Captcha

    private func captchaStep(_ imageURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: "Confirm the captcha",
                   subtitle: "Xiaomi asked for this extra verification before continuing.")

            AsyncImage(url: imageURL) { image in
                image.resizable().interpolation(.none).scaledToFit()
            } placeholder: {
                ProgressView().tint(MB.night950)
            }
            .frame(height: 90)
            .frame(maxWidth: .infinity)
            .background(Color.white)
            .mbCornerRadius(MB.Radius.md)

            MBTextField(label: "Captcha", text: $captchaCode, icon: "textformat.abc",
                        placeholder: "Type the text in the image")

            Spacer()
            MBButton(title: "Confirm", variant: .primary, size: .lg,
                     icon: "checkmark", block: true, glow: true,
                     disabled: captchaCode.isEmpty) {
                auth.submitCaptcha(captchaCode)
                captchaCode = ""
            }
            manualLink
        }
    }

    // MARK: - Email 2FA

    private var twoFAStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: "Two-step verification",
                   subtitle: "Xiaomi sent a code to the account email. Enter it below to confirm it's you.")

            MBTextField(label: "Code", text: $twoFACode, icon: "envelope",
                        placeholder: "Code received by email", mono: true)

            Spacer()
            MBButton(title: "Confirm", variant: .primary, size: .lg,
                     icon: "checkmark", block: true, glow: true,
                     disabled: twoFACode.isEmpty) {
                auth.submit2FACode(twoFACode)
                twoFACode = ""
            }
            manualLink
        }
    }

    // MARK: - Device selection

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: auth.bands.count == 1 ? "Band found" : "Choose your band",
                   subtitle: "The key is stored only in this device's Keychain.")

            VStack(spacing: 12) {
                ForEach(auth.bands) { band in
                    Button { select(band) } label: { bandRow(band) }
                        .buttonStyle(.plain)
                }
            }

            if let selectionError {
                Text(selectionError).font(.mbFootnote).foregroundStyle(MB.danger)
            }

            Spacer()
            manualLink
        }
    }

    private func bandRow(_ band: XiaomiCloudAuth.CloudBand) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(MB.accentSoft)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 19)).foregroundStyle(MB.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(band.name).font(.mbHeadline).foregroundStyle(MB.textPrimary)
                if !band.mac.isEmpty {
                    Text(band.mac).font(.mbMonoSm).foregroundStyle(MB.textTertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MB.textTertiary)
        }
        .padding(14)
        .background(MB.surfaceCard)
        .overlay(RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous)
            .strokeBorder(MB.hairline, lineWidth: 1))
        .mbCornerRadius(MB.Radius.lg)
    }

    // MARK: - Failure

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: "Couldn't extract the key", subtitle: message)
            Spacer()
            MBButton(title: "Try again", variant: .primary, size: .lg,
                     icon: "arrow.clockwise", block: true, glow: true) {
                selectionError = nil
                password = ""
                auth.start()
            }
            manualLink
        }
    }

    // MARK: - Shared pieces

    private func progress(title: String, subtitle: String) -> some View {
        VStack(spacing: MB.Space.x6) {
            Spacer()
            ProgressView().controlSize(.large).tint(MB.accent)
            VStack(spacing: 6) {
                Text(title).font(.mbTitle3).foregroundStyle(MB.textPrimary)
                Text(subtitle).font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            manualLink
        }
        .frame(maxWidth: .infinity)
    }

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.mbTitle1)
                .tracking(-0.02 * 28)
                .foregroundStyle(MB.textPrimary)
            Text(subtitle)
                .font(.mbBody)
                .foregroundStyle(MB.textSecondary)
        }
    }

    private var manualLink: some View {
        Button { auth.cancel(); onManual() } label: {
            Text("Enter AuthKey manually")
                .font(.mbSubheadEmph)
                .foregroundStyle(MB.accent200)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func select(_ band: XiaomiCloudAuth.CloudBand) {
        selectionError = onExtracted(band.beaconKey)
    }
}
