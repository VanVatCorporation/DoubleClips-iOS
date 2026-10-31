import SwiftUI

/// The Templates tab's search bar. It is a button: tapping opens the search screen. Inside, the hot searches take
/// turns: each stays about 3 seconds, then flies up and out while the next one flies up in from below.
struct TemplateSearchBar: View {
    /// The hot searches to rotate through (empty = the plain "Search templates..." prompt).
    let terms: [String]
    @Binding var index: Int
    let onTap: () -> Void

    private let interval: UInt64 = 3_000_000_000

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 16))

                ticker
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Search")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.mdPrimary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.mdSurfaceContainerHigh)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.mdOutlineVariant, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .task(id: terms) { await rotate() }
    }

    private var ticker: some View {
        ZStack(alignment: .leading) {
            if terms.isEmpty {
                Text(L("Search templates..."))
                    .foregroundColor(.secondary)
            } else {
                Text(terms[index % terms.count])
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .id(index)   // a new id = a new view: the old one leaves, the new one comes in
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
        }
        .font(.system(size: 16))
        .frame(height: 22)
        .clipped()   // the text only shows inside the bar
    }

    /// Waits 3 s, flies to the next one, repeats. Cancelled (and restarted) when the list changes or the view leaves.
    private func rotate() async {
        guard terms.count > 1 else { return }
        if index >= terms.count { index = 0 }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.45)) { index += 1 }
        }
    }
}
