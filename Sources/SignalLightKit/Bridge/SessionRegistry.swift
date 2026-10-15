import Foundation

/// The light's whole world view: one phase per live agent session.
///
/// Fed by `HookListener`, read whenever the light needs a bucket. Sessions
/// are keyed by source + session id, so Claude and Codex can never collide
/// on a UUID.
public actor SessionRegistry {
    public enum Phase: String, Codable, Sendable, Equatable {
        case idle
        case running
        case waitingForApproval
        case waitingForAnswer
    }

    public struct SessionStatus: Codable, Sendable, Equatable {
        public let source: HookEvent.Source
        public let sessionID: String
        public let phase: Phase
        public let lastEventAt: Date?

        public init(
            source: HookEvent.Source,
            sessionID: String,
            phase: Phase,
            lastEventAt: Date? = nil
        ) {
            self.source = source
            self.sessionID = sessionID
            self.phase = phase
            self.lastEventAt = lastEventAt
        }
    }

    public struct Summary: Sendable, Equatable {
        public let bucket: SignalLightBucket
        public let sessions: [SessionStatus]
    }

    public struct Session: Sendable, Equatable {
        public let source: HookEvent.Source
        public let sessionID: String
        public var phase: Phase
        public var updatedAt: Date
    }

    /// A `running` phase older than this counts as idle: an agent killed
    /// mid-turn never sends `Stop`, and a green light forever would lie.
    private static let runningLifetime: TimeInterval = 2 * 60 * 60
    /// Attention can wait longer than active work, but must not survive a
    /// lost SessionEnd forever.
    private static let attentionLifetime: TimeInterval = 24 * 60 * 60
    /// Idle sessions are kept long enough for a late `SessionEnd` to land.
    private static let idleLifetime: TimeInterval = 24 * 60 * 60

    private var sessions: [String: Session] = [:]
    private let now: @Sendable () -> Date

    /// - Parameter now: injectable clock, so staleness can be tested without
    ///   sleeping.
    public init(
        restoring statuses: [SessionStatus] = [],
        fallbackLastEventAt: Date? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        let restorationTime = now()
        let cutoff = restorationTime.addingTimeInterval(-Self.idleLifetime)
        sessions = Dictionary(statuses.compactMap { status in
            let updatedAt = status.lastEventAt ?? fallbackLastEventAt ?? .distantPast
            guard !status.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  updatedAt >= cutoff,
                  updatedAt <= restorationTime else {
                return nil
            }
            let phase = Self.restoredPhase(for: status)
            let session = Session(
                source: status.source,
                sessionID: status.sessionID,
                phase: phase,
                updatedAt: updatedAt
            )
            return (Self.key(for: status.source, sessionID: status.sessionID), session)
        }, uniquingKeysWith: { _, latest in latest })
        self.now = now
    }

    /// Applies one hook event and returns the bucket the light should show.
    @discardableResult
    public func apply(
        _ event: HookEvent,
        at timestamp: Date? = nil,
        onStateChange: (@Sendable (Summary) -> Void)? = nil
    ) -> SignalLightBucket {
        let timestamp = timestamp ?? now()
        guard event.version == HookEvent.currentVersion else {
            let summary = summary(at: timestamp)
            onStateChange?(summary)
            return summary.bucket
        }

        let key = Self.key(for: event)
        switch event.kind {
        case .sessionEnd:
            sessions.removeValue(forKey: key)

        case .sessionStart:
            sessions[key] = Session(
                source: event.source,
                sessionID: event.sessionID,
                phase: .idle,
                updatedAt: timestamp
            )

        case .stop, .stopFailure, .interrupt:
            if var session = sessions[key] {
                session.phase = .idle
                session.updatedAt = timestamp
                sessions[key] = session
            }

        case .userPromptSubmit, .postToolUse:
            update(key, source: event.source, sessionID: event.sessionID, at: timestamp) { session in
                session.phase = .running
            }

        case .permissionRequest:
            update(key, source: event.source, sessionID: event.sessionID, at: timestamp) { session in
                session.phase = event.isQuestion ? .waitingForAnswer : .waitingForApproval
            }
        }

        prune(at: timestamp)
        let summary = summary(at: timestamp)
        onStateChange?(summary)
        return summary.bucket
    }

    /// Recomputes expiring session states and publishes the current bucket.
    public func refresh(onStateChange: @Sendable (Summary) -> Void) {
        let timestamp = now()
        prune(at: timestamp)
        onStateChange(summary(at: timestamp))
    }

    public func bucket(at timestamp: Date? = nil) -> SignalLightBucket {
        summary(at: timestamp).bucket
    }

    public func summary(at timestamp: Date? = nil) -> Summary {
        let timestamp = timestamp ?? now()
        let statuses = sessions.values.map { session in
            SessionStatus(
                source: session.source,
                sessionID: session.sessionID,
                phase: isLive(session, at: timestamp) ? session.phase : .idle,
                lastEventAt: session.updatedAt
            )
        }.sorted {
            if $0.source != $1.source { return $0.source.rawValue < $1.source.rawValue }
            return $0.sessionID < $1.sessionID
        }
        let bucket: SignalLightBucket
        if statuses.contains(where: { $0.phase == .waitingForApproval }) {
            bucket = .needsApproval
        } else if statuses.contains(where: { $0.phase == .waitingForAnswer }) {
            bucket = .needsAnswer
        } else if statuses.contains(where: { $0.phase == .running }) {
            bucket = .running
        } else {
            bucket = .idle
        }
        return Summary(bucket: bucket, sessions: statuses)
    }

    public func snapshot() -> [String: Session] {
        sessions
    }

    private static func key(for event: HookEvent) -> String {
        key(for: event.source, sessionID: event.sessionID)
    }

    private static func key(for source: HookEvent.Source, sessionID: String) -> String {
        "\(source.rawValue):\(sessionID)"
    }

    private static func restoredPhase(for status: SessionStatus) -> Phase {
        // Older snapshots cannot prove a Codex approval is still pending.
        if status.lastEventAt == nil, status.source == .codex, status.phase == .waitingForApproval {
            return .idle
        }
        return status.phase
    }

    private func update(
        _ key: String,
        source: HookEvent.Source,
        sessionID: String,
        at timestamp: Date,
        _ body: (inout Session) -> Void
    ) {
        var session = sessions[key] ?? Session(source: source, sessionID: sessionID, phase: .idle, updatedAt: timestamp)
        body(&session)
        session.updatedAt = timestamp
        sessions[key] = session
    }

    private func isLive(_ session: Session, at timestamp: Date) -> Bool {
        switch session.phase {
        case .waitingForApproval, .waitingForAnswer:
            return timestamp.timeIntervalSince(session.updatedAt) < Self.attentionLifetime
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
