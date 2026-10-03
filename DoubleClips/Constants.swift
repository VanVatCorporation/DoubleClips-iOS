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
    /// x264-style CRF -> bits-per-pixel-per-frame: bpp = EXPORT_BPP_AT_CRF23 * 2^((23 - crf) / 6).
    /// The hardware H.264 encoder is a bit less efficient than x264, hence the generous base.
    static let EXPORT_BPP_AT_CRF23: Double  = 0.15
    static let EXPORT_MIN_VIDEO_BITRATE: Int = 1_000_000
    static let EXPORT_MAX_VIDEO_BITRATE: Int = 100_000_000
    /// "High" / "Maximum" quality = the project's CRF minus this many steps (lower CRF = better).
    static let EXPORT_CRF_STEP_HIGH: Int    = 6
    static let EXPORT_CRF_STEP_MAX: Int     = 12
    static let EXPORT_AUDIO_BITRATE: Int    = 192_000
    static let EXPORT_AUDIO_SAMPLE_RATE: Double = 44_100
    /// Keyframe (IDR) interval in seconds.
    static let EXPORT_KEYFRAME_SECONDS: Int = 2

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
