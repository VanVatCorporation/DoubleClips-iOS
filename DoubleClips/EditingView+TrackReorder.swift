import SwiftUI

// MARK: - Track reorder (drag a grip)
//
// Android and desktop have no way to change a track's position once it exists. Here the "reorder"
// toggle in the corner of the ruler row shows a grip on every track label; dragging a grip moves
// that track. Track order IS the layer order (later tracks draw on top, see CompositionBuilder),
// so this also decides which clips cover which.
//
// The drag itself only changes how things are DRAWN (offsets). The tracks array is untouched until
// the finger lifts, then the move is applied once, as one undoable command. That keeps the row
// under the finger stable while the other rows slide out of the way.

struct TrackReorderDrag: Equatable {
    let trackID: UUID
    let startIndex: Int
    /// Finger travel since the grip was grabbed (points, + = down).
    var translation: CGFloat
    
    private var rowHeight: CGFloat { Constants.TRACK_HEIGHT }
    
    /// Where the track would land if released now.
    func targetIndex(count: Int) -> Int {
        guard count > 0 else { return 0 }
        let steps = Int((translation / rowHeight).rounded())
        return min(max(startIndex + steps, 0), count - 1)
    }
    
    /// Vertical offset to draw the row at `index` with: the dragged row follows the finger (kept
    /// inside the list), the rows it passes over move one row out of its way.
    func offset(forRowAt index: Int, count: Int) -> CGFloat {
        if index == startIndex {
            let lowest = -CGFloat(startIndex) * rowHeight
            let highest = CGFloat(count - 1 - startIndex) * rowHeight
            return min(max(translation, lowest), highest)
        }
        let target = targetIndex(count: count)
        if startIndex < target, index > startIndex, index <= target { return -rowHeight }
        if startIndex > target, index >= target, index < startIndex { return rowHeight }
        return 0
    }
}
