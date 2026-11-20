// SPDX-License-Identifier: Apache-2.0
import Foundation

public struct PlaybackQueue: Codable, Sendable {
    public struct Entry: Codable, Identifiable, Sendable {
        public var id = UUID()
        public let track: Track
    }

    public enum RepeatMode: String, Codable, CaseIterable, Sendable {
        case off, all, one
    }

    public private(set) var entries: [Entry] = []
    public private(set) var index: Int?
    public private(set) var shuffled = false
    private var originalOrder: [UUID] = []
    public var repeatMode: RepeatMode = .off

    public init() {}

    public var current: Entry? {
        guard let index, entries.indices.contains(index) else { return nil }
        return entries[index]
    }

    public mutating func replace(_ tracks: [Track], start: Int = 0, shuffle: Bool = false) {
        entries = tracks.map { Entry(track: $0) }
        index = entries.indices.contains(start) ? start : entries.indices.first
        originalOrder = entries.map(\.id)
        shuffled = shuffle && index != nil
        if shuffled, let index {
            let first = entries.remove(at: index)
            entries.shuffle()
            entries.insert(first, at: 0)
            self.index = 0
        }
    }

    public mutating func add(_ track: Track, next: Bool = false) {
        let entry = Entry(track: track)
        let insertion = next ? (index.map { $0 + 1 } ?? 0) : entries.count
        let originalInsertion = next ? current.flatMap { originalOrder.firstIndex(of: $0.id) }.map { $0 + 1 } : nil
        entries.insert(entry, at: insertion)
        originalOrder.insert(entry.id, at: originalInsertion ?? originalOrder.count)
        if index == nil { index = insertion }
    }

    public mutating func select(_ id: Entry.ID) -> Bool {
        guard let selected = entries.firstIndex(where: { $0.id == id }) else { return false }
        index = selected
        return true
    }

    @discardableResult public mutating func remove(_ id: Entry.ID) -> Bool {
        guard let removed = entries.firstIndex(where: { $0.id == id }) else { return false }
        let removedCurrent = current?.id == id
        entries.remove(at: removed)
        originalOrder.removeAll { $0 == id }
        if let index {
            self.index = entries.isEmpty ? nil : min(removed < index ? index - 1 : index, entries.count - 1)
        }
        return removedCurrent
    }

    public mutating func move(_ id: Entry.ID, by delta: Int) {
        guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
        let destination = from + delta
        guard entries.indices.contains(destination) else { return }
        let currentID = current?.id
        let moved = entries.remove(at: from)
        entries.insert(moved, at: destination)
        if !shuffled { originalOrder = entries.map(\.id) }
        if let currentID { _ = select(currentID) }
    }

    public mutating func toggleShuffle() {
        let currentID = current?.id
        if shuffled {
            let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            entries = originalOrder.compactMap { byID[$0] }
        } else if let index {
            let next = entries.index(after: index)
            entries.replaceSubrange(next..., with: entries[next...].shuffled())
        }
        shuffled.toggle()
        if let currentID { _ = select(currentID) }
    }

    @discardableResult public mutating func advance(automatically: Bool) -> Bool {
        guard let index else { return false }
        if automatically && repeatMode == .one { return true }
        if entries.indices.contains(index + 1) {
            self.index = index + 1
            return true
        }
        guard repeatMode == .all else { return false }
        self.index = entries.indices.first
        return true
    }

    @discardableResult public mutating func previous() -> Bool {
        guard let index else { return false }
        if index > 0 {
            self.index = index - 1
            return true
        }
        if repeatMode == .all && entries.count > 1 {
            self.index = entries.indices.last
            return true
        }
        return false
    }
}

public struct PlaybackSnapshot: Codable, Sendable {
    public var queue = PlaybackQueue()
    public var position: Double = 0
    public var speed: Float = 1
    public var entryListeningSeconds: Double = 0
    public var entryCounted = false
    
    public init() {}
}
