import Foundation
import CoreGraphics

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

    // MARK: - Timeline layout
    /// Height of one track row (Android: EditingActivity.TRACK_HEIGHT). The label cell, the row, the
    /// "add track" row/button, the scroll content height, clip hit-testing and the drag ghost all
    /// derive from this one number — change it here and the whole timeline follows.
    static let TRACK_HEIGHT: CGFloat       = 75
    /// Width of the track label column ("T1", "T2" and the add-track "+" button).
    static let TRACK_LABEL_WIDTH: CGFloat  = 50
    /// Gap between a row's top/bottom edge and the clip block inside it.
    static let TRACK_CLIP_INSET: CGFloat   = 6
    /// Height of a clip block: the row minus the inset above and below.
    static var TRACK_CLIP_HEIGHT: CGFloat { TRACK_HEIGHT - TRACK_CLIP_INSET * 2 }

    // MARK: - Export (iOS: Core Image compositor -> AVAssetReader -> AVAssetWriter, H.264 + AAC)
    /// Folder (inside the temporary directory) that holds finished exports until shared or saved.
    static let EXPORT_TEMP_DIRECTORY        = "DoubleClips-Export"
    /// Allowed ranges for the Export Settings fields (values outside are clamped).
    static let EXPORT_MIN_DIMENSION: Int    = 16
    static let EXPORT_MAX_DIMENSION: Int    = 8192
    static let EXPORT_MIN_FRAME_RATE: Int   = 1
    static let EXPORT_MAX_FRAME_RATE: Int   = 120
    static let EXPORT_MIN_BITRATE_MBPS: Int = 1
    static let EXPORT_MAX_BITRATE_MBPS: Int = 100
    static let EXPORT_AUDIO_BITRATE: Int    = 192_000
    static let EXPORT_AUDIO_SAMPLE_RATE: Double = 44_100
    /// Keyframe (IDR) interval in seconds.
    static let EXPORT_KEYFRAME_SECONDS: Int = 2
    /// Same cadence as Android's OpenGLEditNative: progress every 5 frames, a log line every 30.
    static let EXPORT_PROGRESS_FRAME_INTERVAL: Int = 5
    static let EXPORT_LOG_FRAME_INTERVAL: Int      = 30

    // MARK: - Project share (ZIP export)
    /// Folder (inside the temporary directory) that holds finished project ZIPs until shared.
    static let SHARE_TEMP_DIRECTORY         = "DoubleClips-Share"
    /// Leave `Clips/Temp` (the frame cache) out of the ZIP. Android's own export wipes it anyway.
    static let PROJECT_ZIP_EXCLUDE_TEMP     = true
    /// Already-compressed formats: stored as is, since deflating them gains nothing and costs time.
    static let PROJECT_ZIP_STORED_EXTENSIONS: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "3gp", "m4a", "mp3", "aac", "ogg", "opus", "flac",
        "jpg", "jpeg", "png", "heic", "gif", "webp", "zip"
    ]
    // MARK: - Track reorder
    /// How fast the other rows slide out of the way while a track is dragged.
    static let TRACK_REORDER_SLIDE_SECONDS: Double = 0.15

    // MARK: - Project files panel
    static let PROJECT_FILES_GRID_COLUMNS: Int  = 3
    /// "Solid colour image" size (Android makes 100x100; a 16:9 frame fills the canvas as is).
    static let SOLID_COLOR_IMAGE_WIDTH: CGFloat  = 1920
    static let SOLID_COLOR_IMAGE_HEIGHT: CGFloat = 1080

    // MARK: - Timeline clip blocks
    /// Text / effect block tints (Android: ColorFilter 0xAAFF0000 / 0xAAFFFF00 over the block).
    static let CLIP_TINT_ALPHA: Double          = 170.0 / 255.0
    /// Keyframe diamond on the selected clip (Android: 10 dp white square rotated 45 degrees).
    static let KEYFRAME_KNOT_SIZE: CGFloat      = 10
    /// Finger-sized tap area around a diamond.
    static let KEYFRAME_KNOT_HIT: CGFloat       = 30
    /// A diamond lights up when the playhead is within this many seconds of it.
    static let KEYFRAME_KNOT_ACTIVE_SECONDS: Float = 0.02
    /// Video blocks also show their own audio as a thin waveform band along the bottom edge.
    /// (iOS addition: Android shows only thumbnails on video. Set false to turn it off; the first
    /// time a project opens, each video's audio is decoded once in the background and cached.)
    static let VIDEO_WAVEFORM_ENABLED           = true
    static let VIDEO_WAVEFORM_BAND_HEIGHT: CGFloat = 20

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
