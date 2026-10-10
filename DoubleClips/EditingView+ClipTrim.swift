import SwiftUI

// MARK: - Dragging a clip's left / right handle
//
// The maths lives here (pure functions on a snapshot) so the handle gestures in `ClipBlockView` stay thin. A drag always
// starts from a snapshot taken when the finger lands and is applied as "snapshot + finger movement", so the result never
// depends on how often SwiftUI calls the gesture or on the block moving under the finger.
//
// Rules:
// - Video and audio are limited by their source media: the left edge can't be pulled past the start of the file
//   (`startClipTrim` can't go below 0) and the right edge can't be pulled past its end (`endClipTrim` can't go below 0).
//   Shrinking raises the trim, extending gives it back, so the media is never re-cut or stretched.
// - Images, text, effects and other clips without source length can be made any length; their trims are left alone.
// - A clip can't start before time 0 and can't be shorter than `minimumDuration` (or than it already was, if shorter).
// - Neighbouring clips are not a limit: the timeline allows overlaps (a clip move doesn't prevent them either).

extension EditingView {
    /// Everything a handle drag can change on a clip (also what an undo step stores).
    struct ClipTrimState: Equatable {
        var startTime: Float
        var duration: Float
        var startTrim: Float
        var endTrim: Float
    }
    
    enum ClipTrimMath {
        /// Shortest a handle drag can make a clip, in seconds.
        static let minimumDuration: Float = 0.1
        
        /// `delta` = seconds the finger moved to the right since the drag began.
        static func leftEdge(base: ClipTrimState, delta: Float, sourceLimited: Bool) -> ClipTrimState {
            var d = delta
            let floor = Swift.min(minimumDuration, base.duration)
            d = Swift.min(d, base.duration - floor)          // shrink: stay above the minimum length
            d = Swift.max(d, -base.startTime)                // extend: not before time 0
            if sourceLimited { d = Swift.max(d, -Swift.max(0, base.startTrim)) }   // extend: not before the start of the file
            var out = base
            out.startTime = base.startTime + d
            out.duration = base.duration - d
            if sourceLimited { out.startTrim = base.startTrim + d }
            return out
        }
        
        static func rightEdge(base: ClipTrimState, delta: Float, sourceLimited: Bool) -> ClipTrimState {
            var d = delta
            let floor = Swift.min(minimumDuration, base.duration)
            d = Swift.max(d, floor - base.duration)          // shrink: stay above the minimum length
            if sourceLimited { d = Swift.min(d, Swift.max(0, base.endTrim)) }      // extend: not past the end of the file
            var out = base
            out.duration = base.duration + d
            if sourceLimited { out.endTrim = base.endTrim - d }
            return out
        }
    }
}

extension EditingView.Clip {
    var trimState: EditingView.ClipTrimState {
        EditingView.ClipTrimState(startTime: startTime, duration: duration, startTrim: startClipTrim, endTrim: endClipTrim)
    }
    
    func apply(trim s: EditingView.ClipTrimState) {
        startTime = s.startTime
        duration = s.duration
        startClipTrim = s.startTrim
        endClipTrim = s.endTrim
    }
    
    /// Video / audio with a known source length: their edges stop at the ends of the file.
    var isSourceLimited: Bool {
        (type == .video || type == .audio) && originalDuration > 0
    }
}
