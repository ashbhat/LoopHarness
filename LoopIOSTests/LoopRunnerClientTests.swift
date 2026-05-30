//
//  LoopRunnerClientTests.swift
//  LoopIOSTests
//
//  Unit tests for LoopRunnerClient. Uses a mock URLProtocol to intercept
//  network calls so tests run without a live server.
//

import XCTest
@testable import Loop

// MARK: - Mock URLProtocol

private class MockURLProtocol: URLProtocol {

    /// Handler set by each test to return canned responses.
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("MockURLProtocol handler not set")
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

// MARK: - Tests

final class LoopRunnerClientTests: XCTestCase {

    private var client: LoopRunnerClient!
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        client = LoopRunnerClient(
            baseURL: URL(string: "https://runner.example.com:8080")!,
            sharedSecret: "test-secret",
            session: session
        )
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Authorization header

    func testAuthorizationHeaderIsSent() async throws {
        MockURLProtocol.requestHandler = { request in
            let auth = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertEqual(auth, "Bearer test-secret")
            let json = """
            {"status": "ok"}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }
        _ = try await client.checkHealth()
    }

    // MARK: - Health check

    func testCheckHealthSuccess() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/health"))
            let json = #"{"status": "ok"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }
        let health = try await client.checkHealth()
        XCTAssertEqual(health.status, "ok")
    }

    func testCheckHealthHTTPError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 503,
                httpVersion: nil, headerFields: nil
            )!
            return (response, Data())
        }
        do {
            _ = try await client.checkHealth()
            XCTFail("Expected error")
        } catch let error as RunnerError {
            if case .httpError(let code) = error {
                XCTAssertEqual(code, 503)
            } else {
                XCTFail("Wrong error type")
            }
        }
    }

    // MARK: - Poll turns

    func testPollTurnsDecodesCorrectly() async throws {
        let json = """
        {
            "turns": [
                {
                    "id": "t-1",
                    "status": "completed",
                    "final_response": "Hello world",
                    "error": null,
                    "created_at": "2026-01-01T00:00:00Z",
                    "updated_at": "2026-01-01T00:01:00Z"
                },
                {
                    "id": "t-2",
                    "status": "running",
                    "final_response": null,
                    "error": null,
                    "created_at": "2026-01-01T00:02:00Z",
                    "updated_at": "2026-01-01T00:02:30Z"
                }
            ],
            "server_time": "2026-01-01T00:03:00Z"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("/turns"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        let result = try await client.pollTurns(since: Date.distantPast)
        XCTAssertEqual(result.turns.count, 2)
        XCTAssertEqual(result.turns[0].id, "t-1")
        XCTAssertTrue(result.turns[0].isCompleted)
        XCTAssertEqual(result.turns[0].finalResponse, "Hello world")
        XCTAssertFalse(result.turns[1].isCompleted)
    }

    // MARK: - Poll jobs

    func testPollJobsDecodesCorrectly() async throws {
        let json = """
        {
            "jobs": [
                {
                    "id": "j-1",
                    "turn_id": "t-1",
                    "status": "completed",
                    "result": "Done",
                    "error": null,
                    "created_at": "2026-01-01T00:00:00Z",
                    "updated_at": "2026-01-01T00:01:00Z"
                }
            ],
            "server_time": "2026-01-01T00:03:00Z"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        let result = try await client.pollJobs(since: Date.distantPast)
        XCTAssertEqual(result.jobs.count, 1)
        XCTAssertEqual(result.jobs[0].id, "j-1")
        XCTAssertEqual(result.jobs[0].turnId, "t-1")
        XCTAssertTrue(result.jobs[0].isCompleted)
    }

    // MARK: - Get single turn

    func testGetTurnDecodesCorrectly() async throws {
        let json = """
        {
            "id": "t-42",
            "status": "error",
            "final_response": null,
            "error": "timeout",
            "created_at": "2026-01-01T00:00:00Z",
            "updated_at": "2026-01-01T00:01:00Z"
        }
        """.data(using: .utf8)!

        MockURLProtocol.requestHandler = { request in
            XCTAssertTrue(request.url!.path.contains("/turn/t-42"))
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil
            )!
            return (response, json)
        }

        let turn = try await client.getTurn(id: "t-42")
        XCTAssertEqual(turn.id, "t-42")
        XCTAssertEqual(turn.status, "error")
        XCTAssertTrue(turn.isCompleted)
        XCTAssertEqual(turn.error, "timeout")
    }

    // MARK: - RunnerTurn model

    func testRunnerTurnCompletedStatuses() {
        let completed = RunnerTurn(
            id: "1", status: "completed", finalResponse: "ok",
            error: nil,
            createdAt: Date(), updatedAt: Date()
        )
        XCTAssertTrue(completed.isCompleted)

        let errored = RunnerTurn(
            id: "2", status: "error", finalResponse: nil,
            error: "fail",
            createdAt: Date(), updatedAt: Date()
        )
        XCTAssertTrue(errored.isCompleted)

        let running = RunnerTurn(
            id: "3", status: "running", finalResponse: nil,
            error: nil,
            createdAt: Date(), updatedAt: Date()
        )
        XCTAssertFalse(running.isCompleted)
    }
}
