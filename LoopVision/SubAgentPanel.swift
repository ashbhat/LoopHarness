//
//  SubAgentPanel.swift
//  LoopVision
//
//  The visionOS analog of iPhone's `SubAgentStatusBarView` + `SubAgentInspectorVC`
//  + `DevinAgentDetailVC`. A pill above the conversation transcript shows the
//  running-count summary; tapping it presents a sheet that lists every native
//  sub-agent, dispatched Devin session, and dispatched Cursor agent scoped to
//  the active conversation. Tapping a Devin row drills into a live transcript
//  with "Open in Devin" + "See PR" buttons — same affordances iPhone offers.
//
//  Everything binds on `VisionSession.subAgentTick`, which is bumped whenever
//  any of the three services posts a "did change" notification, so the UI
//  reflects spawn / poll updates without manual reloads.
//

import SwiftUI

// MARK: - Pill

/// Top-of-transcript chip mirroring the iPhone pill: dot + count summary +
/// chevron. Hides itself when no agents are tracked for the scoped conversation.
struct SubAgentPill: View {
    let session: VisionSession
    let conversationId: String?
    let onTap: () -> Void

    var body: some View {
        // Touching subAgentTick establishes an observation dependency so the
        // pill repaints when any of the services posts a change notification.
        let _ = session.subAgentTick
        let summary = SubAgentManager.shared.pillSummary(for: conversationId)
        if summary.isEmpty {
            EmptyView()
        } else {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                    Text(summary)
                        .font(.system(size: 13, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private var dotColor: Color {
        let liveCount = SubAgentManager.shared.aggregateLiveCount(for: conversationId)
        if liveCount == 0 { return .gray }
        if SubAgentManager.shared.aggregateHasActive(for: conversationId) {
            return .green
        }
        return .yellow
    }
}

// MARK: - Inspector sheet

/// Modal sheet shown when the pill is tapped. Two sections — Local Sub-agents
/// and Cloud Agents — mirroring iPhone's `SubAgentInspectorVC`. Selection on a
/// Devin row pushes the live transcript; Cursor opens the PR / dashboard URL.
struct SubAgentInspectorSheet: View {
    let session: VisionSession
    let conversationId: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// SessionId of the Devin job whose detail is pushed. Plain String so it
    /// satisfies `navigationDestination(item:)`'s Hashable constraint without
    /// having to teach `DevinAgentJob` Hashable conformance.
    @State private var devinDetailSessionId: String?

    var body: some View {
        let _ = session.subAgentTick
        NavigationStack {
            List {
                let native = nativeAgents()
                if !native.isEmpty {
                    Section("Local Sub-agents") {
                        ForEach(native, id: \.id) { agent in
                            nativeRow(agent: agent)
                        }
                    }
                }
                let cloud = cloudAgents()
                if !cloud.isEmpty {
                    Section("Cloud Agents") {
                        ForEach(cloud) { row in
                            cloudRow(row: row)
                        }
                    }
                }
                if native.isEmpty && cloud.isEmpty {
                    Section {
                        Text("No agents running.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .navigationTitle("Sub-agents")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $devinDetailSessionId) { id in
                DevinAgentDetailView(sessionId: id)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func nativeRow(agent: SubAgent) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(nativeColor(for: agent.state))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 4) {
                Text(agent.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                if !agent.currentStep.isEmpty {
                    Text(agent.currentStep)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(nativeStateLabel(for: agent.state).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(nativeColor(for: agent.state))
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func cloudRow(row: CloudAgentRow) -> some View {
        Button {
            switch row.kind {
            case .devin(let job):
                devinDetailSessionId = job.sessionId
            case .cursor(let job):
                if let urlString = job.prURL ?? job.dashboardURL,
                   let url = URL(string: urlString) {
                    openURL(url)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(row.statusColor)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.headline)
                        .lineLimit(2)
                    Text(row.providerLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(row.status.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(row.statusColor)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

    private func nativeAgents() -> [SubAgent] {
        return SubAgentManager.shared.liveAgents(for: conversationId)
            + SubAgentManager.shared.finishedAgents(for: conversationId)
    }

    private func cloudAgents() -> [CloudAgentRow] {
        var rows: [CloudAgentRow] = []
        let devinJobs = DevinAgentService.shared.allJobs().filter { job in
            conversationId == nil || job.conversationId == conversationId
        }
        for job in devinJobs where !job.isTerminal {
            rows.append(.init(kind: .devin(job)))
        }
        let cursorJobs = CursorAgentService.shared.allJobs().filter { job in
            conversationId == nil || job.conversationId == conversationId
        }
        for job in cursorJobs where !job.isTerminal {
            rows.append(.init(kind: .cursor(job)))
        }
        for job in devinJobs where job.isTerminal {
            rows.append(.init(kind: .devin(job)))
        }
        for job in cursorJobs where job.isTerminal {
            rows.append(.init(kind: .cursor(job)))
        }
        return rows
    }

    private func nativeStateLabel(for state: SubAgentState) -> String {
        switch state {
        case .active: return "Active"
        case .sleeping: return "Sleeping"
        case .waitingForInput: return "Needs input"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    private func nativeColor(for state: SubAgentState) -> Color {
        switch state {
        case .active: return .green
        case .sleeping: return .yellow
        case .waitingForInput: return .orange
        case .completed: return .gray
        case .failed: return .red
        }
    }
}

// MARK: - Cloud agent row model

/// Lightweight wrapper so the sheet can iterate one heterogeneous list. Mirrors
/// iPhone's private `CloudAgentRow` enum but is `Identifiable` for SwiftUI.
struct CloudAgentRow: Identifiable {
    enum Kind {
        case devin(DevinAgentJob)
        case cursor(CursorAgentJob)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .devin(let job):  return "devin-\(job.sessionId)"
        case .cursor(let job): return "cursor-\(job.agentId)"
        }
    }

    var title: String {
        switch kind {
        case .devin(let job): return job.displayTitle
        case .cursor(let job):
            let trimmed = job.task.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            if trimmed.count <= 80 { return trimmed }
            return String(trimmed.prefix(77)) + "\u{2026}"
        }
    }

    var status: String {
        switch kind {
        case .devin(let job):  return job.status.capitalized
        case .cursor(let job): return job.status.capitalized
        }
    }

    var providerLabel: String {
        switch kind {
        case .devin:  return "Devin"
        case .cursor: return "Cursor"
        }
    }

    var statusColor: Color {
        switch kind {
        case .devin(let job):
            switch job.status {
            case "running":  return .green
            case "blocked":  return .yellow
            case "finished": return .gray
            case "error":    return .red
            default:         return .gray
            }
        case .cursor(let job):
            switch job.status {
            case "running":  return .green
            case "finished": return .gray
            case "error":    return .red
            default:         return .gray
            }
        }
    }
}

// MARK: - Devin detail

/// Live transcript view for one dispatched Devin session — visionOS counterpart
/// to iPhone's `DevinAgentDetailVC`. Boosts the shared poll cadence to 5s while
/// the user is reading it; falls back to the background cadence on disappear.
struct DevinAgentDetailView: View {
    let sessionId: String
    @Environment(\.openURL) private var openURL
    /// SwiftUI re-reads this @State each render; we mutate it on every
    /// `.devinAgentsDidChange` notification so the transcript stays live.
    @State private var job: DevinAgentJob?
    @State private var observerToken: NSObjectProtocol?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            transcript
            footer
        }
        .navigationTitle(job?.displayTitle ?? "Devin Session")
        .onAppear {
            job = DevinAgentService.shared.job(forSessionId: sessionId)
            DevinAgentService.shared.addBoost(sessionId: sessionId)
            observerToken = NotificationCenter.default.addObserver(
                forName: .devinAgentsDidChange,
                object: nil,
                queue: .main
            ) { _ in
                job = DevinAgentService.shared.job(forSessionId: sessionId)
            }
        }
        .onDisappear {
            DevinAgentService.shared.removeBoost(sessionId: sessionId)
            if let token = observerToken {
                NotificationCenter.default.removeObserver(token)
                observerToken = nil
            }
        }
    }

    // MARK: Header

    @ViewBuilder
    private var header: some View {
        if let job = job {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(Self.statusLine(for: job))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let job = job {
                    if job.messages.isEmpty {
                        Text(job.status == "running"
                             ? "Waiting for Devin's first message…"
                             : "No messages.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    } else {
                        ForEach(job.messages) { msg in
                            bubble(for: msg)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func bubble(for msg: DevinTranscriptMessage) -> some View {
        let isUser = msg.type.lowercased().contains("user") ||
                     msg.type.lowercased().contains("human")
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(roleLabel(for: msg))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(msg.message)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(isUser ? AnyShapeStyle(.tint.opacity(0.25))
                                       : AnyShapeStyle(.thinMaterial),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .textSelection(.enabled)
            }
            if !isUser { Spacer(minLength: 60) }
        }
    }

    private func roleLabel(for msg: DevinTranscriptMessage) -> String {
        let lower = msg.type.lowercased()
        if lower.contains("user") || lower.contains("human") {
            return msg.username ?? "You"
        }
        if lower.contains("system") { return "System" }
        return msg.username ?? "Devin"
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if let job = job {
            HStack(spacing: 12) {
                if let dashboard = job.dashboardURL, let url = URL(string: dashboard) {
                    Button("Live session") { openURL(url) }
                        .buttonStyle(.bordered)
                }
                if let prURL = job.prURL, let url = URL(string: prURL) {
                    Button(prButtonTitle(for: job)) { openURL(url) }
                        .buttonStyle(.borderedProminent)
                        .tint(prButtonTint(for: job))
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private func prButtonTitle(for job: DevinAgentJob) -> String {
        switch job.prState?.lowercased() {
        case "merged": return "Merged PR"
        case "closed": return "PR closed"
        default:       return "See PR"
        }
    }

    private func prButtonTint(for job: DevinAgentJob) -> Color {
        switch job.prState?.lowercased() {
        case "merged": return .purple
        case "closed": return .gray
        default:       return .accentColor
        }
    }

    // MARK: Status line

    static func statusLine(for job: DevinAgentJob) -> String {
        switch job.prState?.lowercased() {
        case "merged": return "🎉 Merged"
        case "closed": return "🚫 PR closed"
        default: break
        }
        switch job.status {
        case "running":   return "● Working"
        case "blocked":   return "🟡 Blocked"
        case "finished":  return "✅ Finished"
        case "expired":   return "⌛ Expired"
        case "cancelled": return "🚫 Cancelled"
        case "stale":     return "⌛️ Stopped tracking"
        case "error":     return "❌ Error"
        default:          return job.status
        }
    }
}

