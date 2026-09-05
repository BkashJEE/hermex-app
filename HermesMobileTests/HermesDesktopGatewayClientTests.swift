import Foundation
import XCTest
@testable import HermesMobile

final class HermesDesktopGatewayClientTests: XCTestCase {
    func testNormalizesBareHostAndBuildsAuthenticatedWebSocketURL() throws {
        let configuration = try HermesDesktopGatewayClient.normalizedConfiguration(
            serverURLString: "gateway.example.com/hermes/",
            token: " a/b c+d "
        )

        XCTAssertEqual(configuration.serverURL.absoluteString, "https://gateway.example.com/hermes")
        let url = try HermesDesktopGatewayClient.webSocketURL(for: configuration)
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "gateway.example.com")
        XCTAssertEqual(url.path, "/hermes/api/ws")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value,
            "a/b c+d"
        )
    }

    func testRejectsMissingTokenAndUnsupportedScheme() {
        XCTAssertThrowsError(
            try HermesDesktopGatewayClient.normalizedConfiguration(
                serverURLString: "https://gateway.example.com",
                token: "   "
            )
        ) { error in
            XCTAssertEqual(error as? HermesDesktopGatewayError, .missingToken)
        }

        XCTAssertThrowsError(
            try HermesDesktopGatewayClient.normalizedConfiguration(
                serverURLString: "ftp://gateway.example.com",
                token: "token"
            )
        ) { error in
            XCTAssertEqual(error as? HermesDesktopGatewayError, .invalidServerURL)
        }
    }

    func testParsesDesktopPairingCodeWithEncodedGatewayAndToken() throws {
        let configuration = try HermesDesktopGatewayClient.pairingConfiguration(
            from: "hermes-agent://desktop-pair?server=https%3A%2F%2Fdesktop.example.com%3A9443&token=a%2Fb%20c%2Bd"
        )

        XCTAssertEqual(configuration.serverURL.absoluteString, "https://desktop.example.com:9443")
        XCTAssertEqual(configuration.token, "a/b c+d")
    }

    func testRejectsForeignOrIncompleteDesktopPairingCode() {
        for payload in [
            "https://desktop.example.com",
            "hermes-agent-evil://desktop-pair?server=https://desktop.example.com&token=secret",
            "hermes-agent://new-chat?server=https://desktop.example.com&token=secret",
            "hermes-agent://desktop-pair?server=https://desktop.example.com",
        ] {
            XCTAssertThrowsError(try HermesDesktopGatewayClient.pairingConfiguration(from: payload)) { error in
                XCTAssertEqual(error as? HermesDesktopGatewayError, .invalidPairingCode)
            }
        }
    }

    func testExtractsServedDashboardTokenWithoutEvaluatingPageScript() {
        let html = #"<html><script>window.__HERMES_SESSION_TOKEN__="a/b\"c+d";</script></html>"#
        XCTAssertEqual(HermesDesktopGatewayClient.extractServedToken(from: html), "a/b\"c+d")
        XCTAssertNil(HermesDesktopGatewayClient.extractServedToken(from: "<html>No token</html>"))
    }

    @MainActor
    func testReadyThenListsEveryProfileWithRosterSessionData() async throws {
        let socket = MockHermesDesktopWebSocketTask()
        let configuration = try HermesDesktopGatewayClient.normalizedConfiguration(
            serverURLString: "https://gateway.example.com",
            token: "test-token"
        )
        let client = HermesDesktopGatewayClient(configuration: configuration) { _ in socket }

        let connectTask = Task { try await client.connect(timeout: .seconds(1)) }
        socket.enqueue(
            #"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":true}}}"#
        )
        try await connectTask.value
        XCTAssertEqual(client.state, .connected)

        let profilesTask = Task { try await client.listProfiles() }
        try await socket.waitForSentMessageCount(1)
        let requestID = try XCTUnwrap(socket.sentRequestID(at: 0))
        socket.enqueue(
            """
            {"jsonrpc":"2.0","id":\(requestID),"result":{"profiles":[
              {"name":"default","display_name":"Hermes","is_default":true,"model":"gpt-5","provider":"openai","skill_count":18,
               "last_session":{"id":"session-a","resolved_id":"session-a-tip","title":"Release readiness","preview":"Reviewing onboarding notes","last_active":1788552000,"message_count":12}},
              {"name":"research","display_name":"Research","description":"Evidence and source review","model":"gpt-5","provider":"openai","skill_count":9,
               "worker_session":{"id":"worker-1","title":"Source audit","last_active":1788552060,"message_count":3,"source":"tool"}}
            ]}}
            """
        )

        let profiles = try await profilesTask.value
        XCTAssertEqual(profiles.map(\.name), ["default", "research"])
        XCTAssertEqual(profiles[0].displayName, "Hermes")
        XCTAssertEqual(profiles[0].lastSession?.resolvedID, "session-a-tip")
        XCTAssertEqual(profiles[1].description, "Evidence and source review")
        XCTAssertEqual(profiles[1].workerSession?.source, "tool")

        let request = try socket.sentJSON(at: 0)
        XCTAssertEqual(request["method"] as? String, "profiles.list")
        XCTAssertEqual((request["params"] as? [String: Any])?["include_sessions"] as? Bool, true)
    }

    @MainActor
    func testProfileScopedCreatePromptSteerApprovalAndInterruptUseGatewayContract() async throws {
        let socket = MockHermesDesktopWebSocketTask()
        let configuration = try HermesDesktopGatewayClient.normalizedConfiguration(
            serverURLString: "http://127.0.0.1:5000",
            token: "test-token"
        )
        let client = HermesDesktopGatewayClient(configuration: configuration) { _ in socket }

        let connectTask = Task { try await client.connect(timeout: .seconds(1)) }
        socket.enqueue(#"{"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{}}}"#)
        try await connectTask.value

        let createTask = Task { try await client.createSession(profile: "research", title: "Mobile review") }
        try await socket.waitForSentMessageCount(1)
        socket.enqueue(
            """
            {"jsonrpc":"2.0","id":1,"result":{"session_id":"runtime-1","stored_session_id":"stored-1","messages":[],"info":{"model":"gpt-5","provider":"openai"}}}
            """
        )
        let snapshot = try await createTask.value
        XCTAssertEqual(snapshot.runtimeSessionID, "runtime-1")
        XCTAssertEqual(snapshot.storedSessionID, "stored-1")
        XCTAssertEqual(snapshot.model, "gpt-5")

        async let prompt: Void = client.submitPrompt(sessionID: "runtime-1", text: "Audit the release")
        try await socket.waitForSentMessageCount(2)
        socket.enqueue(#"{"jsonrpc":"2.0","id":2,"result":{"accepted":true}}"#)
        try await prompt

        async let steer: Bool = client.steer(sessionID: "runtime-1", text: "Check security too")
        try await socket.waitForSentMessageCount(3)
        socket.enqueue(#"{"jsonrpc":"2.0","id":3,"result":{"status":"queued"}}"#)
        let steerAccepted = try await steer
        XCTAssertTrue(steerAccepted)

        async let approval: Int = client.respondToApproval(
            sessionID: "runtime-1",
            requestID: "approval-1",
            choice: "once"
        )
        try await socket.waitForSentMessageCount(4)
        socket.enqueue(#"{"jsonrpc":"2.0","id":4,"result":{"resolved":1}}"#)
        let resolvedApprovalCount = try await approval
        XCTAssertEqual(resolvedApprovalCount, 1)

        async let interrupt: Void = client.interrupt(sessionID: "runtime-1")
        try await socket.waitForSentMessageCount(5)
        socket.enqueue(#"{"jsonrpc":"2.0","id":5,"result":{"status":"interrupted"}}"#)
        try await interrupt

        async let pendingApprovals = client.pendingApprovals(sessionID: "runtime-1")
        try await socket.waitForSentMessageCount(6)
        socket.enqueue(
            #"{"jsonrpc":"2.0","id":6,"result":{"approvals":[{"request_id":"approval-2","tool":"terminal","command":"git status","description":"Inspect the repository","choices":["once","session","deny"]}]}}"#
        )
        let approvals = try await pendingApprovals
        XCTAssertEqual(approvals.first?.toolName, "terminal")
        XCTAssertEqual(approvals.first?.choices, ["once", "session", "deny"])

        async let skillGroups = client.listSkills(profile: "research")
        try await socket.waitForSentMessageCount(7)
        socket.enqueue(
            #"{"jsonrpc":"2.0","id":7,"result":{"skills":{"research":["source-check","paper-review"],"general":["summarize"]}}}"#
        )
        let groups = try await skillGroups
        XCTAssertEqual(groups.map(\.category), ["general", "research"])
        XCTAssertEqual(groups[1].skills, ["paper-review", "source-check"])

        async let learningSummary = client.learningSummary()
        try await socket.waitForSentMessageCount(8)
        socket.enqueue(
            #"{"jsonrpc":"2.0","id":8,"result":{"count":27,"summary":["19 learned skills · 8 memories"],"legend":[{"label":"skills (19)"},{"label":"memories (8)"}]}}"#
        )
        let learning = try await learningSummary
        XCTAssertEqual(learning.count, 27)
        XCTAssertEqual(learning.legend, ["skills (19)", "memories (8)"])

        let createRequest = try socket.sentJSON(at: 0)
        XCTAssertEqual(createRequest["method"] as? String, "session.create")
        XCTAssertEqual((createRequest["params"] as? [String: Any])?["profile"] as? String, "research")
        XCTAssertEqual((createRequest["params"] as? [String: Any])?["source"] as? String, "ios")

        XCTAssertEqual(try socket.sentJSON(at: 1)["method"] as? String, "prompt.submit")
        XCTAssertEqual(try socket.sentJSON(at: 2)["method"] as? String, "session.steer")
        XCTAssertEqual(try socket.sentJSON(at: 3)["method"] as? String, "approval.respond")
        XCTAssertEqual(try socket.sentJSON(at: 4)["method"] as? String, "session.interrupt")
        XCTAssertEqual(try socket.sentJSON(at: 5)["method"] as? String, "approval.pending")
        XCTAssertEqual(try socket.sentJSON(at: 6)["method"] as? String, "skills.manage")
        XCTAssertEqual(try socket.sentJSON(at: 7)["method"] as? String, "learning.frames")
    }

    @MainActor
    func testLiveTLSGatewayDiscoversAllProfilesAndCompletesPrompt() async throws {
        var pairingCode = URLComponents()
        pairingCode.scheme = "hermes-agent"
        pairingCode.host = "desktop-pair"
        pairingCode.queryItems = [
            URLQueryItem(name: "server", value: "https://127.0.0.1:18791"),
            URLQueryItem(name: "token", value: "hermes-mobile-ci-token"),
        ]
        let configuration = try HermesDesktopGatewayClient.pairingConfiguration(
            from: try XCTUnwrap(pairingCode.string)
        )
        let trustDelegate = HermesGatewayFixtureTrustDelegate()
        let gatewaySession = URLSession(configuration: .ephemeral, delegate: trustDelegate, delegateQueue: nil)
        let client = HermesDesktopGatewayClient(
            configuration: configuration,
            socketFactory: { gatewaySession.webSocketTask(with: $0) }
        )
        defer {
            client.disconnect()
            gatewaySession.invalidateAndCancel()
        }

        let connectionTimeout: Duration
#if HERMES_GATEWAY_CI
        connectionTimeout = .seconds(12)
#else
        connectionTimeout = .seconds(2)
#endif
        do {
            try await client.connect(timeout: connectionTimeout)
        } catch {
#if HERMES_GATEWAY_CI
            XCTFail("Hermes Desktop gateway integration failed: \(error.localizedDescription)")
            return
#else
            throw XCTSkip("The live Hermes Desktop gateway fixture is enabled in PR CI: \(error.localizedDescription)")
#endif
        }
        XCTAssertEqual(client.state, .connected)

        let completed = expectation(description: "Hermes Desktop emitted message.complete")
        var completedEvent: HermesDesktopGatewayEvent?
        let observerID = client.observeEvents { event in
            guard event.type == "message.complete" else { return }
            completedEvent = event
            completed.fulfill()
        }
        defer { client.removeEventObserver(observerID) }

        let profiles = try await client.listProfiles(includeSessions: true)
        XCTAssertEqual(profiles.map(\.name), ["default", "research", "qa"])
        XCTAssertTrue(profiles[0].isDefault)
        XCTAssertEqual(profiles[0].lastSession?.resolvedID, "release-session-tip")

        let session = try await client.createSession(profile: "research", title: "Mobile gateway proof")
        XCTAssertEqual(session.runtimeSessionID, "runtime-mobile-ci")
        XCTAssertEqual(session.storedSessionID, "stored-mobile-ci")
        XCTAssertEqual(session.model, "gpt-5.6-terra")

        try await client.submitPrompt(
            sessionID: session.runtimeSessionID,
            text: "Reply with the Hermes mobile gateway receipt"
        )
        await fulfillment(of: [completed], timeout: 5)

        XCTAssertEqual(completedEvent?.sessionID, session.runtimeSessionID)
        XCTAssertEqual(completedEvent?.profile, "research")
        XCTAssertEqual(
            completedEvent?.payload["content"],
            .string("Hermes mobile gateway verified.")
        )
        XCTAssertEqual(
            completedEvent?.payload["echo"],
            .string("Reply with the Hermes mobile gateway receipt")
        )
    }
}

private final class HermesGatewayFixtureTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
#if HERMES_GATEWAY_CI
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1",
           challenge.protectionSpace.port == 18_791,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
#endif
        completionHandler(.performDefaultHandling, nil)
    }
}

private final class MockHermesDesktopWebSocketTask: HermesDesktopWebSocketTask, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var receivers: [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] = []
    private var sent: [URLSessionWebSocketTask.Message] = []

    func resume() {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let waiting = lock.withLock { () -> [CheckedContinuation<URLSessionWebSocketTask.Message, Error>] in
            defer { receivers.removeAll() }
            return receivers
        }
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { sent.append(message) }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<URLSessionWebSocketTask.Message, Error>? in
                if !queued.isEmpty {
                    return queued.removeFirst()
                }
                receivers.append(continuation)
                return nil
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }

    func enqueue(_ text: String) {
        let waiting = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            if !receivers.isEmpty {
                return receivers.removeFirst()
            }
            queued.append(.success(.string(text)))
            return nil
        }
        waiting?.resume(returning: .string(text))
    }

    func waitForSentMessageCount(_ expected: Int) async throws {
        for _ in 0..<200 {
            if lock.withLock({ sent.count >= expected }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HermesDesktopGatewayError.invalidResponse(
            "timed out waiting for \(expected) sent WebSocket messages"
        )
    }

    func sentRequestID(at index: Int) -> Int? {
        (try? sentJSON(at: index)["id"]) as? Int
    }

    func sentJSON(at index: Int) throws -> [String: Any] {
        let message = try lock.withLock { () throws -> URLSessionWebSocketTask.Message in
            guard sent.indices.contains(index) else {
                throw HermesDesktopGatewayError.invalidResponse("missing sent message")
            }
            return sent[index]
        }

        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw HermesDesktopGatewayError.invalidResponse("unsupported sent message")
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
