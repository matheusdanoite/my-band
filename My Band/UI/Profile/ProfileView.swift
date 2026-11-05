import SwiftUI

// MARK: - ProfileView
//
// User profile sheet. Today it holds the height, needed to derive BMI (bodyMassIndex) in Apple
// Health from a scale weight — the scale only measures weight. Height is stored locally (so the
// field is pre-filled and ScaleManager can use it for instant BMI) and written to Apple Health.

struct ProfileView: View {

    @Environment(ScaleManager.self) private var scale
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ProfileDefaults.heightCmKey) private var storedHeightCm: Double = 0

    @State private var heightInput = ""
    @State private var message: String?
    @State private var isError = false
    @State private var saving = false

    var body: some View {
        NavigationStack {
            ZStack {
                MB.bgApp.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: MB.Space.x6) {
                        heightSection
                        if let kg = scale.lastWeightKg { lastWeightNote(kg) }
                    }
                    .padding(.horizontal, MB.Space.screenPad)
                    .padding(.vertical, MB.Space.x6)
                }
            }
            .navigationTitle("Profile")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if storedHeightCm > 0 && heightInput.isEmpty {
                heightInput = storedHeightCm == storedHeightCm.rounded()
                    ? String(format: "%.0f", storedHeightCm)
                    : String(format: "%.1f", storedHeightCm)
            }
        }
    }

    // MARK: - Height

    private var heightSection: some View {
        VStack(alignment: .leading, spacing: MB.Space.x3) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Height").font(.mbTitle3).foregroundStyle(MB.textPrimary)
                Text("Needed for Apple Health to calculate BMI from the scale weight.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
            MBTextField(label: "Height (cm)", text: $heightInput,
                        icon: "ruler", placeholder: "180", mono: true,
                        hint: "Between 50 and 260 cm")

            MBButton(title: saving ? "Saving…" : "Save height",
                     variant: .primary, size: .lg, icon: "square.and.arrow.down",
                     block: true, loading: saving, disabled: saving) {
                save()
            }
            if let message {
                Text(message)
                    .font(.mbFootnote)
                    .foregroundStyle(isError ? MB.danger : MB.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func lastWeightNote(_ kg: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last weigh-in").font(.mbSubheadEmph).foregroundStyle(MB.textSecondary)
            Text(String(format: "%.2f kg", kg)).font(.mbBody).foregroundStyle(MB.textPrimary)
        }
    }

    // MARK: - Save

    private func save() {
        let normalized = heightInput.replacingOccurrences(of: ",", with: ".")
        guard let cm = Double(normalized), (50...260).contains(cm) else {
            isError = true
            message = "Enter a height between 50 and 260 cm."
            return
        }
        saving = true
        message = nil
        storedHeightCm = cm

        Task {
            do {
                try await HealthKitManager.shared.requestAuthorization()
                try await HealthKitManager.shared.writeHeight(meters: cm / 100)
                // If there's a recent weighing, re-write it so its BMI lands now that we have height
                // (idempotent via sync identifier).
                if let kg = scale.lastWeightKg, let date = scale.lastWeightDate {
                    try await HealthKitManager.shared.writeBodyMass(kg, date: date, heightMeters: cm / 100)
                }
                isError = false
                message = "Height saved to Apple Health."
            } catch {
                isError = true
                message = error.localizedDescription
            }
            saving = false
        }
    }
}
