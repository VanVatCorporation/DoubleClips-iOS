import Foundation

/// iOS equivalent of Constants.java
/// All file/directory name constants and template marks used across the app.
enum Constants {

    // MARK: - File Names
    static let DEFAULT_PROJECT_PROPERTIES_FILENAME  = "project.properties"
    static let DEFAULT_TIMELINE_FILENAME            = "project.timeline"
    static let DEFAULT_VIDEO_SETTINGS_FILENAME      = "project.settings"
    static let DEFAULT_PREVIEW_CLIP_FILENAME        = "preview.mp4"
    static let DEFAULT_EXPORT_CLIP_FILENAME         = "export.mp4"

    // MARK: - Directory Names
    static let DEFAULT_LOGGING_DIRECTORY            = "Logging"
    static let DEFAULT_TEMPLATE_CLIP_TEMP_DIRECTORY = "TemplatesClipTemp"
    static let DEFAULT_CLIP_DIRECTORY               = "Clips"
    static let DEFAULT_PREVIEW_CLIP_DIRECTORY       = "PreviewClips"
    static let DEFAULT_CLIP_TEMP_DIRECTORY          = "Clips/Temp"

    // MARK: - FFmpeg / Template Marks
    /// Separator used when splitting multiple FFmpeg commands in a single string
    static let DEFAULT_MULTI_FFMPEG_COMMAND_REGEX   = "<Ffmpeg Command Splitter hehe lmao skibidi tung tung tung sahur>"
    static let DEFAULT_TEMPLATE_CLIP_EXPORT_MARK    = "<output.mp4>"
    static let DEFAULT_TEMPLATE_CLIP_SCALE_WIDTH_MARK  = "<scale-width>"
    static let DEFAULT_TEMPLATE_CLIP_SCALE_HEIGHT_MARK = "<scale-height>"

    static func DEFAULT_TEMPLATE_CLIP_STATIC_MARK(_ resourceName: String) -> String {
        "<static-\(resourceName)>"
    }
    static func DEFAULT_TEMPLATE_CLIP_MARK(_ index: Int) -> String {
        "<editable-video-\(index)>"
    }
    static func DEFAULT_TEMPLATE_TRIM_MARK(_ index: Int) -> String {
        "<editable-video-trim-\(index)>"
    }

    // MARK: - Numeric Constants
    static let SAMPLE_SIZE_PREVIEW_CLIP: Int            = 16
    static let DEFAULT_LOGGING_LIMIT_CHARACTERS: Int    = 10_000
    static let DEFAULT_DEBUG_LOGGING_SIZE: Int          = 1_048_576   // 1 MB

    // MARK: - Canvas / Snap Constants
    static let CANVAS_ROTATE_SNAP_THRESHOLD_DEGREE: Float  = 3.0   // degrees
    static let CANVAS_ROTATE_SNAP_DEGREE: Float             = 90.0
    static var TRACK_CLIPS_SNAP_THRESHOLD_PIXEL: Float      = 30.0  // pixels
    static var TRACK_CLIPS_SNAP_THRESHOLD_SECONDS: Float    = 0.1   // seconds
    static var TRACK_CLIPS_MINIMUM_KEYFRAME_SPACE_SECONDS: Float = 0.01 // seconds
    static var TRACK_CLIPS_SHRINK_LIMIT_PIXEL: Float        = 20.0  // pixels

    // MARK: - Project Directory
    /// Root directory for all projects — equivalent of DEFAULT_PROJECT_DIRECTORY(context)
    /// On iOS we use the app's Documents directory (persistent, user-visible).
    static var DEFAULT_PROJECT_DIRECTORY: String {
        IOHelper.combinePath(IOHelper.persistentDataPath, "projects")
    }
}
