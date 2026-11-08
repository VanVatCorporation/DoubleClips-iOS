import SwiftUI

/// Profile → Statistics. Two parts: what is on THIS phone (projects, footage, storage, activity by month; works signed out), and
/// how the account's templates perform, which the SERVER counts (`AuthorStatsAPI`): all-time totals, the last 7 / 30 / 90 days
/// against the same number of days before, a per-day chart of other people's activity, and the top templates.
struct StatisticsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var authRepo = AuthRepository.shared

    private enum Metric: CaseIterable {
        case uses, views, likes, saves

        var label: String {
            switch self {
            case .uses: return L("Uses")
            case .views: return L("Views")
            case .likes: return L("Likes")
            case .saves: return L("Saves")
            }
        }

        /// What one bar of the daily chart counts ("new viewers" for views: the first time somebody opened a template).
        var unit: String {
            switch self {
            case .uses: return L("uses")
            case .views: return L("new viewers")
            case .likes: return L("likes")
            case .saves: return L("saves")
            }
        }
    }

    private enum Phase {
        case loading
        case loaded(AuthorStats)
        case failed(String)
    }

    @State private var local = LocalStats.empty
    @State private var phase: Phase = .loading
    @State private var days = 30
    @State private var metric: Metric = .uses
    @State private var selectedDay: String?

    private var isLoggedIn: Bool { authRepo.currentUser != nil }

    var body: some View {
        ZStack {
            Color.mdBackground.edgesIgnoringSafeArea(.all)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)
                            .frame(width: 44, height: 44)
                    }
                    Text(L("Statistics"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 8)

                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        deviceSection
                        templatesSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 40)
                }
            }
        }
        .task { local = await LocalStats.load() }
        .task(id: "\(days)|\(isLoggedIn)") { await loadRemote() }       // on open, a new period, or signing in / out
    }

    // MARK: - On this phone

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L("On this phone"))

            LazyVGrid(columns: Self.columns, spacing: 12) {
                StatTile(label: L("Projects"), value: "\(local.count)")
                StatTile(label: L("Total footage"), value: Self.duration(local.totalMs))
                StatTile(label: L("Storage used"), value: ByteCountFormatter.string(fromByteCount: local.totalBytes, countStyle: .file))
                StatTile(label: L("Last edited"),
                         value: local.latest.map { Self.date($0.projectTimestamp) } ?? "—",
                         sub: local.latest?.projectTitle,
                         valueSize: 20)
                if let p = local.longest, p.projectDuration > 0 {
                    StatTile(label: L("Longest project"), value: Self.duration(p.projectDuration), sub: p.projectTitle)
                }
                if let p = local.biggest, p.projectSize > 0 {
                    StatTile(label: L("Biggest project"),
                             value: ByteCountFormatter.string(fromByteCount: p.projectSize, countStyle: .file),
                             sub: p.projectTitle)
                }
            }

            if local.count > 0 {
                smallTitle(L("Projects last edited, by month"))
                monthBars
            }
        }
    }

    private var monthBars: some View {
        let peak = max(1, local.months.map { $0.count }.max() ?? 1)
        return HStack(alignment: .bottom, spacing: 14) {
            ForEach(local.months) { m in
                VStack(spacing: 6) {
                    Text("\(m.count)").font(.system(size: 11)).foregroundColor(.secondary)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.mdPrimary)
                        .frame(width: 34, height: m.count == 0 ? 4 : 10 + 100 * CGFloat(m.count) / CGFloat(peak))
                    Text(m.name).font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Your templates (counted by the server)

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(L("Your templates"))

            if !isLoggedIn {
                mutedLine(L("Sign in to see how your templates perform."))
            } else {
                Picker("", selection: $days) {
                    ForEach([7, 30, 90], id: \.self) { Text(Lf("%d days", $0)).tag($0) }
                }
                .pickerStyle(.segmented)

                switch phase {
                case .loading:
                    HStack(spacing: 10) {
                        ProgressView()
                        mutedLine(L("Loading your templates..."))
                    }
                case .failed(let message):
                    mutedLine(L("Couldn't load your templates") + ": " + message)
                    Button(L("Retry")) { Task { await loadRemote() } }
                        .buttonStyle(.bordered)
                case .loaded(let stats):
                    if stats.totals.templates == 0 {
                        mutedLine(L("You haven't posted a template yet"))
                    } else {
                        remoteContent(stats)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func remoteContent(_ stats: AuthorStats) -> some View {
        let t = stats.totals
        let useRate: String? = t.views > 0
            ? Lf("%@ of views", String(format: "%.1f%%", 100.0 * Double(t.uses) / Double(t.views)))
            : nil

        smallTitle(L("All time"))
        LazyVGrid(columns: Self.columns, spacing: 12) {
            StatTile(label: L("Templates"), value: Self.compact(t.templates))
            StatTile(label: L("Views"), value: Self.compact(t.views))
            StatTile(label: L("Uses"), value: Self.compact(t.uses), sub: useRate)
            StatTile(label: L("Likes"), value: Self.compact(t.likes))
            StatTile(label: L("Saves"), value: Self.compact(t.saves))
            StatTile(label: L("Comments"), value: Self.compact(t.comments))
            StatTile(label: L("Unique viewers"), value: Self.compact(t.uniqueViewers), sub: L("people who opened them"))
        }

        let cur = stats.period.current
        let prev = stats.period.previous
        smallTitle(Lf("Last %d days (change against the %d days before)", stats.days, stats.days))
        LazyVGrid(columns: Self.columns, spacing: 12) {
            deltaTile(L("New viewers"), cur.newViewers, prev.newViewers)
            deltaTile(L("Uses"), cur.uses, prev.uses)
            deltaTile(L("Likes"), cur.likes, prev.likes)
            deltaTile(L("Saves"), cur.saves, prev.saves)
            deltaTile(L("Comments"), cur.comments, prev.comments)
        }

        smallTitle(L("Activity per day"))
        Picker("", selection: $metric) {
            ForEach(Metric.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        dailyChart(stats.series)

        let sorted = stats.templates.sorted { value($0) > value($1) }
        let top = sorted.first.map { value($0) } ?? 0
        smallTitle(L("Top templates"))
        VStack(spacing: 14) {
            ForEach(Array(sorted.prefix(5).enumerated()), id: \.element.id) { index, item in
                topRow(rank: index + 1, item: item, value: value(item), top: top)
            }
        }
    }

    private func value(_ d: AuthorStats.Day) -> Int {
        switch metric {
        case .uses: return d.uses
        case .views: return d.newViewers
        case .likes: return d.likes
        case .saves: return d.saves
        }
    }

    private func value(_ d: AuthorStats.Item) -> Int {
        switch metric {
        case .uses: return d.uses
        case .views: return d.views
        case .likes: return d.likes
        case .saves: return d.saves
        }
    }

    /// One bar per local day of the current period. Tap a bar to read its day and number above the chart.
    private func dailyChart(_ series: [AuthorStats.Day]) -> some View {
        let peak = max(1, series.map { value($0) }.max() ?? 1)
        let picked = series.first { $0.date == selectedDay }
        let periodTotal = series.reduce(0) { $0 + value($1) }

        return VStack(alignment: .leading, spacing: 8) {
            Text(picked.map { "\($0.date): \(value($0)) \(metric.unit)" } ?? "\(periodTotal) \(metric.unit)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)

            HStack(alignment: .bottom, spacing: series.count > 45 ? 1 : 3) {
                ForEach(series) { d in
                    let v = value(d)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(d.date == selectedDay ? Color.mdSecondary : (v == 0 ? Color.mdSurfaceContainerHigh : Color.mdPrimary))
                        .frame(height: v == 0 ? 3 : 8 + 112 * CGFloat(v) / CGFloat(peak))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle().inset(by: -4))
                        .onTapGesture { selectedDay = (selectedDay == d.date) ? nil : d.date }
                        .accessibilityLabel("\(d.date): \(v) \(metric.unit)")
                }
            }
            .frame(height: 120, alignment: .bottom)

            HStack {
                Text(series.first?.date ?? "")
                Spacer()
                Text(series.last?.date ?? "")
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary)
        }
    }

    private func topRow(rank: Int, item: AuthorStats.Item, value: Int, top: Int) -> some View {
        let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fraction = top > 0 ? min(1, CGFloat(value) / CGFloat(top)) : 0
        return HStack(spacing: 12) {
            Text("\(rank)")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(title.isEmpty ? L("Untitled") : title)
                    .font(.system(size: 14))
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.mdSurfaceContainerHigh)
                        Capsule().fill(Color.mdPrimary).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 8)
            }
            Text(Self.compact(value))
                .font(.system(size: 14, weight: .bold))
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    /// A tile with this period's number and a green / red change against the previous period.
    private func deltaTile(_ label: String, _ current: Int, _ previous: Int) -> some View {
        let text: String
        var color: Color = .secondary
        if current == previous {
            text = L("No change")
        } else if previous == 0 {
            text = "▲ " + L("new")
            color = .green
        } else {
            let pct = 100.0 * Double(current - previous) / Double(previous)
            text = (pct > 0 ? "▲ " : "▼ ") + String(format: "%.0f%%", abs(pct))
            color = pct > 0 ? .green : .red
        }
        return StatTile(label: label, value: Self.compact(current), sub: text, subColor: color, subBold: color != .secondary)
    }

    // MARK: - Loading

    private func loadRemote() async {
        guard isLoggedIn else { return }
        phase = .loading
        do {
            let stats = try await AuthorStatsAPI.fetch(days: days)
            if Task.isCancelled { return }
            phase = .loaded(stats)
            selectedDay = nil
        } catch let error as URLError where error.code == .cancelled {
            return                                  // another period was picked meanwhile
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Small pieces

    private static let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 20, weight: .bold))
    }

    private func smallTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
    }

    private func mutedLine(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    /// 950 → "950", 1234 → "1.2K", 3_400_000 → "3.4M".
    static func compact(_ n: Int) -> String {
        func trimmed(_ v: Double, _ suffix: String) -> String {
            let s = String(format: "%.1f", v)
            return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        if n < 1_000 { return "\(n)" }
        if n < 1_000_000 { return trimmed(Double(n) / 1_000, "K") }
        if n < 1_000_000_000 { return trimmed(Double(n) / 1_000_000, "M") }
        return trimmed(Double(n) / 1_000_000_000, "B")
    }

    static func duration(_ ms: Int64) -> String {
        let seconds = max(0, ms) / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    static func date(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: AppLanguage.currentCode)
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

// MARK: - A tile

private struct StatTile: View {
    let label: String
    let value: String
    var sub: String? = nil
    var subColor: Color = .secondary
    var subBold: Bool = false
    var valueSize: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: valueSize, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            if let sub = sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11, weight: subBold ? .bold : .regular))
                    .foregroundColor(subColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.mdSurface)
        .cornerRadius(14)
    }
}

// MARK: - The phone's own numbers

/// What the project list on this phone adds up to. Read from each project's saved metadata (`project.properties`), the same
/// source the Home screen lists, so a number can lag until a project has been saved once.
struct LocalStats {
    struct Month: Identifiable {
        let name: String
        let count: Int
        var id: String { name + "\(count)" }
    }

    var count = 0
    var totalMs: Int64 = 0
    var totalBytes: Int64 = 0
    var longest: ProjectData?
    var biggest: ProjectData?
    var latest: ProjectData?
    /// The last six months, oldest first: how many projects were last edited in each.
    var months: [Month] = []

    static let empty = LocalStats()

    static func load() async -> LocalStats {
        await Task.detached(priority: .userInitiated) { () -> LocalStats in
            let dirs = IOHelper.listFiles(Constants.DEFAULT_PROJECT_DIRECTORY, options: .directories)
            var projects: [ProjectData] = []
            for dir in dirs {
                if let p = ProjectData.loadProperties(from: dir.path) { projects.append(p) }
            }
            return LocalStats.make(from: projects)
        }.value
    }

    private static func make(from projects: [ProjectData]) -> LocalStats {
        var s = LocalStats()
        s.count = projects.count
        for p in projects {
            s.totalMs += max(0, p.projectDuration)
            s.totalBytes += max(0, p.projectSize)
            if s.longest == nil || p.projectDuration > s.longest!.projectDuration { s.longest = p }
            if s.biggest == nil || p.projectSize > s.biggest!.projectSize { s.biggest = p }
            if s.latest == nil || p.projectTimestamp > s.latest!.projectTimestamp { s.latest = p }
        }

        let calendar = Calendar.current
        let thisMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let nameFormat = DateFormatter()
        nameFormat.locale = Locale(identifier: AppLanguage.currentCode)
        nameFormat.setLocalizedDateFormatFromTemplate("MMM")

        var counts = [Int](repeating: 0, count: 6)
        for p in projects {
            let when = Date(timeIntervalSince1970: TimeInterval(p.projectTimestamp) / 1000)
            guard let start = calendar.dateInterval(of: .month, for: when)?.start else { continue }
            let diff = calendar.dateComponents([.month], from: start, to: thisMonth).month ?? 99
            if diff >= 0 && diff < 6 { counts[5 - diff] += 1 }
        }
        s.months = (0..<6).map { i in
            let monthStart = calendar.date(byAdding: .month, value: i - 5, to: thisMonth) ?? thisMonth
            return Month(name: nameFormat.string(from: monthStart), count: counts[i])
        }
        return s
    }
}
