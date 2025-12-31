import Foundation

/// Manages all active sessions
actor SessionManager {
    private var sessions: [String: TMuxSession] = [:]
    private var sessionObservers: [String: [(OutputChunk) -> Void]] = [:]
    private var stateObservers: [String: [(SessionState) -> Void]] = [:]

    /// Create a new session (runs in tmux + opens Terminal.app)
    func createSession(command: String, arguments: [String]) throws -> TMuxSession {
        let id = generateSessionID()
        let session = try TMuxSession(id: id, command: command, arguments: arguments)

        // Set up callbacks that broadcast to observers
        session.onOutputChunk = { [weak self] chunk in
            Task { [weak self] in
                await self?.notifyOutputObservers(sessionID: id, chunk: chunk)
            }
        }

        session.onStateChange = { [weak self] state in
            Task { [weak self] in
                await self?.notifyStateObservers(sessionID: id, state: state)
            }
        }

        sessions[id] = session
        return session
    }

    /// Get a session by ID
    func getSession(_ id: String) -> TMuxSession? {
        return sessions[id]
    }

    /// Get all sessions as summaries
    func getAllSessions() -> [SessionSummary] {
        var summaries: [SessionSummary] = []

        for session in sessions.values {
            summaries.append(SessionSummary(from: session))
        }

        // Sort by creation date (newest first)
        return summaries.sorted { $0.createdAt > $1.createdAt }
    }

    /// Remove a session
    func removeSession(_ id: String) {
        sessions[id]?.terminate()
        sessions.removeValue(forKey: id)
        sessionObservers.removeValue(forKey: id)
        stateObservers.removeValue(forKey: id)
    }

    /// Send input to a session
    func sendInput(_ id: String, input: String) {
        sessions[id]?.sendInput(input)
    }

    /// Get history for a session
    func getHistory(_ id: String, limit: Int? = nil, offset: Int = 0) -> [OutputChunk] {
        return sessions[id]?.getHistory(limit: limit, offset: offset) ?? []
    }

    /// Add an output observer for a session
    func addOutputObserver(sessionID: String, observer: @escaping (OutputChunk) -> Void) {
        if sessionObservers[sessionID] == nil {
            sessionObservers[sessionID] = []
        }
        sessionObservers[sessionID]?.append(observer)
    }

    /// Add a state observer for a session
    func addStateObserver(sessionID: String, observer: @escaping (SessionState) -> Void) {
        if stateObservers[sessionID] == nil {
            stateObservers[sessionID] = []
        }
        stateObservers[sessionID]?.append(observer)
    }

    /// Remove all observers for a session (called on disconnect)
    func removeObservers(sessionID: String) {
        sessionObservers.removeValue(forKey: sessionID)
        stateObservers.removeValue(forKey: sessionID)
    }

    private func notifyOutputObservers(sessionID: String, chunk: OutputChunk) {
        guard let observers = sessionObservers[sessionID] else { return }
        for observer in observers {
            observer(chunk)
        }
    }

    private func notifyStateObservers(sessionID: String, state: SessionState) {
        guard let observers = stateObservers[sessionID] else { return }
        for observer in observers {
            observer(state)
        }
    }

    private func generateSessionID() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }
}
