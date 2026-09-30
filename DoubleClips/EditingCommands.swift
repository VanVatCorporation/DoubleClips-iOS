import Foundation
import Combine

// MARK: - Command Pattern (Undo/Redo)
//
// iOS equivalent of commands/base/CommandUtils.java + commands/CommandManager.java +
// the concrete commands/*.java classes (AddClipCommand, DeleteClipCommand,
// SplitClipCommand, AddTrackCommand, BatchCommand, ClipPropertyCommand).
//
// Every structural edit in EditingView (delete/split/clone/add-track) is wrapped in one
// of these instead of mutating the timeline directly, so it can be undone/redone through
// CommandManager — matching how EditingActivity routes all such edits through
// `executeCommand(...)` rather than touching `timeline` inline.

/// Equivalent of CommandUtils.Command
protocol EditCommand: AnyObject {
    func execute()
    func undo()
    /// Human-readable description — equivalent of each Java command's toString().
    var description: String { get }
}

/// Equivalent of CommandManager.java
final class CommandManager: ObservableObject {
    private let maxHistory = 100
    private var undoStack: [EditCommand] = []
    private var redoStack: [EditCommand] = []

    @Published private(set) var canUndo: Bool = false
    @Published private(set) var canRedo: Bool = false

    /// Execute a command and push it to the undo stack. Clears the redo stack,
    /// matching Android: new actions invalidate any previously-undone redo history.
    func execute(_ command: EditCommand) {
        command.execute()
        undoStack.append(command)
        redoStack.removeAll()
        if undoStack.count > maxHistory {
            undoStack.removeFirst() // prune oldest
        }
        updateState()
    }

    func undo() {
        guard let cmd = undoStack.popLast() else { return }
        cmd.undo()
        redoStack.append(cmd)
        updateState()
    }

    func redo() {
        guard let cmd = redoStack.popLast() else { return }
        cmd.execute()
        undoStack.append(cmd)
        updateState()
    }

    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }

    var undoCount: Int { undoStack.count }
    var redoCount: Int { redoStack.count }

    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}

/// Equivalent of CommandUtils.GenericCommand — wraps two closures as a command,
/// for one-off edits that don't warrant their own type.
final class GenericCommand: EditCommand {
    private let undoAction: () -> Void
    private let redoAction: () -> Void
    let description: String

    init(description: String = "Edit", undo undoAction: @escaping () -> Void, redo redoAction: @escaping () -> Void) {
        self.description = description
        self.undoAction = undoAction
        self.redoAction = redoAction
    }

    func execute() { redoAction() }
    func undo() { undoAction() }
}

/// Equivalent of AddClipCommand.java
final class AddClipCommand: EditCommand {
    let track: EditingView.Track
    let clip: EditingView.Clip
    private var wasAdded = false
    /// Called on undo if this clip was the active selection, so the caller can clear it
    /// — equivalent of Android's `activity.deselectingClip()` inside AddClipCommand.undo().
    var onDeselect: (() -> Void)?

    init(track: EditingView.Track, clip: EditingView.Clip, onDeselect: (() -> Void)? = nil) {
        self.track = track
        self.clip = clip
        self.onDeselect = onDeselect
    }

    var description: String { "Add Clip: \(clip.clipName)" }

    func execute() {
        guard !wasAdded else { return }
        track.addClip(clip)
        wasAdded = true
    }

    func undo() {
        guard wasAdded else { return }
        track.removeClip(clip)
        onDeselect?()
        wasAdded = false
    }
}

/// Equivalent of DeleteClipCommand.java
final class DeleteClipCommand: EditCommand {
    let timeline: EditingView.Timeline
    let track: EditingView.Track
    let clip: EditingView.Clip
    private let clipIndexInTrack: Int
    private var wasDeleted = false
    var onDeselect: (() -> Void)?

    init(timeline: EditingView.Timeline, clip: EditingView.Clip, onDeselect: (() -> Void)? = nil) {
        self.timeline = timeline
        self.clip = clip
        self.track = timeline.tracks[clip.trackIndex]
        self.clipIndexInTrack = track.clips.firstIndex(where: { $0.id == clip.id }) ?? track.clips.count
        self.onDeselect = onDeselect
    }

    var description: String { "Delete Clip: \(clip.clipName)" }

    func execute() {
        guard !wasDeleted else { return }
        onDeselect?()
        track.removeClip(clip)
        wasDeleted = true
    }

    func undo() {
        guard wasDeleted else { return }
        let insertAt = min(clipIndexInTrack, track.clips.count)
        track.clips.insert(clip, at: insertAt)
        wasDeleted = false
    }
}

/// Equivalent of SplitClipCommand.java. Delegates the actual math to
/// `Clip.splitClip(timeline:currentGlobalTime:)` in EditingView+Operations.swift, which
/// already implements Android's trim-adjustment-on-both-halves logic.
final class SplitClipCommand: EditCommand {
    let timeline: EditingView.Timeline
    let originalClip: EditingView.Clip
    let track: EditingView.Track
    let splitTime: Float

    private var secondaryClip: EditingView.Clip?
    private let originalEndClipTrim: Float
    private let originalDuration: Float
    private let originalEndTransition: EditingView.TransitionClip?
    private let originalEndTransitionEnabled: Bool
    private var wasSplit = false

    init(timeline: EditingView.Timeline, clip: EditingView.Clip, globalSplitTime: Float) {
        self.timeline = timeline
        self.originalClip = clip
        self.track = timeline.tracks[clip.trackIndex]
        self.splitTime = globalSplitTime
        self.originalEndClipTrim = clip.endClipTrim
        self.originalDuration = clip.duration
        self.originalEndTransition = clip.endTransition
        self.originalEndTransitionEnabled = clip.endTransitionEnabled
    }

    var description: String { "Split Clip: \(originalClip.clipName)" }

    func execute() {
        guard !wasSplit else { return }
        guard let newClip = originalClip.splitClip(timeline: timeline, currentGlobalTime: splitTime) else { return }
        secondaryClip = newClip
        wasSplit = true
    }

    func undo() {
        guard wasSplit, let secondaryClip else { return }
        track.removeClip(secondaryClip)
        originalClip.endClipTrim = originalEndClipTrim
        originalClip.duration = originalDuration
        originalClip.endTransition = originalEndTransition
        originalClip.endTransitionEnabled = originalEndTransitionEnabled
        wasSplit = false
        self.secondaryClip = nil
    }
}

/// Equivalent of AddTrackCommand.java
final class AddTrackCommand: EditCommand {
    let timeline: EditingView.Timeline
    let track: EditingView.Track
    private var wasAdded = false

    init(timeline: EditingView.Timeline, track: EditingView.Track) {
        self.timeline = timeline
        self.track = track
    }

    var description: String { "Add Track \(track.timelineIndex)" }

    func execute() {
        guard !wasAdded else { return }
        timeline.addTrack(track)
        wasAdded = true
    }

    func undo() {
        guard wasAdded else { return }
        timeline.removeTrack(track)
        wasAdded = false
    }
}

/// Equivalent of BatchCommand.java — groups several commands so multi-select
/// delete/clone undoes and redoes as one user-visible action.
final class BatchCommand: EditCommand {
    private var commands: [EditCommand] = []
    let batchDescription: String

    init(_ description: String) {
        self.batchDescription = description
    }

    func add(_ command: EditCommand) {
        commands.append(command)
    }

    var isEmpty: Bool { commands.isEmpty }
    var commandCount: Int { commands.count }

    var description: String { "\(batchDescription) (\(commands.count) operations)" }

    func execute() {
        for cmd in commands { cmd.execute() }
    }

    func undo() {
        for cmd in commands.reversed() { cmd.undo() }
    }
}

/// Equivalent of ClipPropertyCommand.java — generic single-property change with a
/// caller-supplied setter, for wiring up property editors (sliders, pickers, etc.)
/// to undo/redo without a bespoke command type each time.
final class ClipPropertyCommand<T>: EditCommand {
    let clip: EditingView.Clip
    let propertyName: String
    let oldValue: T
    let newValue: T
    let setter: (EditingView.Clip, T) -> Void

    init(clip: EditingView.Clip, propertyName: String, oldValue: T, newValue: T, setter: @escaping (EditingView.Clip, T) -> Void) {
        self.clip = clip
        self.propertyName = propertyName
        self.oldValue = oldValue
        self.newValue = newValue
        self.setter = setter
    }

    var description: String { "Change \(propertyName): \(clip.clipName)" }

    func execute() { setter(clip, newValue) }
    func undo() { setter(clip, oldValue) }
}
