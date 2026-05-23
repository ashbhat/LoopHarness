//
//  ConversationCaption.swift
//  LoopVision
//
//  The floating text surface anchored just below the orb (added as a
//  RealityView attachment by OrbVolumeView). It shows, in order of the turn:
//  the live transcript while you speak, a tool-activity line while a skill
//  runs, then the assistant's reply revealed word-by-word.
//
//  The reply text arrives (via VisionSession ← coordinator.onAssistantText)
//  *before* TTS starts, so the typewriter reveal here is purely a local
//  animation off the already-delivered full string — it never gates, and is
//  always ahead of, the spoken audio.
//

import SwiftUI

struct ConversationCaption: View {
    let session: VisionSession

    /// How many space-separated words of the reply are currently revealed.
    @State private var revealedCount = 0

    private static let perWord: Duration = .milliseconds(55)

    var body: some View {
        Group {
            if hasContent {
                VStack(alignment: .leading, spacing: 10) {
                    if !session.userLine.isEmpty {
                        Text(session.userLine)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    content
                }
                .padding(22)
                .frame(maxWidth: 540, alignment: .leading)
                .glassBackgroundEffect()
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: hasContent)
        .task(id: session.assistantText) { await revealReply() }
    }

    @ViewBuilder
    private var content: some View {
        if session.mode == .listening {
            Text(session.partial.isEmpty ? "Listening…" : session.partial)
                .font(.title3)
                .foregroundStyle(session.partial.isEmpty ? .secondary : .primary)
        } else if !session.assistantText.isEmpty {
            MarkdownText(markdown: revealedMarkdown)
                .font(.title3)
        } else if !session.activity.isEmpty {
            Label {
                Text(session.activity)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.headline)
            .foregroundStyle(.secondary)
        } else if session.mode == .thinking {
            Label {
                Text("Thinking…")
            } icon: {
                ProgressView().controlSize(.small)
            }
            .font(.headline)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reveal

    private var words: [Substring] {
        session.assistantText.split(separator: " ", omittingEmptySubsequences: false)
    }

    private var revealedMarkdown: String {
        words.prefix(revealedCount).map(String.init).joined(separator: " ")
    }

    private func revealReply() async {
        revealedCount = 0
        let total = words.count
        guard total > 0 else { return }
        var shown = 0
        while shown < total {
            shown += 1
            revealedCount = shown
            try? await Task.sleep(for: Self.perWord)
            if Task.isCancelled { return }
        }
        revealedCount = total
    }

    private var hasContent: Bool {
        if session.mode == .listening { return true }
        if !session.assistantText.isEmpty { return true }
        if !session.userLine.isEmpty { return true }
        if !session.activity.isEmpty { return true }
        return session.mode == .thinking
    }
}
