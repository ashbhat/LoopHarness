//
//  CursorAgentService.swift
//  Loop
//
//  Long-running engine behind `CursorSkill`. Dispatches a coding task to
//  Cursor's hosted Cloud/Background Agents API (which runs autonomously and
//  opens a pull request on GitHub), persists the dispatched agent so it
//  survives relaunch, polls it to completion, and posts the PR link / outcome
//  back into the originating conversation.
//
//  Patterns reused (not reinvented):
//   - Persistence: `[CursorAgentJob]` JSON in UserDefaults — same shape as
//     BackgroundScheduler.loadJobs/saveJobs.
//   - Long-running work without BGProcessingTask: an in-process
//     DispatchSourceTimer + `beginBackgroundTask` grace on iOS + resume on
//     launch — same model as SubAgentManager (no new BG identifier / Info.plist
//     change). Completion for an agent that finishes while the app is dead is
//     delivered on the next launch via `resumePending()`.
//   - Post-back: locate the parent conversation via SimpleConversationManager
//     and append an assistant message — the exact hand-off
//     SubAgentManager.postCompletionMessage uses.
//
//  All Cursor wire details (base URL, API version path, auth scheme, request
//  body shape, response field names) are deliberately centralized in the
//  `CursorAPI` enum below. Public Cursor docs show version/auth drift
//  (`/v0` vs `/v1`, Bearer vs Basic) and don't crisply document where the PR
//  URL lands — pin those here against live docs; it's the only file to touch.
//

import Foundation
import UserNotifications
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Posted after a Cursor completion message is written into a conversation so
/// an open chat view can refresh in place. Mirrors `.subAgentDidPostMessage`;
/// MessagingVC routes both at the same `handleSubAgentMessage` handler (it
/// only reads `conversationId` from userInfo).
extension Notification.Name {
    static let cursorAgentDidPostMessage = Notification.Name("loop.cursor.didPostMessage")
    /// Posted whenever a tracked Cursor job's persisted state changes (status,
    /// PR url, terminal). The chat sub-agent pill listens to this so a Cursor
    /// dispatch flips the running count immediately instead of after the next
    /// post-back. Mirrors `.devinAgentsDidChange`.
    static let cursorAgentsDidChange = Notification.Name("loop.cursor.didChange")
}

/// One dispatched Cursor agent we're tracking through to its PR.
struct CursorAgentJob: Codable {
    var agentId: String
    var runId: String?
    var repository: String
    var task: String
    /// Conversation to post the outcome back into. May be "" — the post-back
    /// resolves a sensible fallback the same way SubAgentManager does.
    var conversationId: String
    var createdAt: Date
    /// Normalized lifecycle: "running" until a terminal value
    /// ("finished" | "cancelled" | "error" | "stale").
    var status: String
    var prURL: String?
    var dashboardURL: String?
    var lastPolledAt: Date?
    /// Set once the completion message has been written, so a relaunch can't
    /// double-post.
    var postedBack: Bool

    static let terminal: Set<String> = ["finished", "cancelled", "error", "stale"]
    var isTerminal: Bool { CursorAgentJob.terminal.contains(status) }
}

final class CursorAgentService {

    static let shared = CursorAgentService()

    // MARK: - Cursor API surface (the single place to pin on drift)

    private enum CursorAPI {
        static let base = "https://api.cursor.com"
        /// `/v0/agents` per the "Launch an Agent" reference. Newer docs show
        /// `/v1/agents`; flip here if the account is on v1.
        static let agentsPath = "/v0/agents"

        static func authHeader(_ key: String) -> (String, String) {
            // "Launch an Agent" uses Bearer; some pages show Basic
            // (`-u KEY:`). Flip here if needed.
            return ("Authorization", "Bearer \(key)")
        }

        /// Request body for launch. `source.repository` + `source.ref` per the
        /// "Launch an Agent" reference; `target.autoCreatePr` toggles the PR.
        static func launchBody(task: String,
                               repository: String,
                               ref: String?,
                               autoCreatePR: Bool) -> [String: Any] {
            var source: [String: Any] = ["repository": repository]
            if let ref = ref, !ref.isEmpty { source["ref"] = ref }
            return [
                "prompt": ["text": task],
                "source": source,
                "target": ["autoCreatePr": autoCreatePR],
            ]
        }
    }

    /// Stop polling a job that never finishes so the timer can't run forever.
    private static let maxLifetime: TimeInterval = 6 * 60 * 60
    private static let pollInterval: TimeInterval = 20

    private let jobsKey = "loop.cursor.jobs"
    /// Serializes job-array mutations + timer lifecycle.
    private let queue = DispatchQueue(label: "loop.cursor.service")
    private var pollTimer: DispatchSourceTimer?

    private init() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        #endif
    }

    // MARK: - Persistence (mirrors BackgroundScheduler)

    func loadJobs() -> [CursorAgentJob] {
        guard let data = UserDefaults.standard.data(forKey: jobsKey) else { return [] }
        return (try? JSONDecoder().decode([CursorAgentJob].self, from: data)) ?? []
    }

    private func saveJobs(_ jobs: [CursorAgentJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: jobsKey)
    }

    private func upsert(_ job: CursorAgentJob) {
        queue.sync {
            var jobs = loadJobs()
            if let idx = jobs.firstIndex(where: { $0.agentId == job.agentId }) {
                jobs[idx] = job
            } else {
                jobs.append(job)
            }
            saveJobs(jobs)
        }
        // Pill + subagents window listen to this so a dispatch flips counts
        // immediately. Mirrors DevinAgentService.upsert.
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cursorAgentsDidChange,
                object: nil,
                userInfo: ["agentId": job.agentId])
        }
    }

    func job(forAgentId id: String) -> CursorAgentJob? {
        return loadJobs().first { $0.agentId == id }
    }

    /// Most-recent-first listing. Mirrors `DevinAgentService.allJobs()` so the
    /// chat sub-agent pill and any future Cursor settings UI can read the same
    /// shape from either service.
    func allJobs() -> [CursorAgentJob] {
        return loadJobs().sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Dispatch

    enum DispatchResult {
        case success(CursorAgentJob)
        case failure(String)
    }

    /// POST a new agent to Cursor. Surfaces errors (missing key, bad repo,
    /// wrong API version) verbatim — never silently degrades.
    func dispatch(task: String,
                  repository: String,
                  ref: String?,
                  autoCreatePR: Bool,
                  conversationId: String,
                  completion: @escaping (DispatchResult) -> Void) {

        guard let key = KeyStore.shared.value(for: .cursor), !key.isEmpty else {
            completion(.failure("No Cursor key set. Add CURSOR_API_KEY in Settings ▸ Keys."))
            return
        }
        guard let url = URL(string: CursorAPI.base + CursorAPI.agentsPath) else {
            completion(.failure("Bad Cursor API URL."))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (h, v) = CursorAPI.authHeader(key)
        req.setValue(v, forHTTPHeaderField: h)
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: CursorAPI.launchBody(task: task,
                                                 repository: repository,
                                                 ref: ref,
                                                 autoCreatePR: autoCreatePR))
        req.timeoutInterval = 60

        print("CursorAgentService: POST \(url) repo=\(repository)")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                completion(.failure("Network error talking to Cursor: \(error.localizedDescription)"))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure("Cursor returned an unreadable response (HTTP \(code))."))
                return
            }
            if code >= 400 {
                completion(.failure("Cursor API error: \(Self.errorDetail(json) ?? "HTTP \(code)")"))
                return
            }
            // The agent object may be at the top level or nested under
            // "agent" depending on API version.
            let agent = (json["agent"] as? [String: Any]) ?? json
            guard let agentId = (agent["id"] as? String) ?? (json["id"] as? String) else {
                completion(.failure("Cursor response had no agent id."))
                return
            }
            let runId = (json["run"] as? [String: Any])?["id"] as? String
                ?? agent["latestRunId"] as? String
            let job = CursorAgentJob(
                agentId: agentId,
                runId: runId,
                repository: repository,
                task: task,
                conversationId: conversationId,
                createdAt: Date(),
                status: "running",
                prURL: Self.extractPRURL(agent),
                dashboardURL: Self.extractDashboardURL(agent),
                lastPolledAt: nil,
                postedBack: false)
            self.upsert(job)
            self.ensurePolling()
            completion(.success(job))
        }.resume()
    }

    // MARK: - Polling

    /// One-shot status refresh for `cursor_check_agent`. Also updates the
    /// persisted job + triggers post-back if it just went terminal.
    func refresh(agentId: String, completion: @escaping (CursorAgentJob?) -> Void) {
        guard var job = job(forAgentId: agentId) else { completion(nil); return }
        pollJob(job) { updated in
            job = updated ?? job
            completion(job)
        }
    }

    /// Start the shared poll timer if there's anything non-terminal to watch.
    func ensurePolling() {
        queue.sync {
            guard pollTimer == nil else { return }
            guard loadJobs().contains(where: { !$0.isTerminal }) else { return }
            let timer = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "loop.cursor.poll", qos: .utility))
            timer.schedule(deadline: .now() + Self.pollInterval,
                           repeating: Self.pollInterval)
            timer.setEventHandler { [weak self] in self?.pollCycle() }
            pollTimer = timer
            timer.resume()
        }
    }

    private func stopPolling() {
        queue.sync {
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    private func pollCycle() {
        let pending = loadJobs().filter { !$0.isTerminal }
        if pending.isEmpty { stopPolling(); return }
        for job in pending {
            // Lifetime bound — give up gracefully instead of polling forever.
            if Date().timeIntervalSince(job.createdAt) > Self.maxLifetime {
                var stale = job
                stale.status = "stale"
                finish(stale)
                continue
            }
            pollJob(job, completion: { _ in })
        }
    }

    private func pollJob(_ job: CursorAgentJob,
                         completion: @escaping (CursorAgentJob?) -> Void) {
        guard let key = KeyStore.shared.value(for: .cursor), !key.isEmpty,
              let url = URL(string: CursorAPI.base + CursorAPI.agentsPath + "/" + job.agentId) else {
            completion(nil); return
        }
        var req = URLRequest(url: url)
        let (h, v) = CursorAPI.authHeader(key)
        req.setValue(v, forHTTPHeaderField: h)
        req.timeoutInterval = 30

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self = self else { completion(nil); return }
            guard error == nil,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil); return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Re-read the latest persisted copy so we don't clobber a
            // concurrent update.
            guard var current = self.job(forAgentId: job.agentId) else {
                completion(nil); return
            }
            if code >= 400 {
                current.status = "error"
                current.lastPolledAt = Date()
                self.finish(current)
                completion(current)
                return
            }
            let agent = (json["agent"] as? [String: Any]) ?? json
            current.lastPolledAt = Date()
            current.prURL = Self.extractPRURL(agent) ?? current.prURL
            current.dashboardURL = Self.extractDashboardURL(agent) ?? current.dashboardURL
            current.status = Self.normalizeStatus(agent, fallback: current.status)

            if current.isTerminal {
                self.finish(current)
            } else {
                self.upsert(current)
            }
            completion(current)
        }.resume()
    }

    /// Mark a job terminal, persist, and post the outcome back exactly once.
    private func finish(_ job: CursorAgentJob) {
        var done = job
        if !CursorAgentJob.terminal.contains(done.status) { done.status = "finished" }
        upsert(done)
        guard !done.postedBack else { return }
        postCompletion(for: done)
        var marked = done
        marked.postedBack = true
        upsert(marked)
        if !loadJobs().contains(where: { !$0.isTerminal }) { stopPolling() }
    }

    // MARK: - Resume on launch

    /// Called once at launch (AgentHarness bootstrap). Re-arms polling for
    /// anything unfinished, and flushes any job that went terminal while the
    /// app was dead but never got its message posted.
    func resumePending() {
        for job in loadJobs() where job.isTerminal && !job.postedBack {
            finish(job)
        }
        ensurePolling()
    }

    // MARK: - Post-back (mirrors SubAgentManager.postCompletionMessage)

    private func postCompletion(for job: CursorAgentJob) {
        let manager = SimpleConversationManager.shared
        let conversations = manager.getAllConversations()
        let parent: SimpleConversation? = {
            if let exact = conversations.first(where: { $0.id == job.conversationId }) {
                return exact
            }
            if let current = manager.currentConversation { return current }
            return manager.loadLastConversation()
        }()
        guard let parent = parent else {
            print("⚠️ Cursor agent \(job.agentId) finished but no conversation to post to — dropped.")
            return
        }

        var msg = MessageStruct(role: "assistant",
                                content: Self.completionBody(for: job),
                                model: "Cursor · \(Self.repoShortName(job.repository))")
        msg.name = "cursor_agent_\(job.agentId.prefix(8))"
        manager.addMessage(msg, to: parent)

        let postedId = parent.id
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .cursorAgentDidPostMessage,
                object: nil,
                userInfo: ["conversationId": postedId, "messageId": msg.id])
        }
        deliverNotificationIfNeeded(for: job)
    }

    private static func completionBody(for job: CursorAgentJob) -> String {
        let repo = repoShortName(job.repository)
        switch job.status {
        case "finished":
            if let pr = job.prURL {
                return "✅ Cursor finished `\(repo)` — PR: \(pr)"
            }
            let where_ = job.dashboardURL.map { " View it: \($0)" } ?? ""
            return "✅ Cursor finished `\(repo)`. No PR URL was reported yet (it may still be opening on GitHub).\(where_)"
        case "cancelled":
            return "🚫 Cursor agent for `\(repo)` was cancelled."
        case "stale":
            let where_ = job.dashboardURL.map { " Check it: \($0)" } ?? ""
            return "⌛️ Still waiting on the Cursor agent for `\(repo)` after a while — I've stopped tracking it here.\(where_)"
        default:
            return "❌ Cursor agent for `\(repo)` ended with an error."
        }
    }

    private func deliverNotificationIfNeeded(for job: CursorAgentJob) {
        #if os(iOS)
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }
            CursorAgentService.deliverLocalNotification(for: job)
        }
        #elseif os(macOS)
        DispatchQueue.main.async {
            guard !NSApplication.shared.isActive else { return }
            CursorAgentService.deliverLocalNotification(for: job)
        }
        #endif
    }

    private static func deliverLocalNotification(for job: CursorAgentJob) {
        let content = UNMutableNotificationContent()
        content.title = "Cursor · \(repoShortName(job.repository))"
        content.body = completionBody(for: job)
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "loop.cursor.\(job.agentId)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    #if os(iOS)
    @objc private func appWillResignActive() {
        guard loadJobs().contains(where: { !$0.isTerminal }) else { return }
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "loop.cursor.poll") {
            UIApplication.shared.endBackgroundTask(taskId)
            taskId = .invalid
        }
        DispatchQueue.global(qos: .background).async { [weak self] in
            while let self = self,
                  self.loadJobs().contains(where: { !$0.isTerminal }) {
                Thread.sleep(forTimeInterval: 2.0)
            }
            DispatchQueue.main.async {
                if taskId != .invalid { UIApplication.shared.endBackgroundTask(taskId) }
            }
        }
    }
    #endif

    // MARK: - Response parsing helpers (defensive — exact fields pinned on drift)

    private static func normalizeStatus(_ agent: [String: Any], fallback: String) -> String {
        // Prefer run-level status when present, else the agent status.
        let raw = ((agent["run"] as? [String: Any])?["status"] as? String)
            ?? (agent["status"] as? String)
            ?? ""
        switch raw.uppercased() {
        case "FINISHED", "COMPLETED", "SUCCEEDED", "DONE":
            return "finished"
        case "CANCELLED", "CANCELED":
            return "cancelled"
        case "ERROR", "FAILED", "EXPIRED":
            return "error"
        case "CREATING", "RUNNING", "PENDING", "QUEUED", "ACTIVE", "":
            return "running"
        default:
            return fallback
        }
    }

    private static func extractPRURL(_ agent: [String: Any]) -> String? {
        if let t = agent["target"] as? [String: Any] {
            if let pr = t["prUrl"] as? String, !pr.isEmpty { return pr }
            if let pr = t["pullRequestUrl"] as? String, !pr.isEmpty { return pr }
        }
        if let pr = agent["prUrl"] as? String, !pr.isEmpty { return pr }
        return nil
    }

    private static func extractDashboardURL(_ agent: [String: Any]) -> String? {
        if let u = agent["url"] as? String, !u.isEmpty { return u }
        if let t = agent["target"] as? [String: Any],
           let u = t["url"] as? String, !u.isEmpty { return u }
        return nil
    }

    private static func errorDetail(_ json: [String: Any]) -> String? {
        if let err = json["error"] as? [String: Any] {
            return (err["message"] as? String) ?? (err["code"] as? String)
        }
        return (json["error"] as? String) ?? (json["message"] as? String)
    }

    static func repoShortName(_ repo: String) -> String {
        let trimmed = repo.hasSuffix("/") ? String(repo.dropLast()) : repo
        let path = URL(string: trimmed)?.path ?? trimmed
        let parts = path.split(separator: "/").suffix(2)
        let name = parts.joined(separator: "/")
        return name.replacingOccurrences(of: ".git", with: "").ifEmpty(trimmed)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
