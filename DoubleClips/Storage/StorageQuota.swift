import SwiftUI

/// Where account tiers are bought. Tiers live on the account (one pack for every Van Vat service).
enum Plans {
    static let url = URL(string: "https://account.vanvatcorp.com/account-center/#plans")!
}

enum QuotaTone {
    case normal, warn, danger

    var color: Color {
        switch self {
        case .normal: return .accentColor
        case .warn: return .orange
        case .danger: return .red
        }
    }

    /// Same thresholds as the web Drive: below 50% remaining = warn, below 25% remaining = danger.
    static func of(used: Double, total: Double) -> QuotaTone {
        guard total > 0 else { return .normal }
        let ratio = max(0, total - used) / total
        if ratio < 0.25 { return .danger }
        if ratio < 0.50 { return .warn }
        return .normal
    }
}

/// A progress bar plus a caption, coloured by how much is left.
struct QuotaBar: View {
    let used: Double
    let total: Double
    let label: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: min(max(used, 0), max(total, 1)), total: max(total, 1))
                .tint(QuotaTone.of(used: used, total: total).color)
            Text(label).font(.footnote).foregroundStyle(.secondary)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 2)
    }
}

/// "Continue anyway" popup shown before an upload/download that probably won't fit today's allowance.
struct QuotaWarning: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onConfirm: () -> Void
    var onCancel: () -> Void = {}
}

extension View {
    func quotaWarning(_ warning: Binding<QuotaWarning?>) -> some View {
        alert(warning.wrappedValue?.title ?? "", isPresented: Binding(
            get: { warning.wrappedValue != nil },
            set: { if !$0 { warning.wrappedValue = nil } }
        ), presenting: warning.wrappedValue) { w in
            Button("Continue anyway", role: .destructive) { w.onConfirm() }
            Button("Cancel", role: .cancel) { w.onCancel() }
        } message: { w in
            Text(w.message)
        }
    }
}

/// The warning wording of the web Drive.
enum QuotaText {
    static let uploadTitle = "Daily upload limit warning"
    static let downloadTitle = "Daily download limit warning"

    static func upload(size: Int64, free: Int64) -> String {
        "You might not have enough daily upload quota left to upload this file (\(StorageModel.bytes(size)) selected, only \(StorageModel.bytes(free)) left today). The upload may stop once the limit is reached."
    }

    static func download(size: Int64, free: Int64) -> String {
        "You might not have enough daily download quota left for this file (\(StorageModel.bytes(size)) requested, only \(StorageModel.bytes(free)) left today). The download may be cut off once the limit is reached."
    }

    static func credits(_ n: Double) -> String {
        n == n.rounded() ? String(Int(n)) : String(format: "%.1f", n)
    }
}

/// "Get more resources": opens the account tier upgrade in the browser.
struct GetMoreResourcesButton: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        Button { openURL(Plans.url) } label: { Label("Get more resources", systemImage: "arrow.up.circle") }
    }
}

/// Storage + daily limits + plan, for the top of the Storage tab. Minimalist: only the storage bar shows;
/// the chevron animates open to reveal the plan, the daily limits and the upgrade link.
struct QuotaSummary: View {
    let me: Me
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    QuotaBar(used: Double(me.usedBytes), total: Double(me.quotaBytes),
                             label: "\(StorageModel.bytes(me.usedBytes)) of \(StorageModel.bytes(me.quotaBytes)) used")
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide other limits" : "Show other limits")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let plan = me.plan {
                        Text("Plan: \(plan.name)").font(.footnote.weight(.semibold))
                    }
                    if let usage = me.usage {
                        let reset = "Resets \(usage.resetsAt.formatted(date: .abbreviated, time: .shortened))"
                        QuotaBar(used: Double(usage.uploadedBytes), total: Double(usage.uploadLimit),
                                 label: "Today: ↑ \(StorageModel.bytes(usage.uploadedBytes)) / \(StorageModel.bytes(usage.uploadLimit))", caption: reset)
                        QuotaBar(used: Double(usage.downloadedBytes), total: Double(usage.downloadLimit),
                                 label: "Today: ↓ \(StorageModel.bytes(usage.downloadedBytes)) / \(StorageModel.bytes(usage.downloadLimit))", caption: reset)
                        if let limit = usage.computeLimit {
                            QuotaBar(used: usage.computeUsed ?? 0, total: limit,
                                     label: "Today: compute \(QuotaText.credits(usage.computeUsed ?? 0)) / \(QuotaText.credits(limit)) credits", caption: reset)
                        }
                    }
                    GetMoreResourcesButton().font(.footnote)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }
}
