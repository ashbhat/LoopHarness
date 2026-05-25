//
//  PDFSkill.swift
//  Loop
//
//  Built from LoopIOS/pdf_spec.md.
//
//  Thin tool wrapper mirroring ImageSkill: the model calls `generate_pdf`,
//  we hand the work off to PDFGenerationService, and return a "queued"
//  function-result immediately so the assistant can write a short
//  acknowledgement while the render is still in flight. The PDF bubble
//  swaps into the chat via PDFSkillHost when the render completes.
//

import Foundation

/// Side-effect surface PDFGenerationService uses to inject the placeholder
/// and final PDF cells into the chat. Same shape as ImageSkillHost —
/// MessagingVC (iOS) and ConversationWindowController (Mac) implement it.
///
/// Both callbacks are dispatched on the main queue.
protocol PDFSkillHost: AnyObject {
    /// A new generation has started. Insert a synthetic assistant message
    /// carrying `attachment` (in .generating state) so the user sees a
    /// placeholder card immediately.
    func pdfSkillDidStartGenerating(_ attachment: PDFAttachment)
    /// Generation completed (success or failure). Find the placeholder by
    /// `attachment.id` and mutate it in place.
    func pdfSkillDidFinishGenerating(_ attachment: PDFAttachment)
}

/// Generates clean, page-aware PDFs from GFM markdown. The render pipeline
/// is fully local (offscreen WKWebView → createPDF → PDFKit thumbnail) so
/// the skill has no API keys, rate limits, or offline failure mode.
///
/// Iteration ("make it shorter", "add a budget section") is chat-mediated:
/// the model rewrites the full document and calls `generate_pdf` again.
/// Retry on a failed bubble re-submits the cached document + template
/// without re-asking the model.
final class PDFSkill {
    static let shared = PDFSkill()

    static let templates: [String] = ["report", "itinerary", "letter", "notes", "contract"]
    static let defaultTemplate = "report"

    static let systemPromptFragment: String = """
You can generate a clean, page-aware PDF inline in chat using the generate_pdf tool.

When to call:
- The user asks for a PDF, a document, an export, "give me something I can share", "make me a doc / pdf / file".
- The user has been planning something (a list of venues, a trip itinerary, a packing list, a research summary, a letter) and wants it as a polished artifact.
- The user asks to revise a previously-generated PDF ("make it shorter", "add a budget section", "swap the template"). In that case, re-call generate_pdf with the **full new document** — there is no patch tool; rewrite the document end-to-end.

How to write the `document`:
- Use GitHub-Flavored Markdown. No need to include the title — pass it via `title`. The renderer adds a cover page (for report/itinerary/letter) using the title.
- Use `##` for major sections, `###` for subsections, `####` for small labels. Lists, tables, blockquotes, code fences, links, and images all work.
- Workspace images embed via `![alt](workspace://attachments/<filename>)` — the renderer rewrites those to local file URLs.
- Don't just paste the chat back. Write a fresh, document-quality version: real prose, real structure, polished sentences. The PDF is the artifact the user shares with other people.
- Target 1–10 pages. If the topic is huge, summarize sharply.

Templates (pick one based on the content shape):
- `report` — DEFAULT. Cover page, serif body, section headings, page numbers. Right choice for plans, summaries, comparisons, research, anything that wants to feel like a "real document".
- `itinerary` — Date/time-anchored items. Use `##` for day headers, lists with `**HH:MM**` prefixes for time-anchored items. Right for trips, schedules, event runs of show.
- `letter` — Single-flow, no per-section page breaks, serif body. Right for short letters, memos, single-page summaries. ~1 page.
- `notes` — Dense, minimal, no cover page. Right for cheatsheets, quick reference, anything that should feel like a one-sheeter.
- `contract` — Legal/contractual document layout. Centered all-caps title at the top of page 1 (no cover page), justified Times-style serif body, lettered sub-clauses, italic subtitle, page footer with running document title. Right for NDAs, agreements, terms, MOUs, BAAs, and similar.

Authoring a `contract`:
- Document opens with a centered italic SUBTITLE: write `*…*` as the very first markdown line, on its own. Example: `*Pursuant to the Health Insurance Portability and Accountability Act of 1996 ("HIPAA")*`. The renderer styles a first-paragraph italic-only line as centered.
- Right after the subtitle, write metadata as bold-prefixed paragraphs, one per line:
    `**Effective Date:** 2026-03-23`
    `**Covered Entity:** Abstract Laboratories ("CE")`
    `**Business Associate:** OpenAI ("BA")`
- `# RECITALS` — single hash — for the recitals header AND any other major centered+underlined section break ("# GENERAL TERMS", "# SCHEDULE A — STATEMENT OF WORK", etc.). Top-level h1 in a contract is reserved for these dividers; the document title is provided via the `title` arg and rendered automatically at the top of page 1.
- Recital paragraphs start with `**WHEREAS,**` and the closing transition uses `**NOW, THEREFORE,**`.
- Numbered sections use `##` with the number IN the heading: `## 1. Definitions`, `## 2. Obligations of Business Associate`. These render bold + left-aligned, not centered. Subsections use `###`: `### 2.1. General Use and Disclosure Restrictions`.
- Lettered sub-clauses are written as plain ORDERED lists (`1.` / `2.` / `3.`). The CSS renders them as `a. / b. / c.` automatically — don't write the letters by hand. Nested lists render as `i. / ii. / iii.`.
- For each sub-clause, lead with the defined term in `**bold**` followed by the body sentence: `1. **"Applicable Laws"** means HIPAA, the HITECH Act, …`.
- Signature block at the end: use a 2-column markdown table — header row gets the party labels in `**bold**` (renders as the column titles), body rows hold the Signature / Name / Title / Date lines with `____________` placeholders. The contract template strips table borders.

Rules:
- One PDF per call. If the user asks for several, call once and offer to iterate.
- After the PDF renders, write a short conversational reply — don't repeat the document at the user; just acknowledge briefly so they can preview, share, or iterate.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "generate_pdf",
                "description": "Generate a clean, page-aware PDF inline in chat from a markdown document. The PDF appears as a previewable, shareable file card in the conversation. Use whenever the user asks for a PDF, a document, an export, or 'something I can share'. To revise a previously-generated PDF, call again with the full new document — there is no patch.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Title of the document. Used for the cover page and the file name. Concise — 'Wedding Venue Shortlist', 'Tokyo Trip Itinerary', not a full sentence."
                        ],
                        "document": [
                            "type": "string",
                            "description": "The document body in GitHub-Flavored Markdown. Do NOT include the title as an h1 — it's added from `title` automatically. Use `##` for sections, `###` for subsections. Lists, tables, blockquotes, links, and images all render."
                        ],
                        "template": [
                            "type": "string",
                            "enum": ["report", "itinerary", "letter", "notes", "contract"],
                            "description": "Visual template. `report` (default) for plans/summaries/comparisons, `itinerary` for date/time-anchored schedules, `letter` for single-flow short docs, `notes` for dense reference sheets, `contract` for NDAs/agreements/terms/MOUs (justified serif body, centered all-caps title, lettered sub-clauses)."
                        ]
                    ],
                    "required": ["title", "document"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = ["generate_pdf"]

    func handles(functionName: String) -> Bool {
        return PDFSkill.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "generate_pdf":
            if let t = (call.arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                return "drafting \(PDFSkill.truncate(t, to: 50)).pdf"
            }
            return "generating PDF"
        default:
            return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        switch functionCall.name {
        case "generate_pdf":
            guard let title = (functionCall.arguments["title"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a `title` to call generate_pdf.",
                    name: "generate_pdf"
                ))
                return
            }
            guard let document = (functionCall.arguments["document"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !document.isEmpty else {
                completion(MessageStruct(
                    role: "function",
                    content: "I need a `document` (markdown body) to call generate_pdf.",
                    name: "generate_pdf"
                ))
                return
            }
            let rawTemplate = (functionCall.arguments["template"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let template = (rawTemplate.flatMap { PDFSkill.templates.contains($0) ? $0 : nil })
                ?? PDFSkill.defaultTemplate
            generatePDF(title: title,
                        document: document,
                        template: template,
                        completion: completion)
        default:
            completion(MessageStruct(
                role: "assistant",
                content: "I don't know how to handle the PDF tool '\(functionCall.name)'."
            ))
        }
    }

    // MARK: - Tool handler

    /// Submit-and-return: kick the render off and synthesize a function
    /// result immediately so the model can write its short ack while the
    /// WKWebView is loading. The PDF cell swaps in via the host callbacks
    /// when the render completes (or fails).
    private func generatePDF(title: String,
                             document: String,
                             template: String,
                             completion: @escaping (MessageStruct) -> Void) {
        // Pin the render to whichever conversation is active *now* so a
        // tab-switch between submit and finish doesn't drop the bubble in
        // the wrong place on multi-tab Mac.
        let convId = SimpleConversationManager.shared.currentConversation?.id
        let attachment = PDFGenerationService.shared.submit(title: title,
                                                             document: document,
                                                             template: template,
                                                             conversationId: convId)
        let summary = "PDF generation queued (id: \(attachment.id), template: \(template)). The PDF will appear inline shortly. Acknowledge briefly to the user; do not wait for the file."
        completion(MessageStruct(
            role: "function",
            content: summary,
            name: "generate_pdf"
        ))
    }

    // MARK: - Helpers

    private static func truncate(_ s: String, to max: Int) -> String {
        if s.count <= max { return s }
        let idx = s.index(s.startIndex, offsetBy: max)
        return String(s[..<idx]) + "…"
    }
}
