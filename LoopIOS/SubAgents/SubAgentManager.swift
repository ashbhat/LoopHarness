//
//  SubAgentManager.swift
//  Loop
//
//  Singleton registry + lifecycle controller for sub-agents. Spawns runtimes,
//  tracks state, broadcasts changes to the UI, and posts completion messages
//  back into the parent conversation. Cross-platform — shared between iOS
//  and Mac.
//

import Foundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// NotificationCenter name fired whenever the sub-agent collection changes
/// in a way that the UI might care about (spawn, state change, log append,
/// completion, kill). The status bar + inspector observe this; userInfo is
/// empty since observers re-read `SubAgentManager.shared.allAgents`.
extension Notification.Name {
    static let subAgentsDidChange = Notification.Name("loop.subAgents.didChange")
}

final class SubAgentManager {
    static let shared = SubAgentManager()

    private(set) var agents: [SubAgent] = []
    /// Serial queue so multiple in-flight callbacks don't race on the
    /// agents array. All mutations + notification posts happen on this
    /// queue then hop to main for the broadcast.
    private let queue = DispatchQueue(label: "loop.subagents.manager")

    private init() {
        #if os(iOS)
        // When iOS backgrounds the app, request extra runtime to let any
        // in-flight sub-agents wrap up. Best-effort — iOS gives us ~30s.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        #endif
        // Devin + Cursor jobs are tracked by their own services, but the chat
        // pill is unified — rebroadcast their change notifications under our
        // own name so pills (and any other observers of `.subAgentsDidChange`)
        // refresh whenever a remote agent's state moves.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteJobsDidChange),
            name: .devinAgentsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteJobsDidChange),
            name: .cursorAgentsDidChange,
            object: nil
        )
    }

    @objc private func remoteJobsDidChange() {
        broadcast()
    }

    // MARK: - Public API

    /// Snapshot of currently-tracked agents. Returns alive agents first,
    /// most-recently-started first within each bucket. The UI binds against
    /// this; the array is recomputed every read so observers don't capture
    /// stale references.
    var allAgents: [SubAgent] {
        return queue.sync {
            let alive = agents.filter { $0.isAlive }.sorted { $0.startedAt > $1.startedAt }
            let done = agents.filter { !$0.isAlive }.sorted {
                ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt)
            }
            return alive + done
        }
    }

    /// Just the agents that are still doing work. Status-bar count uses this.
    /// Pass a `conversationId` to scope the result to a single conversation —
    /// the chat pill uses this so switching tabs only shows agents that were
    /// spawned from the current thread.
    func liveAgents(for conversationId: String? = nil) -> [SubAgent] {
        return queue.sync {
            return agents
                .filter { $0.isAlive }
                .filter { conversationId == nil || $0.parentConversationId == conversationId }
                .sorted { $0.startedAt > $1.startedAt }
        }
    }

    /// Back-compat shim — unscoped live list. Some call sites (background-
    /// task budget, manager-internal) genuinely want every agent regardless
    /// of conversation.
    var liveAgents: [SubAgent] { return liveAgents(for: nil) }

    /// Agents that have finished — either successfully (.completed) or via
    /// failure (.failed). Treated as one bucket by the status pill so the
    /// user has a single "done" tally to glance at; `clear()` from the
    /// inspector empties them. Scoped to a conversation when an id is given.
    func finishedAgents(for conversationId: String? = nil) -> [SubAgent] {
        return queue.sync {
            return agents
                .filter { !$0.isAlive }
                .filter { conversationId == nil || $0.parentConversationId == conversationId }
                .sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
        }
    }

    var finishedAgents: [SubAgent] { return finishedAgents(for: nil) }

    /// Status-pill label assembled from current counts. Empty string means
    /// "no agents to show — hide the pill." Centralized here so iOS and Mac
    /// pills stay phrased identically. Examples:
    ///   - 1 running, 0 done → "1 sub-agent running"
    ///   - 0 running, 2 done → "2 sub-agents completed"
    ///   - 1 running, 1 done → "1 sub-agent running, 1 completed"
    /// Pass a `conversationId` to scope the summary to one conversation; the
    /// chat pill always does, so switching tabs flips the count to that
    /// thread's own agents.
    ///
    /// The "running" count is the *aggregate* across native sub-agents,
    /// dispatched Devin sessions, and dispatched Cursor agents so the pill
    /// reflects all three in one glance. The "completed" count stays scoped to
    /// native sub-agents only — Devin/Cursor jobs persist forever in
    /// UserDefaults and don't auto-clear, so including them would have the
    /// pill say "37 completed" the moment you've ever used Devin a few times.
    func pillSummary(for conversationId: String? = nil) -> String {
        let running = aggregateLiveCount(for: conversationId)
        let done = finishedAgents(for: conversationId).count
        // Use "agent" instead of "sub-agent" when the running count includes
        // cloud agents (Devin/Cursor) so the pill label is accurate.
        let hasCloud = cloudLiveCount(for: conversationId) > 0
        let noun = hasCloud ? "agent" : "sub-agent"
        let nounPlural = hasCloud ? "agents" : "sub-agents"
        switch (running, done) {
        case (0, 0):
            return ""
        case (let r, 0):
            let suffix = r == 1 ? "\(noun) running" : "\(nounPlural) running"
            return "\(r) \(suffix)"
        case (0, let d):
            let suffix = d == 1 ? "sub-agent completed" : "sub-agents completed"
            return "\(d) \(suffix)"
        case (let r, let d):
            let runSuffix = r == 1 ? "\(noun) running" : "\(nounPlural) running"
            return "\(r) \(runSuffix), \(d) completed"
        }
    }

    var pillSummary: String { return pillSummary(for: nil) }

    // MARK: - Aggregate (native + Devin + Cursor)
    //
    // The chat pill is a single surface for *anything* working on the user's
    // behalf — native sub-agents and the two cloud agent integrations. These
    // helpers union the three sources so pill color/visibility logic doesn't
    // have to know about each service's persistence layer.

    /// Total in-flight count: alive native sub-agents + non-terminal Devin
    /// sessions + non-terminal Cursor agents matching the conversation. Pass
    /// `nil` to count across all conversations.
    func aggregateLiveCount(for conversationId: String? = nil) -> Int {
        let native = liveAgents(for: conversationId).count
        let devin = DevinAgentService.shared.allJobs().filter { job in
            !job.isTerminal && matches(conversationId, candidate: job.conversationId)
        }.count
        let cursor = CursorAgentService.shared.allJobs().filter { job in
            !job.isTerminal && matches(conversationId, candidate: job.conversationId)
        }.count
        return native + devin + cursor
    }

    /// True if anything in the union is in an "actively making progress" state
    /// (as opposed to merely sleeping). Drives the green-vs-yellow pill dot.
    /// Native sub-agents distinguish `.active` from `.sleeping`; Devin/Cursor
    /// have no sleeping concept so any non-terminal job counts as active.
    func aggregateHasActive(for conversationId: String? = nil) -> Bool {
        if liveAgents(for: conversationId).contains(where: { $0.state == .active }) {
            return true
        }
        if DevinAgentService.shared.allJobs().contains(where: { job in
            !job.isTerminal && matches(conversationId, candidate: job.conversationId)
        }) { return true }
        if CursorAgentService.shared.allJobs().contains(where: { job in
            !job.isTerminal && matches(conversationId, candidate: job.conversationId)
        }) { return true }
        return false
    }

    /// Count of non-terminal cloud agents (Devin + Cursor) only, excluding
    /// native sub-agents. Used by `pillSummary` to decide noun phrasing.
    func cloudLiveCount(for conversationId: String? = nil) -> Int {
        let devin = DevinAgentService.shared.allJobs().filter { job in
            !job.isTerminal && matches(conversationId, candidate: job.conversationId)
        }.count
        let cursor = CursorAgentService.shared.allJobs().filter { job in
            !job.isTerminal && matches(conversationId, candidate: job.conversationId)
        }.count
        return devin + cursor
    }

    /// Conversation scoping rule shared by the aggregate helpers: a nil filter
    /// means "match every conversation"; otherwise the job's conversationId
    /// must equal the filter. Mirrors `liveAgents(for:)`'s semantics.
    private func matches(_ filter: String?, candidate: String) -> Bool {
        guard let filter else { return true }
        return candidate == filter
    }

    /// Spawn a new sub-agent for a given task. The agent starts immediately
    /// in `.active` state and begins making model calls on a background
    /// queue. Returns the SubAgent so the caller can capture its id (used
    /// by `spawn_sub_agent` to put the id in the tool result for the parent
    /// conversation to reference).
    @discardableResult
    func spawn(task: String,
               kind: SubAgentKind,
               parentConversationId: String) -> SubAgent {
        let agent = SubAgent(parentConversationId: parentConversationId,
                             task: task,
                             kind: kind,
                             initialStep: "Reading the task")
        queue.sync {
            agents.append(agent)
        }
        broadcast()

        // Kick off execution on the runtime. The runtime captures the
        // agent reference and drives it through model calls + tool
        // dispatch. We use Task so the work survives the spawning call
        // returning.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await SubAgentRuntime.run(agent: agent,
                                      onUpdate: { [weak self] in self?.broadcast() },
                                      onComplete: { [weak self] in self?.broadcast() })
            // After the runtime finishes, post the completion message into
            // the parent conversation (if any). Done here, not inside the
            // runtime, so the manager owns the parent-conversation contract.
            self.postCompletionMessage(for: agent)
        }
        return agent
    }

    /// Stop a running sub-agent. Marks it `.failed` with an explicit reason
    /// and leaves it in the list so the user can review what happened. The
    /// runtime checks `agent.state == .failed` between turns and bails.
    func kill(id: String, reason: String = "Stopped by user") {
        var killed: SubAgent?
        queue.sync {
            if let agent = agents.first(where: { $0.id == id }), agent.isAlive {
                agent.state = .failed
                agent.error = reason
                agent.currentStep = reason
                agent.finishedAt = Date()
                agent.appendLog(SubAgentLogEntry(kind: .system, summary: reason))
                killed = agent
            }
        }
        if killed != nil {
            broadcast()
        }
    }

    /// Drop completed/failed agents from the in-memory list. The UI may
    /// expose this as a "Clear finished" action in the inspector.
    func clearFinished() {
        queue.sync {
            agents.removeAll { !$0.isAlive }
        }
        broadcast()
    }

    /// Remove a single agent (alive or not) from the list. Used by swipe-
    /// to-dismiss on completed entries. If the agent is still alive this
    /// also marks it failed first so the runtime aborts cleanly.
    func remove(id: String) {
        queue.sync {
            if let agent = agents.first(where: { $0.id == id }), agent.isAlive {
                agent.state = .failed
                agent.error = "Removed by user"
                agent.finishedAt = Date()
            }
            agents.removeAll { $0.id == id }
        }
        broadcast()
    }

    /// Look up an agent by id without taking a snapshot of the whole list.
    /// The inspector detail view uses this when the user taps a row.
    func agent(id: String) -> SubAgent? {
        return queue.sync { agents.first(where: { $0.id == id }) }
    }

    // MARK: - Runtime → manager hooks
    //
    // The runtime calls these to mutate agent state without itself needing
    // to know about the broadcast channel. Kept on the manager so all
    // mutations route through the same queue.

    func updateState(id: String, to state: SubAgentState, step: String? = nil) {
        queue.sync {
            guard let agent = agents.first(where: { $0.id == id }) else { return }
            agent.state = state
            if let step = step { agent.currentStep = step }
            if !agent.isAlive && agent.finishedAt == nil {
                agent.finishedAt = Date()
            }
        }
        broadcast()
    }

    func appendLog(id: String, entry: SubAgentLogEntry) {
        var agentTitle: String?
        queue.sync {
            guard let agent = agents.first(where: { $0.id == id }) else { return }
            agent.appendLog(entry)
            agentTitle = agent.displayTitle
        }
        // Mirror into the global activity log so the large-mode AgentView can
        // show "this sub-agent just did X" alongside the primary agent's own
        // tool calls. We only mirror the user-facing kinds (tool calls + plain
        // thoughts); system / state-transition entries would be too chatty.
        if let title = agentTitle {
            switch entry.kind {
            case .toolCall, .thought:
                AgentActivityLog.shared.log(
                    .subAgent,
                    "\(title.prefix(24))… \(entry.summary)",
                    detail: entry.detail
                )
            case .toolResult, .system:
                break
            }
        }
        broadcast()
    }

    func setResult(id: String, summary: String) {
        queue.sync {
            guard let agent = agents.first(where: { $0.id == id }) else { return }
            agent.result = summary
        }
    }

    func setError(id: String, message: String) {
        queue.sync {
            guard let agent = agents.first(where: { $0.id == id }) else { return }
            agent.error = message
        }
    }

    // MARK: - Broadcast

    private func broadcast() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .subAgentsDidChange, object: nil)
        }
    }

    // MARK: - Parent conversation hand-off

    /// Append a function-result-style summary message into the parent
    /// conversation so the primary thread shows what the sub-agent
    /// accomplished. Called by the manager after the runtime finishes.
    ///
    /// Resilience: if the agent's `parentConversationId` no longer exists
    /// (renamed/deleted between spawn and completion, or was empty because
    /// the Mac coordinator hadn't set `currentConversation` at spawn time),
    /// fall back to the current/last conversation so the user never silently
    /// loses a sub-agent's output.
    private func postCompletionMessage(for agent: SubAgent) {
        let manager = SimpleConversationManager.shared
        let conversations = manager.getAllConversations()
        let parent: SimpleConversation? = {
            if let exact = conversations.first(where: { $0.id == agent.parentConversationId }) {
                return exact
            }
            if let current = manager.currentConversation { return current }
            return manager.loadLastConversation()
        }()
        guard let parent = parent else {
            print("⚠️ Sub-agent \(agent.id) completed but no conversation to post to — result dropped.")
            return
        }

        let body = formatCompletionBody(for: agent)
        // Roll it in as an assistant message so the bubble renders like any
        // other Loop reply. (A `function`-role message would be hidden in
        // some UIs.) Tag the model name so the user can see at a glance it
        // came from a sub-agent.
        let modelTag = "Sub-agent · \(agent.kind.rawValue)"
        var msg = MessageStruct(role: "assistant", content: body, model: modelTag)
        msg.name = "sub_agent_\(agent.id.prefix(8))"
        SimpleConversationManager.shared.addMessage(msg, to: parent)

        // Fire a separate notification so the active chat view can refresh
        // and append the row even if the user has the conversation open.
        // Note: we publish `parent.id` (the conversation we actually wrote
        // to) rather than the agent's stored `parentConversationId`, which
        // may have been empty if the spawning context didn't have a current
        // conversation set yet.
        let postedConversationId = parent.id
        // Include just the substantive result (no "✅ Sub-agent finished…"
        // header) so the chat view can read the body aloud without making
        // the user listen to status decoration. Falls back to empty when
        // the agent had nothing to report.
        let spokenSummary = (agent.result ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .subAgentDidPostMessage,
                object: nil,
                userInfo: [
                    "conversationId": postedConversationId,
                    "messageId": msg.id,
                    "summary": spokenSummary,
                ]
            )
        }

        // If the app is backgrounded (iOS) or otherwise inactive, surface a
        // local notification so the user knows the agent finished.
        deliverNotificationIfNeeded(for: agent)
    }

    private func formatCompletionBody(for agent: SubAgent) -> String {
        let header: String
        switch agent.state {
        case .completed:
            header = "✅ Sub-agent finished: \(agent.displayTitle)"
        case .failed:
            header = "⚠️ Sub-agent failed: \(agent.displayTitle)"
        default:
            header = "Sub-agent ended: \(agent.displayTitle)"
        }
        var sections: [String] = [header]
        if let result = agent.result, !result.isEmpty {
            sections.append(result)
        }
        if let error = agent.error, !error.isEmpty, agent.state == .failed {
            sections.append("Error: \(error)")
        }
        return sections.joined(separator: "\n\n")
    }

    private func deliverNotificationIfNeeded(for agent: SubAgent) {
        #if os(iOS)
        DispatchQueue.main.async {
            let appActive = UIApplication.shared.applicationState == .active
            guard !appActive else { return }
            SubAgentNotifications.deliver(for: agent)
        }
        #elseif os(macOS)
        DispatchQueue.main.async {
            let appActive = NSApplication.shared.isActive
            guard !appActive else { return }
            SubAgentNotifications.deliver(for: agent)
        }
        #endif
    }

    #if os(iOS)
    @objc private func appWillResignActive() {
        // Best-effort: request background time so in-flight sub-agents have
        // a chance to wrap up. iOS will reclaim after ~30s if we don't end
        // the task; we end it as soon as everything is .completed/.failed.
        guard !liveAgents.isEmpty else { return }
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask(withName: "loop.subagents") {
            UIApplication.shared.endBackgroundTask(taskId)
            taskId = .invalid
        }
        // Poll for liveness on a low-priority queue and release the task once
        // everything has settled. 1s cadence is plenty given a 30s budget.
        DispatchQueue.global(qos: .background).async { [weak self] in
            while let self = self, !self.liveAgents.isEmpty {
                Thread.sleep(forTimeInterval: 1.0)
            }
            DispatchQueue.main.async {
                if taskId != .invalid {
                    UIApplication.shared.endBackgroundTask(taskId)
                }
            }
        }
    }
    #endif
}

/// Posted (in addition to `subAgentsDidChange`) when a completion message has
/// been written into the parent conversation, so chat views can append a
/// bubble in real time instead of waiting for the next reload.
extension Notification.Name {
    static let subAgentDidPostMessage = Notification.Name("loop.subAgents.didPostMessage")
}
