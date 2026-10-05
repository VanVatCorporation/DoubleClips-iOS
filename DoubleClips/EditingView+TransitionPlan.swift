import Foundation

// MARK: - Transition plan (timing only, no AVFoundation)
//
// A transition belongs to the END of a clip ("A") and joins it to the next clip on the same track
// ("B"): Android's Clip.endTransition / endTransitionEnabled. This file decides WHEN the blend
// happens and how far each clip has to be shown beyond its own range, from the same numbers
// Android's exporters use:
//
//   FXCommandEmitter (FFmpeg xfade offset, relative to the start of A, T = end of A, d = duration)
//     END_FIRST     A - 2d   -> blend over [T - 2d, T - d)   done before the cut
//     OVERLAP       A -  d   -> blend over [T -  d, T)       finishes at the cut
//     BEGIN_SECOND  A        -> blend over [T, T + d)        starts at the cut
//   OpenGLEdit.findActiveTransition (Android's GPU export) implements the OVERLAP row exactly:
//   window [T - d, T), progress = (t - start) / d, A drawn as usual, B drawn BEFORE its own start.
//
// While the blend runs, both clips draw at the SAME timeline position (not shifted):
//   - B shows the footage that lies before its trim-in point (or its first frame, held, when the
//     clip isn't trimmed there) -> "pre-roll", `preRoll[B]`
//   - A keeps going past its nominal end when the window reaches beyond it (BEGIN_SECOND), with the
//     footage after its trim-out, or its last frame held -> "post-roll", `postRoll[A]`
// and after the blend the new clip simply takes over: A is visible only until the window's end, B
// from the window's start (END_FIRST finishes before B's nominal start, so B is already showing).
//
// Same rules as the Android knot: the two clips must touch (within the snap threshold) and be the
// neighbours in start-time order. Only pictures transition (video / image on both sides), as in
// Android's GPU export; text, effect and audio clips are skipped.

struct TransitionPlan {
    
    struct Window {
        let aID: UUID
        let bID: UUID
        let style: String           // normalized: trimmed, lower case
        let start: Float
        let end: Float
        var duration: Float { end - start }
    }
    
    var windows: [Window] = []
    /// Seconds a clip must be shown BEFORE its nominal start (it is the B of a transition).
    var preRoll: [UUID: Float] = [:]
    /// Seconds a clip must be shown AFTER its nominal end (it is the A of a transition).
    var postRoll: [UUID: Float] = [:]
    /// Where a clip's picture starts / stops, when that differs from its nominal range.
    var visibleStart: [UUID: Float] = [:]
    var visibleEnd: [UUID: Float] = [:]
    
    // MARK: Helpers shared with the knot UI
    
    static func normalizedStyle(_ style: String?) -> String {
        (style ?? "none").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    static func isPicture(_ clip: EditingView.Clip) -> Bool {
        clip.type == .video || clip.type == .image
    }
    
    /// Neighbouring clips that touch: the places where Android shows a transition knot.
    static func adjacentPairs(in clips: [EditingView.Clip]) -> [(a: EditingView.Clip, b: EditingView.Clip)] {
        let sorted = clips.sorted { $0.startTime < $1.startTime }
        guard sorted.count > 1 else { return [] }
        var pairs: [(a: EditingView.Clip, b: EditingView.Clip)] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            guard a.duration > 0, b.duration > 0 else { continue }
            if abs(b.startTime - (a.startTime + a.duration)) <= Constants.TRACK_CLIPS_SNAP_THRESHOLD_SECONDS {
                pairs.append((a, b))
            }
        }
        return pairs
    }
    
    /// Longest blend that fits: OVERLAP needs A to last that long, END_FIRST twice that (it ends
    /// one duration before the cut), BEGIN_SECOND needs B to last that long.
    static func maxDuration(mode: EditingView.TransitionClip.TransitionMode, a: EditingView.Clip, b: EditingView.Clip) -> Float {
        switch mode {
        case .overlap: return a.duration
        case .endFirst: return a.duration / 2
        case .beginSecond: return b.duration
        }
    }
    
    /// The window's start and end for a transition of `duration` at the cut `cut`.
    static func windowRange(mode: EditingView.TransitionClip.TransitionMode, cut: Float, duration: Float) -> (start: Float, end: Float) {
        switch mode {
        case .endFirst: return (cut - 2 * duration, cut - duration)
        case .overlap: return (cut - duration, cut)
        case .beginSecond: return (cut, cut + duration)
        }
    }
    
    // MARK: Building
    
    static func make(clips: [EditingView.Clip]) -> TransitionPlan {
        var plan = TransitionPlan()
        for (a, b) in adjacentPairs(in: clips) {
            guard a.endTransitionEnabled, let transition = a.endTransition else { continue }
            let style = normalizedStyle(transition.effect.style)
            guard style != "none", !style.isEmpty, isPicture(a), isPicture(b) else { continue }
            
            let limit = maxDuration(mode: transition.mode, a: a, b: b)
            let duration = min(max(transition.duration, 0), limit)
            guard duration >= Constants.TRANSITION_MIN_SECONDS else { continue }
            
            let cut = a.startTime + a.duration
            let range = windowRange(mode: transition.mode, cut: cut, duration: duration)
            
            plan.windows.append(Window(aID: a.id, bID: b.id, style: style, start: range.start, end: range.end))
            plan.preRoll[b.id] = max(plan.preRoll[b.id] ?? 0, max(0, b.startTime - range.start))
            plan.postRoll[a.id] = max(plan.postRoll[a.id] ?? 0, max(0, range.end - cut))
            plan.visibleStart[b.id] = range.start
            plan.visibleEnd[a.id] = range.end
        }
        return plan
    }
}
