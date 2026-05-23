//
//  ConversationView.swift
//  LoopVision
//
//  The visionOS rethink of the Mac's NSSplitViewController conversation
//  window. Opened as a separate 2D window when the pill below the orb is
//  tapped, so it sits alongside the orb (and every other app) in the Shared
//  Space. A SwiftUI NavigationSplitView: conversations on the left, the
//  selected transcript on the right, rendered with native markdown.
//
//  History is the shared, iCloud-synced SimpleConversationManager store, so
//  the list and transcripts match what the iPhone and Mac show. Selecting a
//  conversation tells the session to continue voice turns in it.
//

import SwiftUI

struct ConversationView: View {
    let session: VisionSession

    @State private var selectedID: String?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .onAppear {
            session.reloadConversations()
            if selectedID == nil { selectedID = session.currentConversationID }
        }
        .onChange(of: selectedID) { _, newID in
            guard let newID, newID != session.currentConversationID,
                  let conv = session.conversations.first(where: { $0.id == newID })
            else { return }
            session.selectConversation(conv)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedID) {
            ForEach(session.conversations, id: \.id) { conv in
                VStack(alignment: .leading, spacing: 4) {
                    Text(conv.title.isEmpty ? "Untitled" : conv.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(conv.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(conv.id)
            }
        }
        .navigationTitle("Conversations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let conv = SimpleConversationManager.shared.createConversation(
                        title: "Vision Chat \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))")
                    session.reloadConversations()
                    selectedID = conv.id
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
            }
        }
    }

    // MARK: - Detail (transcript)

    @ViewBuilder
    private var detail: some View {
        // Touching turnCounter establishes an observation dependency so the
        // transcript re-reads the store after each completed voice turn.
        let _ = session.turnCounter
        if let id = selectedID {
            let messages = Self.transcript(for: id)
            if messages.isEmpty {
                ContentUnavailableView("No messages yet",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Look at the orb and pinch to talk."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(messages, id: \.id) { msg in
                                bubble(for: msg).id(msg.id)
                            }
                        }
                        .padding(24)
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if let last = messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a conversation",
                                   systemImage: "sidebar.left")
        }
    }

    @ViewBuilder
    private func bubble(for msg: MessageStruct) -> some View {
        let isUser = msg.role == "user"
        HStack {
            if isUser { Spacer(minLength: 60) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(isUser ? "You" : "Loop")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Group {
                    if isUser {
                        Text(msg.content)
                    } else {
                        MarkdownText(markdown: msg.content)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isUser ? AnyShapeStyle(.tint.opacity(0.25))
                                   : AnyShapeStyle(.thinMaterial),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .textSelection(.enabled)
            }
            if !isUser { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    /// User/assistant turns of a conversation, newest-readable order, pulled
    /// fresh from the shared store each call.
    private static func transcript(for id: String) -> [MessageStruct] {
        let mgr = SimpleConversationManager.shared
        guard let conv = mgr.getConversation(by: id) else { return [] }
        return mgr.getMessages(for: conv)
            .map { mgr.messageStruct(from: $0) }
            .filter { ($0.role == "user" || $0.role == "assistant") && !$0.content.isEmpty }
    }
}
