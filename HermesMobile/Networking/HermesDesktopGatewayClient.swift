import Foundation
import Observation

enum HermesDesktopGatewayError: LocalizedError, Equatable {
    case invalidServerURL
    case invalidPairingCode
    case missingToken
    case tokenDiscoveryFailed(String)
    case notConnected
    case connectionTimedOut
    case requestTimedOut(String)
    case connectionClosed(String)
    case invalidResponse(String)
    case rpc(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            String(localized: "Enter a valid Hermes Desktop gateway URL.")
        case .invalidPairingCode:
            String(localized: "This is not a valid Hermes Desktop mobile pairing code.")
        case .missingToken:
            String(localized: "Enter the Hermes Desktop gateway token.")
        case .tokenDiscoveryFailed(let reason):
            String(localized: "Could not discover the Hermes Desktop gateway token: \(reason)")
        case .notConnected:
            String(localized: "Hermes Desktop gateway is not connected.")
        case .connectionTimedOut:
            String(localized: "Hermes Desktop did not finish connecting in time.")
        case .requestTimedOut(let method):
            String(localized: "Hermes Desktop did not answer \(method) in time.")
        case .connectionClosed(let reason):
            reason.isEmpty
                ? String(localized: "The Hermes Desktop connection closed.")
                : String(localized: "The Hermes Desktop connection closed: \(reason)")
        case .invalidResponse(let message):
            String(localized: "Hermes Desktop returned an invalid response: \(message)")
        case .rpc(_, let message):
            message
        }
    }
}

struct HermesDesktopGatewayConfiguration: Equatable, Sendable {
    let serverURL: URL
    let token: String
}

@MainActor
@Observable
final class HermesDesktopGatewayAccount {
    private(set) var configuration: HermesDesktopGatewayConfiguration?
    private(set) var isConnecting = false
    private(set) var lastErrorMessage: String?

    private let keychain: any KeychainStoring
    private let clientFactory: @MainActor (HermesDesktopGatewayConfiguration) -> HermesDesktopGatewayClient
    private let tokenResolver: (URL) async throws -> String

    init(
        keychain: any KeychainStoring = KeychainStore(),
        clientFactory: @escaping @MainActor (HermesDesktopGatewayConfiguration) -> HermesDesktopGatewayClient = {
            HermesDesktopGatewayClient(configuration: $0)
        },
        tokenResolver: @escaping (URL) async throws -> String = {
            try await HermesDesktopGatewayClient.discoverServedToken(serverURL: $0)
        }
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.tokenResolver = tokenResolver
        restore()
    }

    @discardableResult
    func configure(serverURLString: String, token: String) async -> Bool {
        lastErrorMessage = nil
        isConnecting = true
        defer { isConnecting = false }

        do {
            let serverURL = try HermesDesktopGatewayClient.normalizedServerURL(serverURLString)
            let enteredToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedToken = enteredToken.isEmpty ? try await tokenResolver(serverURL) : enteredToken
            let candidate = try HermesDesktopGatewayClient.normalizedConfiguration(
                serverURLString: serverURL.absoluteString,
                token: resolvedToken
            )
            let probe = clientFactory(candidate)
            try await probe.connect()
            _ = try await probe.listProfiles(includeSessions: false)
            probe.disconnect()

            try keychain.save(candidate.serverURL.absoluteString, forKey: .desktopGatewayURL)
            try keychain.save(candidate.token, forKey: .desktopGatewayToken)
            configuration = candidate
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func forget() {
        try? keychain.delete(.desktopGatewayURL)
        try? keychain.delete(.desktopGatewayToken)
        configuration = nil
        lastErrorMessage = nil
    }

    /// Hermes Desktop rotates its served session token when its backend restarts.
    /// Refresh it opportunistically from the same gateway page while retaining a
    /// manually supplied token when the page is headless or OAuth-gated.
    func refreshServedTokenIfAvailable() async {
        guard let current = configuration else { return }
        guard let refreshedToken = try? await tokenResolver(current.serverURL),
              refreshedToken != current.token
        else {
            return
        }

        do {
            try keychain.save(refreshedToken, forKey: .desktopGatewayToken)
            configuration = HermesDesktopGatewayConfiguration(
                serverURL: current.serverURL,
                token: refreshedToken
            )
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func restore() {
        guard let rawURL = try? keychain.load(.desktopGatewayURL),
              let token = try? keychain.load(.desktopGatewayToken),
              let restored = try? HermesDesktopGatewayClient.normalizedConfiguration(
                  serverURLString: rawURL,
                  token: token
              )
        else {
            configuration = nil
            return
        }
        configuration = restored
    }
}

struct HermesDesktopGatewaySessionSummary: Identifiable, Equatable {
    let id: String
    let resolvedID: String?
    let title: String
    let preview: String
    let startedAt: Double?
    let lastActive: Double?
    let messageCount: Int
    let source: String?
}

struct HermesDesktopGatewayProfile: Identifiable, Equatable {
    var id: String { name }

    let name: String
    let displayName: String
    let description: String
    let model: String?
    let provider: String?
    let skillCount: Int
    let isDefault: Bool
    let lastSession: HermesDesktopGatewaySessionSummary?
    let workerSession: HermesDesktopGatewaySessionSummary?
}

struct HermesDesktopGatewayMessage: Identifiable, Equatable {
    let id: String
    let role: String
    var content: String
    let timestamp: Double?
}

struct HermesDesktopGatewaySessionSnapshot: Equatable {
    let runtimeSessionID: String
    let storedSessionID: String?
    let title: String?
    let model: String?
    let provider: String?
    let isRunning: Bool
    let messages: [HermesDesktopGatewayMessage]
}

struct HermesDesktopGatewayApproval: Identifiable, Equatable {
    let id: String
    let toolName: String
    let command: String
    let description: String
    let choices: [String]
}

struct HermesDesktopGatewaySkillGroup: Identifiable, Equatable {
    var id: String { category }
    let category: String
    let skills: [String]
}

struct HermesDesktopGatewayLearningSummary: Equatable {
    let count: Int
    let summary: [String]
    let legend: [String]
}

struct HermesDesktopGatewayEvent: Equatable {
    let type: String
    let sessionID: String?
    let profile: String?
    let payload: [String: JSONValue]
}

private struct HermesDesktopRPCError: Decodable {
    let code: Int
    let message: String
}

private struct HermesDesktopRPCEnvelope: Decodable {
    let id: Int?
    let result: JSONValue?
    let error: HermesDesktopRPCError?
    let method: String?
    let params: JSONValue?
}

private struct HermesDesktopRPCRequest: Encodable {
    let jsonrpc = "2.0"
    let id: Int
    let method: String
    let params: [String: JSONValue]
}

protocol HermesDesktopWebSocketTask: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
}

extension URLSessionWebSocketTask: HermesDesktopWebSocketTask {}

@MainActor
@Observable
final class HermesDesktopGatewayClient {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case degraded(String)
    }

    private(set) var state: ConnectionState = .disconnected

    private let configuration: HermesDesktopGatewayConfiguration
    private let socketFactory: (URL) -> any HermesDesktopWebSocketTask
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var socket: (any HermesDesktopWebSocketTask)?
    private var receiveTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pendingRequests: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var didReceiveReady = false
    private var eventObservers: [UUID: (HermesDesktopGatewayEvent) -> Void] = [:]
    private var connectionGeneration = 0

    init(
        configuration: HermesDesktopGatewayConfiguration,
        socketFactory: @escaping (URL) -> any HermesDesktopWebSocketTask = {
            URLSession.shared.webSocketTask(with: $0)
        }
    ) {
        self.configuration = configuration
        self.socketFactory = socketFactory
    }

    nonisolated static func normalizedConfiguration(serverURLString: String, token: String) throws -> HermesDesktopGatewayConfiguration {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw HermesDesktopGatewayError.missingToken
        }

        return HermesDesktopGatewayConfiguration(
            serverURL: try normalizedServerURL(serverURLString),
            token: trimmedToken
        )
    }

    nonisolated static func pairingConfiguration(from payload: String) throws -> HermesDesktopGatewayConfiguration {
        guard let components = URLComponents(
            string: payload.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
        components.scheme?.lowercased().hasPrefix("hermes-agent") == true,
        components.host?.lowercased() == "desktop-pair",
        let serverURLString = components.queryItems?.first(where: { $0.name == "server" })?.value,
        let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else {
            throw HermesDesktopGatewayError.invalidPairingCode
        }

        do {
            return try normalizedConfiguration(serverURLString: serverURLString, token: token)
        } catch {
            throw HermesDesktopGatewayError.invalidPairingCode
        }
    }

    nonisolated static func normalizedServerURL(_ serverURLString: String) throws -> URL {
        var raw = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw HermesDesktopGatewayError.invalidServerURL
        }
        if !raw.contains("://") {
            raw = "https://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false
        else {
            throw HermesDesktopGatewayError.invalidServerURL
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        let cleanedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = cleanedPath.isEmpty ? "" : "/\(cleanedPath)"

        guard let serverURL = components.url else {
            throw HermesDesktopGatewayError.invalidServerURL
        }
        return serverURL
    }

    nonisolated static func discoverServedToken(
        serverURL: URL,
        session: URLSession = .shared
    ) async throws -> String {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw HermesDesktopGatewayError.invalidServerURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/" : "/\(basePath)/"
        components.query = nil
        components.fragment = nil
        guard let indexURL = components.url else {
            throw HermesDesktopGatewayError.invalidServerURL
        }

        do {
            let (data, response) = try await session.data(from: indexURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw HermesDesktopGatewayError.tokenDiscoveryFailed("the gateway page was unavailable")
            }
            guard let html = String(data: data, encoding: .utf8),
                  let token = extractServedToken(from: html)
            else {
                throw HermesDesktopGatewayError.tokenDiscoveryFailed(
                    "no session token was advertised; paste a token from Hermes Desktop"
                )
            }
            return token
        } catch let error as HermesDesktopGatewayError {
            throw error
        } catch {
            throw HermesDesktopGatewayError.tokenDiscoveryFailed(error.localizedDescription)
        }
    }

    nonisolated static func extractServedToken(from html: String) -> String? {
        let pattern = #"window\.__HERMES_SESSION_TOKEN__\s*=\s*(\"(?:\\.|[^\"\\])*\")"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: html,
                  range: NSRange(html.startIndex..., in: html)
              ),
              let literalRange = Range(match.range(at: 1), in: html),
              let data = String(html[literalRange]).data(using: .utf8),
              let token = try? JSONDecoder().decode(String.self, from: data),
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    nonisolated static func webSocketURL(for configuration: HermesDesktopGatewayConfiguration) throws -> URL {
        guard var components = URLComponents(url: configuration.serverURL, resolvingAgainstBaseURL: false) else {
            throw HermesDesktopGatewayError.invalidServerURL
        }

        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw HermesDesktopGatewayError.invalidServerURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "/api/ws" : "/\(basePath)/api/ws"
        components.queryItems = [URLQueryItem(name: "token", value: configuration.token)]

        guard let url = components.url else {
            throw HermesDesktopGatewayError.invalidServerURL
        }
        return url
    }

    func connect(timeout: Duration = .seconds(12)) async throws {
        if state == .connected { return }
        disconnect()
        connectionGeneration &+= 1
        let generation = connectionGeneration

        let url = try Self.webSocketURL(for: configuration)
        let newSocket = socketFactory(url)
        socket = newSocket
        state = .connecting
        didReceiveReady = false
        newSocket.resume()
        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop(socket: newSocket, generation: generation)
        }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failReady(with: .connectionTimedOut, generation: generation)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            if didReceiveReady {
                continuation.resume()
            } else {
                readyContinuation = continuation
            }
        }
    }

    func disconnect() {
        connectionGeneration &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        didReceiveReady = false
        state = .disconnected

        readyContinuation?.resume(throwing: HermesDesktopGatewayError.notConnected)
        readyContinuation = nil
        failAllPending(with: HermesDesktopGatewayError.notConnected)
    }

    @discardableResult
    func observeEvents(_ observer: @escaping (HermesDesktopGatewayEvent) -> Void) -> UUID {
        let id = UUID()
        eventObservers[id] = observer
        return id
    }

    func removeEventObserver(_ id: UUID) {
        eventObservers.removeValue(forKey: id)
    }

    func listProfiles(includeSessions: Bool = true) async throws -> [HermesDesktopGatewayProfile] {
        let result = try await request(
            method: "profiles.list",
            params: ["include_sessions": .bool(includeSessions)]
        )
        guard let rows = result.gatewayObjectValue?["profiles"]?.gatewayArrayValue else {
            throw HermesDesktopGatewayError.invalidResponse("profiles.list did not include profiles")
        }
        return rows.compactMap(HermesDesktopGatewayProfile.init(json:))
    }

    func createSession(profile: String, title: String? = nil) async throws -> HermesDesktopGatewaySessionSnapshot {
        var params: [String: JSONValue] = [
            "profile": .string(profile),
            "source": .string("ios")
        ]
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            params["title"] = .string(title)
        }
        let result = try await request(method: "session.create", params: params)
        return try HermesDesktopGatewaySessionSnapshot(json: result)
    }

    func resumeSession(storedSessionID: String, profile: String) async throws -> HermesDesktopGatewaySessionSnapshot {
        let result = try await request(
            method: "session.resume",
            params: [
                "session_id": .string(storedSessionID),
                "profile": .string(profile),
                "source": .string("ios"),
                "close_on_disconnect": .bool(false)
            ]
        )
        return try HermesDesktopGatewaySessionSnapshot(json: result)
    }

    func submitPrompt(sessionID: String, text: String) async throws {
        _ = try await request(
            method: "prompt.submit",
            params: ["session_id": .string(sessionID), "text": .string(text)]
        )
    }

    func steer(sessionID: String, text: String) async throws -> Bool {
        let result = try await request(
            method: "session.steer",
            params: ["session_id": .string(sessionID), "text": .string(text)]
        )
        return result.gatewayObjectValue?["status"]?.gatewayStringValue == "queued"
    }

    func interrupt(sessionID: String) async throws {
        _ = try await request(
            method: "session.interrupt",
            params: ["session_id": .string(sessionID)]
        )
    }

    func pendingApprovals(sessionID: String) async throws -> [HermesDesktopGatewayApproval] {
        let result = try await request(
            method: "approval.pending",
            params: ["session_id": .string(sessionID)]
        )
        return (result.gatewayObjectValue?["approvals"]?.gatewayArrayValue ?? [])
            .compactMap(HermesDesktopGatewayApproval.init(json:))
    }

    func listSkills(profile: String) async throws -> [HermesDesktopGatewaySkillGroup] {
        let result = try await request(
            method: "skills.manage",
            params: [
                "action": .string("list"),
                "profile": .string(profile)
            ]
        )
        guard let categories = result.gatewayObjectValue?["skills"]?.gatewayObjectValue else {
            throw HermesDesktopGatewayError.invalidResponse("skills.manage did not include grouped skills")
        }
        return categories.compactMap { category, value in
            let skills = value.gatewayArrayValue?
                .compactMap(\.gatewayStringValue)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                ?? []
            return skills.isEmpty ? nil : HermesDesktopGatewaySkillGroup(category: category, skills: skills)
        }
        .sorted { $0.category.localizedCaseInsensitiveCompare($1.category) == .orderedAscending }
    }

    func learningSummary() async throws -> HermesDesktopGatewayLearningSummary {
        let result = try await request(
            method: "learning.frames",
            params: [
                "cols": .number(44),
                "rows": .number(14),
                "frames": .number(2)
            ]
        )
        guard let object = result.gatewayObjectValue else {
            throw HermesDesktopGatewayError.invalidResponse("learning.frames returned no summary")
        }
        let summary = object["summary"]?.gatewayArrayValue?.compactMap(\.gatewayStringValue) ?? []
        let legend = object["legend"]?.gatewayArrayValue?.compactMap { row in
            row.gatewayObjectValue?["label"]?.gatewayStringValue
        } ?? []
        return HermesDesktopGatewayLearningSummary(
            count: object["count"]?.gatewayIntValue ?? 0,
            summary: summary,
            legend: legend
        )
    }

    func respondToApproval(
        sessionID: String,
        requestID: String,
        choice: String,
        resolveAll: Bool = false
    ) async throws -> Int {
        let result = try await request(
            method: "approval.respond",
            params: [
                "session_id": .string(sessionID),
                "request_id": .string(requestID),
                "choice": .string(choice),
                "all": .bool(resolveAll)
            ]
        )
        return result.gatewayObjectValue?["resolved"]?.gatewayIntValue ?? 0
    }

    func request(method: String, params: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let socket, state == .connected else {
            throw HermesDesktopGatewayError.notConnected
        }

        let requestID = nextRequestID
        nextRequestID += 1
        let wireRequest = HermesDesktopRPCRequest(id: requestID, method: method, params: params)
        let data = try encoder.encode(wireRequest)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HermesDesktopGatewayError.invalidResponse("could not encode request")
        }

        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.requestTimeout(for: method))
            } catch {
                return
            }
            self?.failRequest(
                requestID,
                with: HermesDesktopGatewayError.requestTimedOut(method)
            )
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
            Task { [weak self] in
                do {
                    try await socket.send(.string(text))
                } catch {
                    await self?.failRequest(requestID, with: error)
                }
            }
        }
    }

    private static func requestTimeout(for method: String) -> Duration {
        switch method {
        case "prompt.submit":
            // The gateway acknowledges after the agent turn and permits runs up
            // to 30 minutes. Completion still arrives through message.complete.
            .seconds(1_800)
        case "profiles.list", "session.create", "session.resume":
            .seconds(60)
        default:
            .seconds(30)
        }
    }

    private func receiveLoop(socket: any HermesDesktopWebSocketTask, generation: Int) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let payload):
                    data = payload
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    continue
                }
                try handleIncoming(data, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            handleSocketFailure(error, generation: generation)
        }
    }

    private func handleIncoming(_ data: Data, generation: Int) throws {
        guard generation == connectionGeneration else { return }
        let envelope = try decoder.decode(HermesDesktopRPCEnvelope.self, from: data)

        if let id = envelope.id {
            guard let continuation = pendingRequests.removeValue(forKey: id) else { return }
            if let error = envelope.error {
                continuation.resume(throwing: HermesDesktopGatewayError.rpc(code: error.code, message: error.message))
            } else {
                continuation.resume(returning: envelope.result ?? .null)
            }
            return
        }

        guard envelope.method == "event",
              let params = envelope.params?.gatewayObjectValue,
              let type = params["type"]?.gatewayStringValue
        else {
            return
        }

        let event = HermesDesktopGatewayEvent(
            type: type,
            sessionID: params["session_id"]?.gatewayStringValue ?? params["sessionId"]?.gatewayStringValue,
            profile: params["profile"]?.gatewayStringValue,
            payload: params["payload"]?.gatewayObjectValue ?? [:]
        )

        if type == "gateway.ready" {
            didReceiveReady = true
            state = .connected
            readyContinuation?.resume()
            readyContinuation = nil
        }

        for observer in Array(eventObservers.values) {
            observer(event)
        }
    }

    private func handleSocketFailure(_ error: Error, generation: Int) {
        guard generation == connectionGeneration else { return }
        let reason = error.localizedDescription
        state = .degraded(reason)
        didReceiveReady = false
        receiveTask = nil
        socket = nil
        readyContinuation?.resume(throwing: HermesDesktopGatewayError.connectionClosed(reason))
        readyContinuation = nil
        failAllPending(with: HermesDesktopGatewayError.connectionClosed(reason))
    }

    private func failReady(with error: HermesDesktopGatewayError, generation: Int) {
        guard generation == connectionGeneration, !didReceiveReady else { return }
        state = .degraded(error.localizedDescription)
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func failRequest(_ requestID: Int, with error: Error) {
        pendingRequests.removeValue(forKey: requestID)?.resume(throwing: error)
    }

    private func failAllPending(with error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        for continuation in requests {
            continuation.resume(throwing: error)
        }
    }
}

private extension HermesDesktopGatewayProfile {
    init?(json: JSONValue) {
        guard let object = json.gatewayObjectValue,
              let name = object["name"]?.gatewayStringValue,
              !name.isEmpty
        else {
            return nil
        }
        let explicitDisplayName = object["display_name"]?.gatewayStringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = explicitDisplayName.flatMap { $0.isEmpty ? nil : $0 } ?? name.capitalized
        self.init(
            name: name,
            displayName: displayName,
            description: object["description"]?.gatewayStringValue ?? "",
            model: object["model"]?.gatewayStringValue,
            provider: object["provider"]?.gatewayStringValue,
            skillCount: object["skill_count"]?.gatewayIntValue ?? 0,
            isDefault: object["is_default"]?.gatewayBoolValue ?? false,
            lastSession: object["last_session"].flatMap(HermesDesktopGatewaySessionSummary.init(json:)),
            workerSession: object["worker_session"].flatMap(HermesDesktopGatewaySessionSummary.init(json:))
        )
    }
}

private extension HermesDesktopGatewaySessionSummary {
    init?(json: JSONValue) {
        guard let object = json.gatewayObjectValue,
              let id = object["id"]?.gatewayStringValue,
              !id.isEmpty
        else {
            return nil
        }
        self.init(
            id: id,
            resolvedID: object["resolved_id"]?.gatewayStringValue,
            title: object["title"]?.gatewayStringValue ?? "",
            preview: object["preview"]?.gatewayStringValue ?? "",
            startedAt: object["started_at"]?.gatewayDoubleValue,
            lastActive: object["last_active"]?.gatewayDoubleValue,
            messageCount: object["message_count"]?.gatewayIntValue ?? 0,
            source: object["source"]?.gatewayStringValue
        )
    }
}

private extension HermesDesktopGatewaySessionSnapshot {
    init(json: JSONValue) throws {
        guard let object = json.gatewayObjectValue,
              let runtimeID = object["session_id"]?.gatewayStringValue,
              !runtimeID.isEmpty
        else {
            throw HermesDesktopGatewayError.invalidResponse("session response did not include session_id")
        }

        let info = object["info"]?.gatewayObjectValue ?? [:]
        let rows = object["messages"]?.gatewayArrayValue ?? []
        self.init(
            runtimeSessionID: runtimeID,
            storedSessionID: object["stored_session_id"]?.gatewayStringValue
                ?? object["session_key"]?.gatewayStringValue
                ?? object["resumed"]?.gatewayStringValue,
            title: object["title"]?.gatewayStringValue,
            model: info["model"]?.gatewayStringValue,
            provider: info["provider"]?.gatewayStringValue,
            isRunning: object["running"]?.gatewayBoolValue ?? false,
            messages: rows.enumerated().compactMap { index, row in
                HermesDesktopGatewayMessage(json: row, fallbackID: "message-\(index)")
            }
        )
    }
}

private extension HermesDesktopGatewayMessage {
    init?(json: JSONValue, fallbackID: String) {
        guard let object = json.gatewayObjectValue,
              let role = object["role"]?.gatewayStringValue
        else {
            return nil
        }
        self.init(
            id: object["message_id"]?.gatewayStringValue
                ?? object["row_id"]?.gatewayStringValue
                ?? fallbackID,
            role: role,
            content: object["content"]?.gatewayStringValue ?? "",
            timestamp: object["timestamp"]?.gatewayDoubleValue ?? object["_ts"]?.gatewayDoubleValue
        )
    }
}

private extension HermesDesktopGatewayApproval {
    init?(json: JSONValue) {
        guard let object = json.gatewayObjectValue,
              let requestID = object["request_id"]?.gatewayStringValue,
              !requestID.isEmpty
        else {
            return nil
        }
        let details = object["details"]?.gatewayObjectValue ?? [:]
        self.init(
            id: requestID,
            toolName: object["tool"]?.gatewayStringValue ?? object["name"]?.gatewayStringValue ?? "tool",
            command: object["command"]?.gatewayStringValue
                ?? details["command"]?.gatewayStringValue
                ?? details["cmd"]?.gatewayStringValue
                ?? "",
            description: object["description"]?.gatewayStringValue
                ?? object["reason"]?.gatewayStringValue
                ?? "Hermes needs your approval to continue.",
            choices: object["choices"]?.gatewayArrayValue?.compactMap(\.gatewayStringValue) ?? ["once", "session", "deny"]
        )
    }
}

private extension JSONValue {
    var gatewayObjectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var gatewayArrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var gatewayStringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        default: nil
        }
    }

    var gatewayDoubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var gatewayIntValue: Int? {
        guard let value = gatewayDoubleValue, value.isFinite else { return nil }
        return Int(value)
    }

    var gatewayBoolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes", "on": true
            case "false", "0", "no", "off": false
            default: nil
            }
        default: nil
        }
    }
}
