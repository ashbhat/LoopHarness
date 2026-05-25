# PDF Generation Skill

## Context
Users frequently end a chat with "make me a PDF I can share" — wedding venue
shortlists, trip itineraries, packing checklists, summary letters, dense
research notes. Today Loop has no way to materialize the conversation into a
shareable document; users have to copy text into Notes or Pages and clean it
up themselves.

This skill closes that loop. The model writes the document content; the skill
turns it into a clean, page-aware PDF and drops it as a previewable file in
the chat. Tap to preview (Quick Look), tap Share to send it anywhere via the
system share sheet.

## User story
> *I'm chatting with Loop about wedding venues. I ask for a PDF summary. A
> "Loop PDF" bubble appears inline — title, page-1 thumbnail, "3 pages",
> Preview and Share buttons. Preview opens Quick Look. Share sends it to
> Messages, AirDrop, Notes, etc.*

## Tool surface

```
generate_pdf(
  title:    string,                                    // required
  document: string,                                    // required — GFM markdown
  template: "report" | "itinerary" | "letter" | "notes"  // optional, default "report"
)
```

- `title` becomes the cover heading (for templates that have a cover) and the
  filename slug.
- `document` is GFM markdown. Cover heading is implicit from `title`; the
  model uses `##` for section headings, normal markdown for everything else
  (lists, tables, quotes, links, images). Workspace image references work via
  standard `![alt](workspace://attachments/foo.png)` paths — the renderer
  rewrites them to `file://` URLs before loading.
- `template` picks the visual style. v1 ships four:
  - **report** — cover page, serif body, section headings, page numbers.
    Default. Wedding-venues use case.
  - **itinerary** — date headers, time-anchored items, compact spacing.
  - **letter** — single-page (page-break controls discourage overflow),
    salutation, signature block.
  - **notes** — minimal, dense, no cover page. Quick reference.

## System prompt fragment
Teaches the model when to call (`"make a PDF"`, `"export this"`, `"give me a
doc I can share"`, etc.), the four templates and when each fits, and the
fact that revision happens by calling `generate_pdf` again with the full new
document (no patch — read the prior call's args from chat history). Also
spells out "don't restate the chat verbatim — write a fresh, document-quality
version."

## Render pipeline

1. **Markdown → HTML** — small bundled converter (cmark-style, single .swift
   file in `LoopShare`-equivalent location), enough for headings, lists,
   tables, links, images, code blocks, quotes, hr, emphasis.
2. **HTML → templated HTML** — wrap body in the template's HTML shell, inline
   the template's CSS. Substitute `{{title}}` and `{{date}}` placeholders.
3. **Offscreen WKWebView load** — instantiate sized to the Letter page width
   (816pt @ 96dpi); load HTML with a `baseURL` of `Workspace.shared.rootURL`
   so relative `file://` references resolve. Wait on
   `webView(_:didFinish:)` *and* `document.fonts.ready` (eval'd via JS) so
   neither layout nor typography are mid-flight when we snapshot.
4. **WKWebView.createPDF(configuration:)** — produces a multi-page,
   page-aware PDF using the CSS `@page` rules in the template.
5. **Save to Workspace** — `Workspace.shared.rootURL/pdfs/{slug}-{date}.pdf`.
6. **Page-1 thumbnail** via `PDFKit.PDFPage.thumbnail(of:for:)` for the chat
   cell.
7. **Notify host** with `PDFAttachment(status: .ready, fileURL:, pageCount:,
   thumbnailURL:)`.

### Page rules (every template)
```css
@page { size: Letter; margin: 0.75in;
        @bottom-right { content: counter(page) " / " counter(pages) } }
h1, h2, h3 { break-after: avoid-page; }
figure, table, blockquote, pre { break-inside: avoid-page; }
h2 { break-before: page; }    /* per-template — report/itinerary use this */
```

## Attachment + chat integration

Mirrors `ImageAttachment` / `ImageSkill` / `ImageSkillHost`:

- `PDFAttachment` struct with id, title, template, document (the source
  markdown — kept so retry can re-render without re-asking the model),
  fileURL?, thumbnailURL?, pageCount?, status (.generating/.ready/.failed),
  failureReason?, conversationId? (for multi-tab Mac routing).
- `MessageStruct.pdfAttachment: PDFAttachment?` (parallel to `imageAttachment`).
- `PDFSkill` is target-agnostic; tool schema + system prompt + dispatch.
- `PDFGenerationService.shared` owns the WKWebView render lifecycle and the
  in-flight jobs registry.
- `PDFSkillHost` protocol: `pdfSkillDidStartGenerating(_:)` and
  `pdfSkillDidFinishGenerating(_:)`. Implemented by `MessagingVC` (iOS) and
  `ConversationWindowController` (Mac).
- Chat cell: title + page-1 thumbnail + page count + Preview button
  (`QLPreviewController` on iOS, `QLPreviewPanel` on Mac) + ShareLink
  (cross-platform from iOS 16+/macOS 13+).

## Iteration
Chat-only. To revise ("add a budget section", "make it shorter"), the user
asks in chat, the model calls `generate_pdf` again with a fresh full
document, and a new PDF bubble appears. Retry on a failed bubble re-submits
the same `document + template` (cached in the attachment) without re-asking
the model.

## Constraints
- **No network.** Render is fully local. No keys to provision, no rate
  limits, no offline failure mode.
- **Page size: Letter** in v1. Locale-derived A4 is a follow-up.
- **Workspace storage** — PDFs live alongside images at
  `Workspace.shared.rootURL/pdfs/`. iCloud-synced when available; survives
  app restart and shows up in the Files app.
- **visionOS** — skill compiles and the message lands in the shared store,
  but no thumbnail cell in v1 (parity with `ImageSkill` on visionOS today).
