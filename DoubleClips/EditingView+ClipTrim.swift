import SwiftUI

// MARK: - Dragging a clip's left / right handle
//
// The maths lives here (pure functions on a snapshot) so the handle gestures in `ClipBlockView` stay thin. A drag always
// starts from a snapshot taken when the finger lands and is applied as "snapshot + finger movement", so the result never
// depends on how often SwiftUI calls the gesture or on the block moving under the finger.
//
// Rules:
// - Timeline seconds and source seconds differ when the clip has a speed (a curve if it is keyframed): an edge moves by `speed x d`
//   source seconds, so a 2x clip is half as long on the timeline as its footage. Speed keyframes stay where they are on the timeline.
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
        
        /// `delta` = timeline seconds the finger moved to the right since the drag began. `map` is the clip's speed
        /// (timeline seconds -> source seconds): moving an edge by `d` timeline seconds moves it by `speed x d` source seconds.
        static func leftEdge(base: ClipTrimState, delta: Float, sourceLimited: Bool, map: EditingView.ClipTimeMap) -> ClipTrimState {
            var d = delta
            let floor = Swift.min(minimumDuration, base.duration)
            d = Swift.min(d, base.duration - floor)          // shrink: stay above the minimum length
            d = Swift.max(d, -base.startTime)                // extend: not before time 0
            let v0 = Float(map.speed(atLocal: 0))            // speed held before the clip's first frame
            if sourceLimited { d = Swift.max(d, -Swift.max(0, base.startTrim) / v0) }   // extend: not before the start of the file
            var out = base
            out.startTime = base.startTime + d
            out.duration = base.duration - d
            if sourceLimited {
                let moved = d >= 0 ? Float(map.sourceOffset(atLocal: Double(d))) : v0 * d
                out.startTrim = base.startTrim + moved
            }
            return out
        }
        
        static func rightEdge(base: ClipTrimState, delta: Float, sourceLimited: Bool, map: EditingView.ClipTimeMap) -> ClipTrimState {
            var d = delta
            let floor = Swift.min(minimumDuration, base.duration)
            d = Swift.max(d, floor - base.duration)          // shrink: stay above the minimum length
            let usedNow = map.sourceOffset(atLocal: Double(base.duration))
            if sourceLimited {
                // extend: the extra timeline seconds may use at most what is left of the file (`endTrim` source seconds)
                let latest = Float(map.localTime(forSourceOffset: usedNow + Double(Swift.max(0, base.endTrim))))
                d = Swift.min(d, latest - base.duration)
            }
            var out = base
            out.duration = base.duration + d
            if sourceLimited {
                let usedAfter = map.sourceOffset(atLocal: Double(out.duration))
                out.endTrim = Swift.max(0, base.endTrim - Float(usedAfter - usedNow))
            }
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
