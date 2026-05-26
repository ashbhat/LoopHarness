# Streaming / Render Variance Investigation

## Summary

Assistant messages sometimes appear to type out very quickly and other times very slowly. This investigation identifies the root causes and proposes fixes.

## Architecture Overview

The iOS app does **not** use Server-Sent Events (SSE) streaming from providers. Both `AnthropicChat` and `OpenAIChat` use non-streaming `URLSession.dataTask` requests — the full response body arrives in **one shot** once the model finishes generating. The perceived "streaming" is actually a **client-side word-by-word typewriter animation** that plays back the already-complete response text.

```
User sends message
  → Cloud.connection.chat() [non-streaming HTTP]
  → Full response arrives at once
  → MessagingVC sets messageIdToAnimate = response.id
  → tableView.reloadData()
  → cellForRowAt calls cell.setData(shouldAnimate: true)
  → MessagingCell.animateText() plays words via a Timer
```

## Root Cause Analysis

### Primary Cause: Fixed-interval timer on variable-length content

**File:** `intel/MessagingCell.swift` lines 419–461

```swift
timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { ... }
```

The animation fires every **10ms** and displays **one word** per tick. This means:
- A 10-word response finishes in ~100ms (appears instant)
- A 500-word response takes ~5 seconds (appears slow)

The perceived speed is directly proportional to response length. Short answers fly by; long answers crawl.

### Secondary Cause: Expensive markdown re-parse on every word

Each timer tick calls:
```swift
self.animatingtextView.attributedText = self.attributedString(from: newText)
```

`attributedString(from:)` (line 514) runs **5+ regex passes** on every invocation:
1. Header regex (`^#{1,6}\s*…`)
2. Bold regex (`\*\*…\*\*`)
3. Markdown link regex (`[text](url)`)
4. File-path linkifier regex
5. `NSDataDetector` for bare URLs

As `newText` grows (word by word), each regex pass takes longer — producing a **quadratic** cost curve. For a 500-word response, the final ticks parse ~2500 characters through 5 regex engines. This compounds with the fixed interval: the timer fires every 10ms but the regex work may take 5–15ms per tick on longer texts, causing frame drops and stutter.

### Tertiary Cause: `updateContentSize()` triggers `beginUpdates/endUpdates` every tick

```swift
// Line 477-479, called from within the timer's DispatchQueue.main.async block:
tableView.beginUpdates()
tableView.endUpdates()
```

This forces UITableView to recalculate **all visible cell heights** on every single word. On a conversation with 20+ visible cells, this is extremely expensive (Auto Layout + `systemLayoutSizeFitting` on every cell).

### Tertiary Cause: Full `tableView.reloadData()` during animation

Multiple code paths call `tableView.reloadData()` while an animation may be in flight (e.g. the tool-dispatch shimmer updates at line 910). This dequeues fresh cells, resetting any in-progress animation or triggering a new one mid-flight.

## What does NOT cause the variance

| Hypothesis | Finding |
|---|---|
| Network/provider chunk-size variance | Not applicable — no SSE streaming; full response in one HTTP body |
| Main-thread contention from model calls | Model calls are on URLSession background queues; callbacks dispatch to main only for UI |
| SwiftUI re-render thrash | App uses UIKit (UITableView), not SwiftUI |
| Artificial per-character sleep/delay | No `Thread.sleep` or `Task.sleep` in the render path |

## Proposed Fixes (ranked by impact)

### Fix 1 — Remove animation entirely (highest impact, lowest risk)

The "typewriter" effect provides no functional value and is the sole cause of variable speed perception. The macOS target (`intelmac/ConversationWindowController.swift`) already renders messages instantly — it never calls `animateText`. Removing the animation on iOS makes behavior consistent across platforms.

**Change:** In `setData(data:shouldAnimate:)`, always take the non-animated path (set `textView.alpha = 1.0` and assign the attributed text directly).

### Fix 2 — Switch to fixed total duration (medium impact)

If animation is desired, compute `interval = TARGET_DURATION / wordCount` so every response takes the same wall time (e.g. 800ms) regardless of length.

### Fix 3 — Throttle markdown re-parse (medium impact, medium risk)

Only call `attributedString(from:)` every N words or at the final tick. Display plain text in between. Eliminates the quadratic regex cost.

### Fix 4 — Remove per-word `beginUpdates/endUpdates` (medium impact)

Replace the per-tick table update with a single `invalidateIntrinsicContentSize` at the end of animation. The text view already uses Auto Layout constraints that track content size.

## Recommendation

**Ship Fix 1** — it eliminates all variance, removes ~50 lines of complexity, aligns iOS with macOS behavior, and has zero regression risk (the non-animated path is already exercised for every non-latest message on scroll/reload).

Fixes 2–4 are alternatives if the product decision is to keep the typewriter effect.
