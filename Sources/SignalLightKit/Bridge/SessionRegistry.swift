import Foundation

/// The light's whole world view: one phase per live agent session.
///
/// Fed by `HookListener`, read whenever the light needs a bucket. Sessions
/// are keyed by source + session id, so Claude and Codex can never collide
/// on a UUID.
public actor SessionRegistry {
    public enum Phase: Sendable, Equatable {
        case idle
        case running
        case waitingForApproval
        case waitingForAnswer
    }

    public struct Session: Sendable, Equatable {
        public let source: HookEvent.Source
        public var phase: Phase
        public var updatedAt: Date
    }

    /// A `running` phase older than this counts as idle: an agent killed
    /// mid-turn never sends `Stop`, and a green light forever would lie.
    private static let runningLifetime: TimeInterval = 2 * 60 * 60
    /// Idle sessions are kept only so a late `SessionEnd` has something to
    /// land on; a day is plenty.
    private static let idleLifetime: TimeInterval = 24 * 60 * 60

    private var sessions: [String: Session] = [:]
    private let now: @Sendable () -> Date

    /// - Parameter now: injectable clock, so staleness can be tested without
    ///   sleeping.
    public init(now: @escaping @Sendable () -> Date = { .now }) {
        self.now = now
    }

    /// Applies one hook event and returns the bucket the light should show.
    @discardableResult
    public func apply(_ event: HookEvent, at timestamp: Date? = nil) -> SignalLightBucket {
        let timestamp = timestamp ?? now()
        guard event.version == HookEvent.currentVersion else {
            return bucket(at: timestamp)
        }

        let key = Self.key(for: event)
        switch event.kind {
        case .sessionEnd:
            sessions.removeValue(forKey: key)

        case .sessionStart:
            sessions[key] = Session(source: event.source, phase: .idle, updatedAt: timestamp)

        case .stop, .stopFailure, .interrupt:
            if var session = sessions[key] {
                session.phase = .idle
                session.updatedAt = timestamp
                sessions[key] = session
            }

        case .userPromptSubmit, .postToolUse:
            // Work is happening again — but a pending approval or question
            // stays on screen until the user answers it.
            update(key, source: event.source, at: timestamp) { session in
                if session.phase == .idle {
                    session.phase = .running
                }
            }

        case .permissionRequest:
            update(key, source: event.source, at: timestamp) { session in
                session.phase = event.isQuestion ? .waitingForAnswer : .waitingForApproval
            }
        }

        prune(at: timestamp)
        return bucket(at: timestamp)
    }

    public func bucket(at timestamp: Date? = nil) -> SignalLightBucket {
        let timestamp = timestamp ?? now()
        if sessions.values.contains(where: { isLive($0, at: timestamp) && $0.phase == .waitingForApproval }) {
            return .needsApproval
        }
        if sessions.values.contains(where: { isLive($0, at: timestamp) && $0.phase == .waitingForAnswer }) {
            return .needsAnswer
        }
        if sessions.values.contains(where: { isLive($0, at: timestamp) && $0.phase == .running }) {
            return .running
        }
        return .idle
    }

    public func snapshot() -> [String: Session] {
        sessions
    }

    private static func key(for event: HookEvent) -> String {
        "\(event.source.rawValue):\(event.sessionID)"
    }

    private func update(
        _ key: String,
        source: HookEvent.Source,
        at timestamp: Date,
        _ body: (inout Session) -> Void
    ) {
        var session = sessions[key] ?? Session(source: source, phase: .idle, updatedAt: timestamp)
        body(&session)
        session.updatedAt = timestamp
        sessions[key] = session
    }

    private func isLive(_ session: Session, at timestamp: Date) -> Bool {
        switch session.phase {
        case .waitingForApproval, .waitingForAnswer:
            // A prompt can legitimately sit unanswered for a long time.
            return true
        case .running:
            return timestamp.timeIntervalSince(session.updatedAt) < Self.runningLifetime
        case .idle:
            return false
        }
    }

    private func prune(at timestamp: Date) {
        let cutoff = timestamp.addingTimeInterval(-Self.idleLifetime)
        sessions = sessions.filter { $0.value.updatedAt >= cutoff }
    }
}
