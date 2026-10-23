import SwiftUI
#if canImport(VanVatDriveKit)
import VanVatDriveKit
#endif

/// The blocking Terms of Service popup, same layout as the web: title, subtitle, the product's terms in a scrollable box,
/// a checkbox "I accept the Privacy Policy and Terms of Service" (both are links to the full pages) and a Continue button that
/// stays disabled until the box is ticked. It cannot be dismissed: the only way on is accepting, which the server records.
/// It appears for users who have not accepted yet and again for everyone whenever new terms are published.
///
/// The view knows nothing about the app: it gets closures, so the Drive app and OpenEditz use this same file.
struct TermsGateView: View {
    let status: LegalStatus
    let loadDocument: (_ key: String, _ lang: String?) async throws -> LegalDocument
    let accept: (_ versions: [String: String], _ lang: String) async throws -> LegalStatus
    let pageURL: (_ slug: String, _ lang: String?) -> URL
    let onAccepted: () async -> Void

    @State private var doc: LegalDocument?
    @State private var lang: String?                     // nil = the device language
    @State private var loadFailed = false
    @State private var checked = false
    @State private var busy = false
    @State private var error: String?

    private static let vi = Locale.preferredLanguages.first?.lowercased().hasPrefix("vi") == true
    private func tr(_ en: String, _ vi: String) -> String { Self.vi ? vi : en }
    private var versionsKey: String { status.documents.map { "\($0.key)@\($0.version)" }.joined(separator: "|") }
    private var deviceLang: String { Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            documentBox
            footer
        }
        .padding(20)
        .background(Color(.systemBackground))
        .interactiveDismissDisabled()
        .task(id: "\(versionsKey)|\(lang ?? "")") { await load() }
    }

    // MARK: - Parts

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("Terms of Service", "Điều khoản dịch vụ")).font(.title2.bold())
                Text(tr("Please read and accept the Terms of Service and Privacy Policy to keep using Van Vat Drive.",
                        "Vui lòng đọc và chấp nhận Điều khoản dịch vụ và Chính sách bảo mật để tiếp tục sử dụng Van Vat Drive."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let doc, doc.languages.count > 1 {
                Menu {
                    ForEach(doc.languages, id: \.self) { l in
                        Button(l.uppercased()) { lang = l }
                    }
                } label: { Label(doc.lang.uppercased(), systemImage: "globe") }
            }
        }
    }

    private var documentBox: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let doc {
                    if doc.fallback {
                        Text(tr("This document is not available in your language yet, so it is shown in English.",
                                "Tài liệu này chưa có bản dịch cho ngôn ngữ của bạn nên đang hiển thị bằng tiếng Anh."))
                            .font(.footnote).padding(8)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                    LegalBlocksView(blocks: doc.blocks, headingBase: 3)
                } else if loadFailed {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr("The Terms of Service could not be loaded. Check your connection and try again.",
                                "Không thể tải Điều khoản dịch vụ. Hãy kiểm tra kết nối và thử lại."))
                        Button(tr("Try again", "Thử lại")) { Task { await load() } }.buttonStyle(.bordered)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 30)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Button { checked.toggle() } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(checked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(doc == nil || busy)
                .accessibilityLabel(tr("I accept the Privacy Policy and Terms of Service", "Tôi chấp nhận Chính sách bảo mật và Điều khoản dịch vụ"))
                .accessibilityValue(checked ? "on" : "off")

                Text(acceptLabel).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Button { Task { await submit() } } label: {
                Text(busy ? tr("Saving…", "Đang lưu…") : tr("Continue", "Tiếp tục")).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!checked || busy || doc == nil)
        }
    }

    /// "I accept the {privacy} and {terms}": the two names are blue links to the full pages (word order differs per language).
    private var acceptLabel: AttributedString {
        let template = tr("I accept the {privacy} and {terms}", "Tôi chấp nhận {privacy} và {terms}")
        var out = AttributedString()
        for part in splitTokens(template) {
            switch part {
            case "{privacy}": out += link(tr("Privacy Policy", "Chính sách bảo mật"), slug: "privacy")
            case "{terms}": out += link(tr("Terms of Service", "Điều khoản dịch vụ"), slug: "terms")
            default: out += AttributedString(part)
            }
        }
        return out
    }

    private func splitTokens(_ s: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(s)
        while let r = rest.range(of: #"\{(privacy|terms)\}"#, options: .regularExpression) {
            if r.lowerBound > rest.startIndex { parts.append(String(rest[rest.startIndex..<r.lowerBound])) }
            parts.append(String(rest[r]))
            rest = rest[r.upperBound...]
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    private func link(_ label: String, slug: String) -> AttributedString {
        var a = AttributedString(label)
        a.link = pageURL(slug, doc?.lang ?? lang ?? deviceLang)
        a.foregroundColor = .blue
        a.underlineStyle = .single
        return a
    }

    // MARK: - Actions

    private func load() async {
        doc = nil
        loadFailed = false
        checked = false
        do { doc = try await loadDocument(status.inline, lang ?? deviceLang) }
        catch { loadFailed = true }
    }

    private func submit() async {
        guard checked, !busy, let doc else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            var versions: [String: String] = [:]
            for d in status.documents { versions[d.key] = d.version }
            _ = try await accept(versions, doc.lang)
            await onAccepted()
        } catch {
            self.error = error.localizedDescription
            // New terms were published while this one was open: reload the status so the new text is what gets accepted.
            if (error as? DriveError)?.code == "version_changed" { await onAccepted() }
        }
    }
}

/// Draws the server's blocks: headings, paragraphs, nested lists, quotes and rules, with bold/italic/code/links.
struct LegalBlocksView: View {
    let blocks: [LegalBlock]
    var headingBase = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b.type {
                case "h":
                    Text(attributed(b.spans, base: headingFont(b.level ?? 1)))
                        .padding(.top, 8)
                case "li":
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(b.ordered == true ? "\(b.number ?? 0)." : "•").foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
                        Text(attributed(b.spans, base: .subheadline))
                    }
                    .padding(.leading, CGFloat(b.depth ?? 0) * 18)
                case "quote":
                    Text(attributed(b.spans, base: .subheadline))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.orange).frame(width: 3) }
                case "rule":
                    Divider().padding(.vertical, 4)
                default:
                    Text(attributed(b.spans, base: .subheadline))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level + headingBase - 1 {
        case ...2: return .title3.bold()
        case 3: return .headline
        default: return .subheadline.bold()
        }
    }

    private func attributed(_ spans: [LegalSpan], base: Font) -> AttributedString {
        var out = AttributedString()
        for s in spans {
            var a = AttributedString(s.t)
            var font = base
            if s.b == true { font = font.bold() }
            if s.i == true { font = font.italic() }
            if s.c == true { font = font.monospaced() }
            a.font = font
            if let href = s.href, let url = URL(string: href) {
                a.link = url
                a.foregroundColor = .blue
            }
            out += a
        }
        return out
    }
}
