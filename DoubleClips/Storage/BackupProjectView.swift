import SwiftUI

/// Pick a local project; it is zipped (same ZIP as "Share project") and uploaded to OpenEditz/Projects.
struct BackupProjectView: View {
    @ObservedObject var model: StorageModel
    @Environment(\.dismiss) private var dismiss

    @State private var projects: [ProjectData] = []
    @State private var loading = true

    private var running: Bool {
        guard let b = model.backup else { return false }
        return b.phase == .zipping || b.phase == .uploading
    }

    var body: some View {
        NavigationStack {
            Group {
                if let backup = model.backup { progressView(backup) } else { list }
            }
            .navigationTitle("Back up a project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(running ? "Stop" : "Close") {
                        if running { model.cancelBackup() } else { model.dismissBackup(); dismiss() }
                    }
                }
            }
            .task { loadProjects() }
        }
        .interactiveDismissDisabled(running)
    }

    private var list: some View {
        List {
            if loading { ProgressView() }
            if !loading && projects.isEmpty {
                ContentUnavailableView("No projects", systemImage: "film", description: Text("Create a project first, then come back to back it up."))
            }
            ForEach(projects) { project in
                Button { model.startBackup(project) } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.projectTitle).lineLimit(1)
                            Text("About \(StorageModel.bytes(project.projectSize)) · \(Date(timeIntervalSince1970: TimeInterval(project.projectTimestamp) / 1000).formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "icloud.and.arrow.up").foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private func progressView(_ backup: StorageModel.BackupState) -> some View {
        VStack(spacing: 16) {
            Spacer()
            switch backup.phase {
            case .zipping, .uploading:
                ProgressView(value: backup.fraction)
                    .padding(.horizontal, 40)
                Text(backup.phase == .zipping ? "Packing “\(backup.title)”…" : "Uploading “\(backup.title)”…")
                Text("\(Int(backup.fraction * 100))%").font(.footnote).foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(.green)
                Text("Backed up to OpenEditz/Projects")
                Button("Done") { model.dismissBackup(); dismiss() }.buttonStyle(.borderedProminent)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center).padding(.horizontal, 30)
                Button("Back") { model.dismissBackup() }.buttonStyle(.bordered)
            }
            Spacer()
        }
    }

    // Same loader HomeView uses.
    private func loadProjects() {
        DispatchQueue.global(qos: .userInitiated).async {
            IOHelper.createEmptyDirectories(Constants.DEFAULT_PROJECT_DIRECTORY)
            let dirs = IOHelper.listFiles(Constants.DEFAULT_PROJECT_DIRECTORY, options: .directories)
            var loaded: [ProjectData] = []
            for dir in dirs {
                if let data = ProjectData.loadProperties(from: dir.path) { loaded.append(data) }
            }
            loaded.sort { $0.projectTimestamp > $1.projectTimestamp }
            DispatchQueue.main.async {
                projects = loaded
                loading = false
            }
        }
    }
}
