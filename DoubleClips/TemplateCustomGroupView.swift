import SwiftUI
import Combine

// MARK: - Custom group: the author edits the template's groups by hand
//
// "Group the same clip" (details screen of Post template) groups the replaceable clips that share one media on its own. That is a
// guess: two clips can be the same shot cut from different files, or one file can be used for clips that should be filled apart.
// "Custom group" lets the author decide: every replaceable clip is a tile (numbered like its slot, coloured like its group); tap
// tiles to select them, then
//   - Group          puts the selected clips in one new group (a clip leaves the group it was in);
//   - Add to group   puts them in a group that already exists;
//   - Ungroup        takes them out of their groups, so each stands alone again;
//   - Reset          goes back to what the automatic grouping made.
// A group needs two clips: when a change leaves one alone in its group, that group is gone. Done keeps the result for the
// upload (the timeline's `templateGroup` ids, see TemplateGrouping.apply); Cancel changes nothing.

@MainActor
final class CustomGroupModel: ObservableObject {
    
    struct GroupInfo: Identifiable {
        let id: String           // the label the clips share
        let members: [UUID]      // slot order
        let colorIndex: Int      // by first appearance, the numbering "Use template" gives its dots
    }
    
    let clips: [PostTemplateDraft.CustomGroupClip]
    /// Clip id -> group label. A clip that isn't in it stands alone; a label with a single clip is no group (`normalize`).
    @Published private(set) var groupOf: [UUID: String]
    @Published var selection = Set<UUID>()
    private let automatic: [UUID: String]
    
    /// `initial`: the grouping the author made on an earlier visit; nil = the automatic one.
    init(clips: [PostTemplateDraft.CustomGroupClip], initial: [UUID: String]?) {
        self.clips = clips
        var auto: [UUID: String] = [:]
        for clip in clips { if let g = clip.autoGroup { auto[clip.id] = g } }
        automatic = auto
        groupOf = initial ?? auto
        normalize()
    }
    
    /// A label used by one clip only isn't a group.
    private func normalize() {
        var counts: [String: Int] = [:]
        for label in groupOf.values { counts[label, default: 0] += 1 }
        groupOf = groupOf.filter { counts[$0.value, default: 0] > 1 }
    }
    
    /// The groups in order of first appearance.
    var groups: [GroupInfo] {
        var order: [String] = []
        var members: [String: [UUID]] = [:]
        for clip in clips {
            guard let label = groupOf[clip.id] else { continue }
            if members[label] == nil { order.append(label) }
            members[label, default: []].append(clip.id)
        }
        return order.enumerated().map { GroupInfo(id: $1, members: members[$1] ?? [], colorIndex: $0) }
    }
    
    func colorIndex(of clip: UUID) -> Int? {
        guard let label = groupOf[clip] else { return nil }
        return groups.first { $0.id == label }?.colorIndex
    }
    
    var isAutomatic: Bool { groupOf == automatic }
    var selectionHasGroupedClip: Bool { selection.contains { groupOf[$0] != nil } }
    
    func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
    
    /// Selects every clip of a group (to move them together or take them apart).
    func select(group: GroupInfo) { selection = Set(group.members) }
    
    func groupSelected() {
        guard selection.count > 1 else { return }
        let label = "custom-" + UUID().uuidString
        for id in selection { groupOf[id] = label }
        selection = []
        normalize()
    }
    
    func add(toGroup label: String) {
        for id in selection { groupOf[id] = label }
        selection = []
        normalize()
    }
    
    func ungroupSelected() {
        for id in selection { groupOf[id] = nil }
        selection = []
        normalize()
    }
    
    func reset() {
        groupOf = automatic
        selection = []
    }
}

struct TemplateCustomGroupView: View {
    let draft: PostTemplateDraft
    /// Called with the grouping the author made, and whether it is the automatic one again.
    let onDone: ([UUID: String], Bool) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CustomGroupModel
    
    init(draft: PostTemplateDraft, initial: [UUID: String]?, onDone: @escaping ([UUID: String], Bool) -> Void) {
        self.draft = draft
        self.onDone = onDone
        _model = StateObject(wrappedValue: CustomGroupModel(clips: draft.groupClips, initial: initial))
    }
    
    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 10)]
    
    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tap clips to select them, then group them. Clips in one group take the same media when someone uses the template.")
                        .font(.system(size: 13)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    if !model.groups.isEmpty { groupChips }
                    
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.clips) { clip in
                            tile(clip)
                        }
                    }
                }
                .padding(16)
            }
            actionBar
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }
    
    // MARK: Top bar
    
    private var topBar: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            Text("Custom group").font(.system(size: 17, weight: .semibold))
            Spacer()
            Button("Done") {
                onDone(model.groupOf, model.isAutomatic)
                dismiss()
            }
            .font(.system(size: 17, weight: .semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Divider() }
    }
    
    // MARK: Groups
    
    /// One chip per group: tap selects all of its clips.
    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.groups) { group in
                    Button { model.select(group: group) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(TemplateGroupPalette.color(group.colorIndex)).frame(width: 10, height: 10)
                            Text(Lf("Group %lld · %lld clips", Int64(group.colorIndex + 1), Int64(group.members.count)))
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private func tile(_ clip: PostTemplateDraft.CustomGroupClip) -> some View {
        let color = model.colorIndex(of: clip.id).map { TemplateGroupPalette.color($0) }
        let selected = model.selection.contains(clip.id)
        return CustomGroupThumbnail(clip: clip)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color ?? Color.clear, lineWidth: 3))
            .overlay(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(selected ? 0.35 : 0)))
            .overlay {
                VStack {
                    HStack(alignment: .top) {
                        if let color {
                            Circle().fill(color).frame(width: 12, height: 12).overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 20))
                            .foregroundColor(selected ? Color.mdPrimary : Color.white.opacity(0.85))
                            .shadow(radius: 2)
                    }
                    Spacer()
                    HStack {
                        Text("\(clip.number)")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.6)).clipShape(Capsule())
                        Spacer()
                        Text(String(format: "%.1fs", clip.duration))
                            .font(.system(size: 11)).foregroundColor(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.black.opacity(0.6)).clipShape(Capsule())
                    }
                }
                .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.toggle(clip.id) }
    }
    
    // MARK: Actions
    
    private var actionBar: some View {
        VStack(spacing: 10) {
            HStack {
                Text(model.selection.isEmpty ? L("Nothing selected") : Lf("%lld selected", Int64(model.selection.count)))
                    .font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                if !model.selection.isEmpty {
                    Button("Clear selection") { model.selection = [] }
                        .font(.system(size: 12, weight: .semibold))
                }
                Button("Reset to automatic") { model.reset() }
                    .font(.system(size: 12, weight: .semibold))
                    .disabled(model.isAutomatic)
            }
            HStack(spacing: 10) {
                actionButton("Group", icon: "link", filled: true, enabled: model.selection.count > 1) { model.groupSelected() }
                
                Menu {
                    ForEach(model.groups) { group in
                        Button {
                            model.add(toGroup: group.id)
                        } label: {
                            Text(Lf("Group %lld · %lld clips", Int64(group.colorIndex + 1), Int64(group.members.count)))
                        }
                    }
                } label: {
                    actionLabel("Add to group", icon: "plus.circle", filled: false,
                                enabled: !model.selection.isEmpty && !model.groups.isEmpty)
                }
                .disabled(model.selection.isEmpty || model.groups.isEmpty)
                
                actionButton("Ungroup", icon: "link.badge.plus", filled: false, enabled: model.selectionHasGroupedClip) {
                    model.ungroupSelected()
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea(edges: .bottom))
    }
    
    private func actionButton(_ title: String, icon: String, filled: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(title, icon: icon, filled: filled, enabled: enabled) }
            .buttonStyle(.plain)
            .disabled(!enabled)
    }
    
    private func actionLabel(_ title: String, icon: String, filled: Bool, enabled: Bool) -> some View {
        Label(L(title), systemImage: icon)
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1).minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundColor(filled ? .white : Color.mdPrimary)
            .background(filled ? Color.mdPrimary : Color.mdPrimary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.4)
    }
}

/// The first picture of a clip's media, where the template's clip starts in it.
private struct CustomGroupThumbnail: View {
    let clip: PostTemplateDraft.CustomGroupClip
    @State private var image: UIImage?
    
    var body: some View {
        Color.secondary.opacity(0.2)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: clip.isImage ? "photo" : "film").foregroundColor(.secondary)
                }
            }
            .clipped()
        .task(id: clip.id) {
            image = await ClipMediaCache.shared.thumbnail(url: clip.mediaURL, isVideo: !clip.isImage, time: clip.mediaTime)
        }
    }
}
