import SwiftUI

// MARK: - Post template: the four cards
//
// Android's layout_post_template.xml (a ViewFlipper), same four pages:
//   1. Preview         the rendered template video, looping, with Next
//   2. Edit details    thumbnail, title, description; Save draft / Upload template
//   3. Uploading       progress bar, thumbnail, status; Back / Retry when it fails
//   4. Completed       "Upload Completed!", the template id, Done
// The same post-template API as Android and desktop (see TemplatePosting.swift).

struct PostTemplateView: View {
    let draft: PostTemplateDraft
    
    @Environment(\.dismiss) private var dismiss
    @StateObject private var uploader = TemplateUploader()
    @StateObject private var player = TemplatePreviewPlayer()
    
    @State private var step = 0
    @State private var forward = true
    @State private var title = ""
    @State private var descriptionText = ""
    @State private var showLoginAlert = false
    @State private var templateId = ""
    @FocusState private var focused: Field?
    private enum Field { case title, description }
    
    private var thumbnail: UIImage? {
        draft.previewImage.flatMap { UIImage(contentsOfFile: $0.path) }
    }
    
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            Group {
                switch step {
                case 0: previewCard
                case 1: detailsCard
                case 2: uploadingCard
                default: completedCard
                }
            }
            .transition(.asymmetric(
                insertion: .move(edge: forward ? .trailing : .leading),
                removal: .move(edge: forward ? .leading : .trailing)))
            .id(step)
        }
        .clipped()
        .onAppear { player.activate(draft.previewVideo) }
        .onDisappear { player.deactivate() }
        .onChange(of: uploader.state) { state in
            if case .done(let id) = state {
                templateId = id
                go(to: 3)
            }
        }
        .alert("Login required", isPresented: $showLoginAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please login to post template")
        }
    }
    
    private func go(to newStep: Int) {
        guard newStep != step else { return }
        forward = newStep > step
        withAnimation(.easeInOut(duration: 0.28)) { step = newStep }
        // The preview only plays while its card is showing.
        if newStep == 0 { player.activate(draft.previewVideo) } else { player.pause() }
    }
    
    // MARK: 1. Preview
    
    private var previewCard: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar("Preview", dark: true) { dismiss() }
                TemplatePlayerLayerView(player: player.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture { player.toggle() }
                bigButton("Next", filled: true) { go(to: 1) }
                    .padding(16)
            }
        }
    }
    
    // MARK: 2. Edit details
    
    private var detailsCard: some View {
        VStack(spacing: 0) {
            topBar("Edit details", dark: false) { go(to: 0) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if let thumbnail {
                                Image(uiImage: thumbnail).resizable().scaledToFill()
                            } else {
                                Color.secondary.opacity(0.2)
                            }
                        }
                        .frame(width: 96, height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        
                        TextField("Template title...", text: $title, axis: .vertical)
                            .lineLimit(1...3)
                            .font(.system(size: 17, weight: .semibold))
                            .focused($focused, equals: .title)
                    }
                    Divider()
                    ZStack(alignment: .topLeading) {
                        if descriptionText.isEmpty {
                            Text("Add description...").foregroundColor(.secondary).padding(.top, 8).padding(.leading, 5)
                        }
                        TextEditor(text: $descriptionText)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .focused($focused, equals: .description)
                    }
                    Divider()
                    contentsSummary
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            
            HStack(spacing: 12) {
                bigButton("Save draft", filled: false) { dismiss() }
                bigButton("Upload template", filled: true) { startUpload() }
            }
            .padding(16)
        }
    }
    
    /// What the template is made of, so the author knows what goes up.
    private var contentsSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryRow("rectangle.dashed", "\(draft.replaceableCount) clip\(draft.replaceableCount == 1 ? "" : "s") to replace",
                       tint: nil)
            summaryRow("lock.fill", "\(draft.lockedCount) locked", tint: nil)
            summaryRow("clock", ExportSheetView.formatDuration(draft.duration), tint: nil)
            summaryRow("doc.on.doc", "\(draft.contentFiles.count) file\(draft.contentFiles.count == 1 ? "" : "s") to upload"
                       + (draft.contentBytes > 0 ? " · " + TimelineExporter.formatBytes(draft.contentBytes) : ""), tint: nil)
            ForEach(draft.warnings, id: \.self) { warning in
                summaryRow("exclamationmark.triangle.fill", warning, tint: .orange)
            }
        }
        .font(.system(size: 14))
    }
    
    private func summaryRow(_ icon: String, _ text: String, tint: Color?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundColor(tint ?? .secondary)
            Text(text).foregroundColor(tint ?? .primary).fixedSize(horizontal: false, vertical: true)
        }
    }
    
    // MARK: 3. Uploading
    
    private var uploadFailed: String? {
        if case .failed(let message) = uploader.state { return message }
        return nil
    }
    
    private var uploadingCard: some View {
        VStack(spacing: 22) {
            Spacer()
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25))
                    Capsule()
                        .fill(uploadFailed == nil ? Color.mdPrimary : Color.red)
                        .frame(width: geo.size.width * (uploadFailed == nil ? uploader.progress : 1))
                        .animation(.linear(duration: 0.15), value: uploader.progress)
                }
            }
            .frame(height: 10)
            .padding(.horizontal, 32)
            
            Text(statusText)
                .font(.system(size: 15))
                .foregroundColor(uploadFailed == nil ? .primary : .red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            if uploadFailed != nil {
                HStack(spacing: 12) {
                    bigButton("Back", filled: false) { uploader.reset(); go(to: 1) }
                    bigButton("Retry", filled: true) { startUpload() }
                }
                .padding(.horizontal, 32)
            } else {
                Button("Cancel") { uploader.reset(); go(to: 1) }
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
    
    private var statusText: String {
        if let message = uploadFailed { return "Failed to upload: \(message)" }
        return "Uploading... \(Int(uploader.progress * 100))%"
    }
    
    // MARK: 4. Completed
    
    private var completedCard: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 84))
                .foregroundColor(.green)
            Text("Upload Completed!").font(.system(size: 22, weight: .bold))
            if !templateId.isEmpty {
                Text("Template ID: \(templateId)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            bigButton("Done", filled: true) { dismiss() }
                .padding(16)
        }
    }
    
    // MARK: Upload
    
    private func startUpload() {
        guard let username = AuthRepository.shared.currentUser?.username, !username.isEmpty else {
            showLoginAlert = true
            return
        }
        focused = nil
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = cleanTitle.isEmpty ? draft.defaultTitle : cleanTitle
        // Android: an empty description falls back to the title as well.
        let finalDescription = cleanDescription.isEmpty ? finalTitle : cleanDescription
        
        // No ffmpegCommand: it stays NULL (iOS has no FFmpeg), the timeline is the template.
        let fields: [(String, String)] = [
            ("accountUsername", username),
            ("accountPassword", Constants.TEMPLATE_POST_PASSWORD_PLACEHOLDER),
            ("templateTitle", finalTitle),
            ("templateDescription", finalDescription),
            ("templateTimelineJson", draft.timelineJSON),
            ("templateTotalClips", String(draft.replaceableCount))
        ]
        var files: [(field: String, file: PostFile)] = draft.contentFiles.map { ("videoFiles", $0) }
        if let image = draft.previewImage { files.append(("previewFiles", PostFile(url: image, name: "preview.png"))) }
        files.append(("previewFiles", PostFile(url: draft.previewVideo, name: Constants.DEFAULT_PREVIEW_CLIP_FILENAME)))
        
        go(to: 2)
        uploader.upload(to: URL(string: Constants.TEMPLATE_POST_URL)!, fields: fields, files: files)
    }
    
    // MARK: Pieces
    
    private func topBar(_ title: String, dark: Bool, back: @escaping () -> Void) -> some View {
        ZStack {
            Text(title).font(.system(size: 17, weight: .bold))
            HStack {
                Button(action: back) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 50, height: 50)
                }
                Spacer()
            }
        }
        .foregroundColor(dark ? .white : .primary)
        .frame(height: 50)
    }
    
    private func bigButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundColor(filled ? .white : Color.mdPrimary)
                .background(filled ? Color.mdPrimary : Color.mdPrimary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
