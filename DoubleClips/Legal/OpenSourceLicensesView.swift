import SwiftUI

// MARK: - Settings > About > Open-source licences
//
// The third-party software inside the app and what the licences ask for: who wrote it, what it is used for, the licence, where its source
// is, and (when the full text is bundled) the licence text itself. The full texts are plain files in the app bundle
// (tools/licenses/fetch-license-texts.sh downloads them; drop the `licenses` folder into the target as a folder reference). Without them the
// screen still shows the notice and the link to the text.
//
// What is in the app: FFmpeg + ffmpeg-kit (converting .mkv / .avi / .webm ... Media/FFmpegBackend.swift), built as LGPL (no GPL, no
// non-free parts) and linked as dynamic frameworks, plus libdav1d when ffmpeg-kit was built with WITH_AV1=1 (AV1 decoding).

struct OpenSourceNotice: Identifiable {
    let id: String
    let name: String
    /// What DoubleClips uses it for.
    let usedFor: String
    let license: String
    let copyright: String
    let links: [(title: String, url: String)]
    var note: String? = nil
    /// Bundled licence text files (without .txt), shown on request.
    var textFiles: [String] = []
}

enum OpenSourceNotices {
    /// false if ffmpeg-kit was built WITHOUT `WITH_AV1=1` (no libdav1d inside): its entry is then left out.
    static let includesAV1 = true

    static var all: [OpenSourceNotice] {
        var list = [ffmpeg, ffmpegKit]
        if includesAV1 { list.append(dav1d) }
        return list
    }

    static let ffmpeg = OpenSourceNotice(
        id: "ffmpeg", name: "FFmpeg",
        usedFor: "Converting video and audio formats iOS can't open (MKV, AVI, WebM, FLV, WMV, Opus, ...) into MP4 / M4A.",
        license: "GNU Lesser General Public License, version 3 or later (LGPL-3.0+)",
        copyright: "Copyright © the FFmpeg developers",
        links: [("Website", "https://ffmpeg.org"),
                ("Source code of the version used (FFmpeg 6.0 as patched by ffmpeg-kit)", "https://github.com/arthenica/FFmpeg"),
                ("Licence text", "https://www.gnu.org/licenses/lgpl-3.0.html")],
        note: "Built without any GPL or non-free component. FFmpeg is linked as separate dynamic frameworks (libavcodec, libavformat, libavutil, libavfilter, libavdevice, libswresample, libswscale): you may replace them with your own build of the same sources, which the app then uses.",
        textFiles: ["LGPL-3.0", "GPL-3.0"])

    static let ffmpegKit = OpenSourceNotice(
        id: "ffmpeg-kit", name: "ffmpeg-kit",
        usedFor: "The wrapper that runs FFmpeg inside the app (version 6.0).",
        license: "GNU Lesser General Public License, version 3 (LGPL-3.0)",
        copyright: "Copyright © ARTHENICA LTD and contributors",
        links: [("Source code", "https://github.com/arthenica/ffmpeg-kit"),
                ("Licence text", "https://www.gnu.org/licenses/lgpl-3.0.html")],
        note: "The project is retired by its authors; the app uses a build made from the v6.0 sources.",
        textFiles: ["LGPL-3.0", "GPL-3.0"])

    static let dav1d = OpenSourceNotice(
        id: "dav1d", name: "dav1d",
        usedFor: "Decoding AV1 video (through FFmpeg).",
        license: "BSD 2-Clause licence",
        copyright: "Copyright © 2018, VideoLAN and dav1d authors. All rights reserved.",
        links: [("Source code", "https://code.videolan.org/videolan/dav1d"),
                ("Licence text", "https://opensource.org/license/bsd-2-clause")],
        textFiles: ["BSD-2-Clause"])
}

struct OpenSourceLicensesView: View {
    var body: some View {
        List {
            Section {
                ForEach(OpenSourceNotices.all) { notice in
                    NavigationLink { OpenSourceNoticeView(notice: notice) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(notice.name).font(.system(size: 16, weight: .semibold))
                            Text(notice.license).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                }
            } footer: {
                Text("DoubleClips is built with the open-source software listed here. Tap one for its licence and where to get its source code.")
            }
        }
        .navigationTitle("Open-source licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct OpenSourceNoticeView: View {
    let notice: OpenSourceNotice
    @State private var shownText: String?

    var body: some View {
        List {
            Section("Used for") { Text(LocalizedStringKey(notice.usedFor)) }
            Section("Licence") {
                Text(notice.license).font(.system(size: 15, weight: .medium))
                Text(notice.copyright).font(.system(size: 13)).foregroundColor(.secondary)
                if let note = notice.note { Text(LocalizedStringKey(note)).font(.system(size: 13)).foregroundColor(.secondary) }
            }
            Section("Links") {
                ForEach(notice.links, id: \.url) { link in
                    if let url = URL(string: link.url) { Link(destination: url) { Label(LocalizedStringKey(link.title), systemImage: "arrow.up.right.square") } }
                }
            }
            if !notice.textFiles.isEmpty {
                Section {
                    Button(shownText == nil ? "Show the licence text" : "Hide the licence text") {
                        shownText = shownText == nil ? Self.loadText(notice.textFiles) : nil
                    }
                    if let shownText {
                        Text(shownText).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle(notice.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The bundled texts joined, or a pointer to the link when none is bundled.
    private static func loadText(_ files: [String]) -> String {
        let texts = files.compactMap { name -> String? in
            let url = Bundle.main.url(forResource: name, withExtension: "txt", subdirectory: "licenses")
                ?? Bundle.main.url(forResource: name, withExtension: "txt")
            return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        return texts.isEmpty ? L("The full text isn't bundled with this build. Use the licence link above.")
                             : texts.joined(separator: "\n\n————————————————————\n\n")
    }
}
