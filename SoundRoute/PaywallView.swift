import SwiftUI

/// Presented as a sheet from `ContentView`, either when the user taps
/// Unlock or automatically when a free session expires while routing.
///
/// Conforms to App Store Review Guideline 3.1.1 by:
///   - Displaying StoreKit's localized price (transparency).
///   - Providing a Restore Purchases button.
struct PaywallView: View {
    @ObservedObject var storeManager: StoreManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            header
            Divider()
            valueProps

            if let error = storeManager.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 8) {
                unlockButton
                restoreButton
            }
            .padding(.top, 4)

            dismissButton
        }
        .padding(22)
        .frame(width: 340)
        .onChange(of: storeManager.isUnlocked) { _, newValue in
            if newValue { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(.tint)
                .padding(.top, 4)
            Text("Unlock Unlimited Routing")
                .font(.title3.weight(.semibold))
            Text("One-time purchase. Yours forever.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var valueProps: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("infinity", "No session time limit")
            row("waveform.path", "Full routing for vinyl, podcasts, streams")
            row("checkmark.shield", "Buy once. Restore on any of your Macs.")
        }
        .padding(.horizontal, 6)
    }

    private func row(_ systemImage: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                .frame(width: 18)
            Text(text)
                .font(.subheadline)
            Spacer()
        }
    }

    private var unlockButton: some View {
        Button {
            Task { await storeManager.purchase() }
        } label: {
            HStack(spacing: 6) {
                if storeManager.isPurchasing {
                    ProgressView().controlSize(.small)
                }
                Text(unlockButtonText).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .disabled(storeManager.isPurchasing || storeManager.unlockProduct == nil)
    }

    private var unlockButtonText: String {
        if let price = storeManager.unlockProduct?.displayPrice {
            return "Unlock for \(price)"
        }
        return "Unlock"
    }

    private var restoreButton: some View {
        Button {
            Task { await storeManager.restorePurchases() }
        } label: {
            Text("Restore Purchases").frame(maxWidth: .infinity)
        }
        .controlSize(.regular)
        .buttonStyle(.bordered)
        .disabled(storeManager.isPurchasing)
    }

    private var dismissButton: some View {
        Button("Maybe Later") { dismiss() }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.secondary)
    }
}
