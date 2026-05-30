//
//  RunnerModels.swift
//  Loop
//
//  Domain models for the Portable Loop Runner integration. These mirror the
//  Go runner's JSON shapes (`GET /turn/:id`, `GET /job/:job_id`,
//  `GET /turns?since=...`, `GET /jobs?since=...`) and the persisted runner
//  configuration stored in the Keychain.
//

import Foundation

// MARK: - Runner configuration (persisted)

/// A single configured Loop Runner instance. Stored as a JSON array in the
/// Keychain under `RunnerStore.service`.
struct RunnerConfig: Codable, Identifiable, Equatable {
    var id: String
    var nickname: String
    var baseURL: String
    /// Keychain account name that holds the shared secret for this runner.
    /// The secret itself lives in a separate Keychain entry so it never
    /// rides serialized JSON.
    var secretRef: String
    var createdAt: Date
    var lastPollTime: Date?
    var lastSeenTurnCount: Int

    init(id: String = UUID().uuidString,
         nickname: String,
         baseURL: String,
         secretRef: String? = nil,
         createdAt: Date = Date(),
         lastPollTime: Date? = nil,
         lastSeenTurnCount: Int = 0) {
        self.id = id
        self.nickname = nickname
        self.baseURL = baseURL
        self.secretRef = secretRef ?? "com.loop.runner.secret.\(id)"
        self.createdAt = createdAt
        self.lastPollTime = lastPollTime
        self.lastSeenTurnCount = lastSeenTurnCount
    }
}

// MARK: - Wire models (runner API responses)

/// A single turn as returned by the runner.
struct RunnerTurn: Codable, Identifiable, Equatable {
    let id: String
    let status: String
    let finalResponse: String?
    let error: String?
    let createdAt: Date
    let updatedAt: Date

    var isCompleted: Bool { status == "completed" || status == "error" }

    enum CodingKeys: String, CodingKey {
        case id
        case status
        case finalResponse = "final_response"
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// A single job as returned by the runner.
struct RunnerJob: Codable, Identifiable, Equatable {
    let id: String
    let turnId: String
    let status: String
    let result: String?
    let error: String?
    let createdAt: Date
    let updatedAt: Date

    var isCompleted: Bool { status == "completed" || status == "error" }

    enum CodingKeys: String, CodingKey {
        case id
        case turnId = "turn_id"
        case status
        case result
        case error
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Batch-poll response wrapper. The runner returns a `server_time` field
/// alongside the items so the client can advance its `since` cursor without
/// clock-skew issues.
struct RunnerTurnsResponse: Codable {
    let turns: [RunnerTurn]
    let serverTime: Date

    enum CodingKeys: String, CodingKey {
        case turns
        case serverTime = "server_time"
    }
}

struct RunnerJobsResponse: Codable {
    let jobs: [RunnerJob]
    let serverTime: Date

    enum CodingKeys: String, CodingKey {
        case jobs
        case serverTime = "server_time"
    }
}

/// Health-check response from `GET /health`.
struct RunnerHealthResponse: Codable {
    let status: String
}
