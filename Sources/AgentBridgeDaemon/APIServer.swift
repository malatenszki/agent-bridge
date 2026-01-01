import Vapor
import Foundation

/// Vapor-based API server for REST and WebSocket endpoints
final class APIServer {
    private let app: Application
    private let sessionManager: SessionManager
    private let authManager: AuthManager
    private let processScanner: ProcessScanner
    private let host: String
    private let port: Int

    init(sessionManager: SessionManager, authManager: AuthManager, processScanner: ProcessScanner, host: String = "0.0.0.0", port: Int = 8765) throws {
        self.sessionManager = sessionManager
        self.authManager = authManager
        self.processScanner = processScanner
        self.host = host
        self.port = port

        var env = Environment.production
        env.arguments = ["serve"]
        self.app = try Application(env)

        // Suppress verbose Vapor logging
        app.logger.logLevel = .error

        configureRoutes()
    }

    private func configureRoutes() {
        // CORS middleware
        let cors = CORSMiddleware(configuration: .init(
            allowedOrigin: .all,
            allowedMethods: [.GET, .POST, .PUT, .DELETE, .OPTIONS],
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
        ))
        app.middleware.use(cors)

        // Health check
        app.get("health") { _ in
            StatusResponse(status: "ok")
        }

        // Pairing endpoint (no auth required)
        app.post("pair") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handlePair(req)
        }

        // Protected routes group
        let protected = app.grouped(AuthMiddleware(authManager: authManager))

        // Sessions endpoints
        protected.get("sessions") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handleGetSessions(req)
        }

        protected.post("sessions") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handleCreateSession(req)
        }

        protected.get("sessions", ":id") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handleGetSession(req)
        }

        protected.get("sessions", ":id", "history") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handleGetHistory(req)
        }

        protected.post("sessions", ":id", "input") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handleSendInput(req)
        }

        protected.delete("sessions", ":id") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handleDeleteSession(req)
        }

        // Process detection endpoint
        protected.get("processes") { [weak self] req async throws -> Response in
            guard let self = self else { throw Abort(.internalServerError) }
            return try await self.handleGetProcesses(req)
        }

        // WebSocket endpoint
        app.webSocket("ws") { [weak self] req, ws in
            guard let self = self else { return }
            await self.handleWebSocket(req, ws: ws)
        }
    }

    // MARK: - Pairing

    private func handlePair(_ req: Request) async throws -> Response {
        struct PairRequest: Content {
            let token: String
            let deviceID: String
        }

        let pairReq = try req.content.decode(PairRequest.self)

        guard let deviceKey = await authManager.validatePairingToken(pairReq.token, deviceID: pairReq.deviceID) else {
            throw Abort(.unauthorized, reason: "Invalid or expired pairing token")
        }

        struct PairResponse: Content {
            let deviceKey: String
            let message: String
        }

        let response = PairResponse(
            deviceKey: deviceKey.key,
            message: "Successfully paired"
        )

        return try await response.encodeResponse(for: req)
    }

    // MARK: - Sessions

    private func handleGetSessions(_ req: Request) async throws -> Response {
        let summaries = await sessionManager.getAllSessions()
        return try await summaries.encodeResponse(for: req)
    }

    private func handleCreateSession(_ req: Request) async throws -> Response {
        struct CreateSessionRequest: Content {
            let command: String
            let arguments: [String]?
        }

        let createReq = try req.content.decode(CreateSessionRequest.self)

        let session = try await sessionManager.createSession(
            command: createReq.command,
            arguments: createReq.arguments ?? []
        )

        return try await SessionSummary(from: session).encodeResponse(for: req)
    }

    private func handleGetSession(_ req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing session ID")
        }

        guard let session = await sessionManager.getSession(id) else {
            throw Abort(.notFound, reason: "Session not found")
        }

        return try await SessionSummary(from: session).encodeResponse(for: req)
    }

    private func handleGetHistory(_ req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing session ID")
        }

        let limit = req.query[Int.self, at: "limit"]
        let offset = req.query[Int.self, at: "offset"] ?? 0

        // Use the new unified getHistory method
        let history = await sessionManager.getHistory(id, limit: limit, offset: offset)
        return try await history.encodeResponse(for: req)
    }

    private func handleSendInput(_ req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing session ID")
        }

        struct InputRequest: Content {
            let input: String
        }

        let inputReq = try req.content.decode(InputRequest.self)

        // Use the new unified sendInput method
        await sessionManager.sendInput(id, input: inputReq.input)

        return try await StatusResponse(status: "ok").encodeResponse(for: req)
    }

    private func handleDeleteSession(_ req: Request) async throws -> Response {
        guard let id = req.parameters.get("id") else {
            throw Abort(.badRequest, reason: "Missing session ID")
        }

        await sessionManager.removeSession(id)
        return try await StatusResponse(status: "ok").encodeResponse(for: req)
    }

    private func handleGetProcesses(_ req: Request) async throws -> Response {
        let processes = await processScanner.getProcesses()
        return try await processes.encodeResponse(for: req)
    }

    // MARK: - WebSocket

    private func handleWebSocket(_ req: Request, ws: WebSocket) async {
        // Authenticate via query parameter or first message
        let deviceKey = req.query[String.self, at: "key"]

        if let key = deviceKey {
            let valid = await authManager.validateDeviceKey(key)
            if !valid {
                try? await ws.close(code: .policyViolation)
                return
            }
        } else {
            // Wait for auth message
            let authResult = await waitForAuth(ws)
            if !authResult {
                try? await ws.close(code: .policyViolation)
                return
            }
        }

        // Handle subscriptions
        var subscribedSessions: Set<String> = []

        ws.onText { [weak self] ws, text async in
            guard let self = self else { return }
            await self.handleWebSocketMessage(ws, text: text, subscribedSessions: &subscribedSessions)
        }

        ws.onClose.whenComplete { [weak self] _ in
            Task { [weak self] in
                for sessionID in subscribedSessions {
                    await self?.sessionManager.removeObservers(sessionID: sessionID)
                }
            }
        }
    }

    private func waitForAuth(_ ws: WebSocket) async -> Bool {
        return await withCheckedContinuation { continuation in
            var resumed = false
            let timeout = DispatchWorkItem {
                if !resumed {
                    resumed = true
                    continuation.resume(returning: false)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: timeout)

            ws.onText { [weak self] ws, text in
                timeout.cancel()
                if resumed { return }
                resumed = true

                struct AuthMessage: Codable {
                    let type: String
                    let key: String
                }

                guard let data = text.data(using: .utf8),
                      let msg = try? JSONDecoder().decode(AuthMessage.self, from: data),
                      msg.type == "auth" else {
                    continuation.resume(returning: false)
                    return
                }

                Task { [weak self] in
                    let valid = await self?.authManager.validateDeviceKey(msg.key) ?? false
                    continuation.resume(returning: valid)
                }
            }
        }
    }

    private func handleWebSocketMessage(_ ws: WebSocket, text: String, subscribedSessions: inout Set<String>) async {
        guard let data = text.data(using: .utf8) else { return }

        struct WSMessage: Codable {
            let type: String
            let sessionID: String?
            let input: String?
        }

        guard let msg = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }

        switch msg.type {
        case "subscribe":
            guard let sessionID = msg.sessionID else { return }

            // Remove any existing observers first to avoid duplicates
            await sessionManager.removeObservers(sessionID: sessionID)

            subscribedSessions.insert(sessionID)

            // Add output observer with weak ws capture
            await sessionManager.addOutputObserver(sessionID: sessionID) { [weak ws] chunk in
                guard let ws = ws else { return }
                let event = OutputEvent(type: "output", sessionID: sessionID, chunk: chunk)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let json = try? encoder.encode(event),
                   let str = String(data: json, encoding: .utf8) {
                    ws.send(str)
                }
            }

            // Add state observer with weak ws capture
            await sessionManager.addStateObserver(sessionID: sessionID) { [weak ws] state in
                guard let ws = ws else { return }
                let event = StateEvent(type: "state", sessionID: sessionID, state: state)
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                if let json = try? encoder.encode(event),
                   let str = String(data: json, encoding: .utf8) {
                    ws.send(str)
                }
            }

        case "unsubscribe":
            guard let sessionID = msg.sessionID else { return }
            subscribedSessions.remove(sessionID)
            await sessionManager.removeObservers(sessionID: sessionID)

        case "input":
            guard let sessionID = msg.sessionID,
                  let input = msg.input else { return }

            if let session = await sessionManager.getSession(sessionID) {
                session.sendInput(input)
            }

        default:
            break
        }
    }

    // MARK: - Server Control

    func start() async throws {
        app.http.server.configuration.hostname = host
        app.http.server.configuration.port = port

        // Use execute() instead of startup() - it blocks until the server stops
        try await app.execute()
    }

    func shutdown() async throws {
        try await app.asyncShutdown()
    }

    var runningPort: Int {
        return port
    }
}

// MARK: - WebSocket Events

struct OutputEvent: Codable {
    let type: String
    let sessionID: String
    let chunk: OutputChunk
}

struct StateEvent: Codable {
    let type: String
    let sessionID: String
    let state: SessionState
}

// MARK: - Auth Middleware

struct AuthMiddleware: AsyncMiddleware {
    let authManager: AuthManager

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        // Get key from Authorization header or query
        let key: String?
        if let auth = request.headers.bearerAuthorization?.token {
            key = auth
        } else {
            key = request.query[String.self, at: "key"]
        }

        guard let deviceKey = key else {
            throw Abort(.unauthorized, reason: "Missing authentication")
        }

        let valid = await authManager.validateDeviceKey(deviceKey)
        guard valid else {
            throw Abort(.unauthorized, reason: "Invalid authentication")
        }

        return try await next.respond(to: request)
    }
}

// MARK: - Content Conformance

extension SessionSummary: Content {}
extension OutputChunk: Content {}
extension ExternalProcess: Content {}

struct StatusResponse: Content {
    let status: String
}
