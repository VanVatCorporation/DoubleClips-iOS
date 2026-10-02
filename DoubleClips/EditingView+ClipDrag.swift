import SwiftUI
import UIKit

// MARK: - Clip drag (Android: EditingActivity.handleClipInteraction)
//
//   tap         -> select the clip
//   long press  -> a half-transparent GHOST of the clip appears under the finger, the original is
//                  hidden, timeline scrolling is locked (requestDisallowInterceptTouchEvent)
//   move        -> the ghost follows horizontally (snapping to the playhead and to the clips of the
//                  neighbouring tracks) and hops to whichever track is under the finger
//   release     -> the clip is committed at the frame-snapped start time on the new track
//
// Until release only the ghost moves; the real clip is never touched mid-gesture, so a cancelled
// drag leaves no trace. (Previously a plain 8 pt drag on any clip moved it immediately — so a
// scrub that merely started on a clip dragged it away instead of scrolling the timeline.)

enum ClipLongPressPhase {
    case began, moved, ended, cancelled
}

/// Target/delegate of the long-press recogniser on the timeline scroll view.
final class ClipLongPressHandler: NSObject, UIGestureRecognizerDelegate {
    /// Content-coordinate callback. For `.began` the return value decides whether the gesture may
    /// begin (false = no clip here); for the other phases it is ignored.
    var onLongPress: ((ClipLongPressPhase, CGPoint) -> Bool)?
    private var isActive = false
    
    /// Asked right before the long press would fire: only let it begin over a draggable clip.
    /// Failing here (instead of cancelling afterwards) leaves the touch fully intact, so a long
    /// hold on empty space is still a normal tap / scroll.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scrollView = gestureRecognizer.view as? UIScrollView else { return false }
        isActive = onLongPress?(.began, gestureRecognizer.location(in: scrollView)) ?? false
        return isActive
    }
    
    @objc func handle(_ gesture: UILongPressGestureRecognizer) {
        guard isActive, let scrollView = gesture.view as? UIScrollView else { return }
        let point = gesture.location(in: scrollView)
        switch gesture.state {
        case .began:
            scrollView.isScrollEnabled = false          // requestDisallowInterceptTouchEvent(true)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .changed:
            _ = onLongPress?(.moved, point)
        case .ended:
            _ = onLongPress?(.ended, point)
            scrollView.isScrollEnabled = true
            isActive = false
        case .cancelled, .failed:
            _ = onLongPress?(.cancelled, point)
            scrollView.isScrollEnabled = true
            isActive = false
        default:
            break
        }
    }
}

extension EditingView {
    
    /// State of one ghost drag. Positions are stored as time + track, not pixels, so zooming
    /// mid-drag can't desynchronise the ghost.
    struct ClipGhost {
        let clip: Clip
        /// Finger x minus the clip's left edge (content coordinates): keeps the clip under the
        /// finger where it was grabbed instead of jumping its left edge to the touch point.
        let grabOffsetX: CGFloat
        let initialStartTime: Float
        let initialTrackIndex: Int
        var startTime: Float
        var trackIndex: Int
    }
    
    enum ClipGhostMath {
        static let rowHeight: CGFloat = 100
        /// Clip blocks sit 6 pt below the row's top and are 88 pt tall (see TrackRowView).
        static let blockInset: CGFloat = 6
        static let blockHeight: CGFloat = 88
        
        /// `point` is in the timeline scroll view's content coordinates:
        /// x = centerOffset + time * pps, y = trackIndex * rowHeight (+ inset).
        static func hitTest(point: CGPoint, timeline: Timeline, centerOffset: CGFloat, pps: CGFloat) -> ClipGhost? {
            let row = Int(floor(point.y / rowHeight))
            guard timeline.tracks.indices.contains(row) else { return nil }
            let local = point.y - CGFloat(row) * rowHeight
            guard local >= blockInset, local <= blockInset + blockHeight else { return nil }
            
            for clip in timeline.tracks[row].clips.reversed() {   // later = drawn on top
                let left = centerOffset + CGFloat(clip.startTime) * pps
                let width = max(20, CGFloat(clip.duration) * pps)  // same minimum as ClipBlockView
                if point.x >= left, point.x <= left + width {
                    return ClipGhost(clip: clip, grabOffsetX: point.x - left,
                                     initialStartTime: clip.startTime, initialTrackIndex: row,
                                     startTime: clip.startTime, trackIndex: row)
                }
            }
            return nil
        }
        
        static func moved(_ ghost: ClipGhost, to point: CGPoint, timeline: Timeline,
                          centerOffset: CGFloat, pps: CGFloat, currentTime: Float) -> ClipGhost {
            var next = ghost
            // Track under the finger; staying on the first/last row when the finger leaves the area.
            let row = Int(floor(point.y / rowHeight))
            next.trackIndex = min(max(row, 0), max(timeline.tracks.count - 1, 0))
            
            let proposed = Float((point.x - ghost.grabOffsetX - centerOffset) / max(pps, 1))
            // Android's ACTION_MOVE snapping: clamp at 0 s, playhead, neighbouring tracks (+-1).
            next.startTime = timeline.snappedStartTime(
                for: ghost.clip, proposedStartTime: proposed, candidateTrackIndex: next.trackIndex,
                currentTime: currentTime, pixelsPerSecond: pps)
            return next
        }
        
        /// Android's ACTION_UP: snap to the nearest frame, move the clip, re-sort, recompute duration.
        /// Returns true when something actually changed.
        static func commit(_ ghost: ClipGhost, timeline: Timeline, commandManager: CommandManager,
                           frameRate: Int) -> Bool {
            let fps = Float(max(frameRate, 1))
            let snapped = max(0, (ghost.startTime * fps).rounded() / fps)
            guard snapped != ghost.initialStartTime || ghost.trackIndex != ghost.initialTrackIndex else { return false }
            commandManager.execute(MoveClipCommand(
                timeline: timeline, clip: ghost.clip,
                fromStart: ghost.initialStartTime, fromTrack: ghost.initialTrackIndex,
                toStart: snapped, toTrack: ghost.trackIndex))
            return true
        }
    }
    
    /// The half-transparent copy that follows the finger (Android: ghost.setAlpha(0.5f)).
    struct ClipGhostView: View {
        let ghost: ClipGhost
        let pps: CGFloat
        var media: ClipMediaContext = .empty
        
        var body: some View {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.mdPrimary.opacity(0.55))
                // Same thumbnails / waveform as the real block (Android copies its bitmap into the ghost).
                ClipVisualContent(clip: ghost.clip, displayStartTime: ghost.startTime, pps: pps,
                                  blockWidth: max(20, CGFloat(ghost.clip.duration) * pps),
                                  height: ClipGhostMath.blockHeight, media: media)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .opacity(0.7)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                Text(ghost.clip.clipName)
                    .font(.system(size: 10))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 16)
            }
            .frame(width: max(20, CGFloat(ghost.clip.duration) * pps), height: ClipGhostMath.blockHeight)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 3)
            // Origin = time 0 of the track area: same convention as TrackRowView's `.offset(x:)`.
            .offset(x: CGFloat(ghost.startTime) * pps,
                    y: CGFloat(ghost.trackIndex) * ClipGhostMath.rowHeight + ClipGhostMath.blockInset)
            .allowsHitTesting(false)
        }
    }
}
