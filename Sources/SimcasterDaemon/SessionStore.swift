import Foundation
import SimcasterCore

/// Thread-safe in-memory store for active sessions.
///
/// Uses NSLock for synchronization — all mutable state is accessed
/// exclusively through lock-protected methods.
final class SessionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _sessions: [String: Session] = [:]

    var sessions: [Session] {
        lock.lock()
        defer { lock.unlock() }
        return Array(_sessions.values).sorted { $0.createdAt < $1.createdAt }
    }

    func add(_ session: Session) {
        lock.lock()
        defer { lock.unlock() }
        _sessions[session.id] = session
    }

    func get(_ id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return _sessions[id]
    }

    func update(_ id: String, _ transform: (inout Session) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if var session = _sessions[id] {
            transform(&session)
            _sessions[id] = session
        }
    }

    func remove(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        _sessions.removeValue(forKey: id)
    }
}
