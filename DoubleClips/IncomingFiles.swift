import Foundation
import Combine

// MARK: - "Open in DoubleClips"
//
// Info.plist declares DoubleClips as an (alternate) handler for ZIP archives, so a project ZIP
// tapped in Files, Mail, Messages, AirDrop or Safari offers "DoubleClips". iOS then calls
// `.onOpenURL` (DoubleClipsApp), which drops the URL here. HomeView picks it up and runs the
// normal import (ProjectImporter), so Files-import and Open-in behave identically.
//
// A singleton, because the URL can arrive before HomeView exists (cold launch from Files) or
// while another screen is up; it just waits here until HomeView can take it.

final class IncomingFileCenter: ObservableObject {
    static let shared = IncomingFileCenter()
    
    @Published private(set) var pendingZip: URL?
    
    private init() {}
    
    /// Called for every URL iOS hands the app. Only file URLs are projects.
    func receive(_ url: URL) {
        guard url.isFileURL else { return }
        pendingZip = url
    }
    
    /// Hands the waiting URL over exactly once.
    func takePending() -> URL? {
        defer { pendingZip = nil }
        return pendingZip
    }
    
    /// Files opened "not in place" (AirDrop, some apps) are copied into Documents/Inbox, which
    /// would sit there forever, next to the user's projects. Once imported, the copy goes.
    /// Anything else (a file still living in Files / iCloud) is never touched.
    static func removeInboxCopy(_ url: URL) {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == inbox else { return }
        try? fm.removeItem(at: url)
    }
}
