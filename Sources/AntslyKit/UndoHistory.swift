// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Undo and redo over whole-state snapshots. Changes with the same key within `window` seconds share one step,
/// so typing undoes by phrase instead of by letter, while adding or removing something always starts a new step.
public struct UndoHistory<State> {
    private var undos: [State] = []
    private var redos: [State] = []
    private var lastKey = ""
    private var lastAt = Date.distantPast
    public let limit: Int
    public let window: TimeInterval

    public init(limit: Int = 200, window: TimeInterval = 1.0) { self.limit = limit; self.window = window }

    public var canUndo: Bool { !undos.isEmpty }
    public var canRedo: Bool { !redos.isEmpty }

    /// Call with the state as it is before a local change.
    public mutating func record(key: String, state: @autoclosure () -> State, now: Date = Date()) {
        if key == lastKey, now.timeIntervalSince(lastAt) < window { lastAt = now; return }
        lastKey = key; lastAt = now
        undos.append(state())
        if undos.count > limit { undos.removeFirst() }
        redos.removeAll()
    }

    /// Returns the state to restore, given the current one (kept for redo).
    public mutating func undo(current: State) -> State? {
        guard let s = undos.popLast() else { return nil }
        redos.append(current); lastKey = ""; return s
    }
    public mutating func redo(current: State) -> State? {
        guard let s = redos.popLast() else { return nil }
        undos.append(current); lastKey = ""; return s
    }
}
