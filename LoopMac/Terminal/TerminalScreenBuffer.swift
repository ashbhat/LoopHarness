//
//  TerminalScreenBuffer.swift
//  LoopMac
//
//  Minimal VT100-ish screen buffer used to render pty output in the
//  in-app terminal window without a full terminal emulator. Handles the
//  control sequences that show up in everyday shell output (\r overwrites
//  for progress bars, CSI K erase-line, CSI A/B cursor motion for
//  spinners like the one Claude Code uses) so that those animations
//  redraw in place instead of stacking into a vertical column.
//
//  What this is NOT: a full terminal. We don't implement scrolling
//  regions, alt-screen buffers, mouse modes, character sets, or most
//  SGR styling. Heavy TUIs (vim, htop, claude code's full-screen UI) will
//  still look messy here — the system prompt routes those to
//  open_external_terminal.
//
//  Two output channels are exposed:
//   - `render()`     → screen contents (lines joined by \n) for display.
//                       Re-rendered on every update; the rendered string
//                       can shrink when erase / overwrite happens.
//   - `appendedRaw`  → cumulative, never-overwritten plain-text view for
//                       byte-offset markers (agents reading via
//                       read_terminal_output). Spinners still bloat this,
//                       but the marker semantics stay correct.
//

import Foundation

final class TerminalScreenBuffer {

    // MARK: - Public state

    /// Cumulative scrubbed text — strips ANSI escapes and most control
    /// bytes but does NOT process cursor motion or erases. This is what
    /// `read(since:)` returns to agents that want a flat transcript.
    private(set) var appendedRaw: String = ""

    /// Monotonically increases on every mutation. Lets observers detect
    /// that the rendered string may have changed without diffing it.
    private(set) var version: Int = 0

    // MARK: - Private state (the "screen")

    /// Logical lines making up the current screen contents. The buffer
    /// grows as lines are appended via \n and shrinks (or has lines
    /// overwritten in place) when erase sequences fire.
    private var lines: [String] = [""]
    /// 0-indexed cursor row (index into `lines`).
    private var cursorRow: Int = 0
    /// 0-indexed cursor column. May be past the end of the current line;
    /// `writeChar` pads with spaces as needed.
    private var cursorCol: Int = 0

    /// Hard cap on retained lines. Older lines are trimmed off the top
    /// when exceeded — a long-running session won't grow without bound.
    /// 5000 lines is comfortably more than any terminal's scrollback the
    /// in-app view would actually let the user scroll through.
    private let maxLines = 5000

    // MARK: - Public API

    /// Feed a chunk of pty output into the buffer. Returns whether the
    /// rendered output changed (always true in practice — callers use
    /// the version counter for change detection).
    func write(_ input: String) {
        var iter = input.unicodeScalars.makeIterator()
        while let scalar = iter.next() {
            switch scalar.value {
            case 0x1B:
                // ESC — drives one of the small set of sequences we
                // recognize; everything else is dropped.
                handleEscape(&iter)
            case 0x0D:
                // CR — return cursor to column 0 of the current line.
                // The shell's line discipline already turns Enter into
                // \r\n; bare \r is what progress bars and spinners use.
                cursorCol = 0
                appendedRaw.append("\r")
            case 0x0A:
                // LF — move to the next line, column 0. We add the \n
                // to appendedRaw too so agent reads keep line structure.
                cursorRow += 1
                cursorCol = 0
                ensureRow(cursorRow)
                appendedRaw.append("\n")
            case 0x08:
                // BS — back one column. Doesn't erase; the next write
                // will overwrite. Matches xterm semantics.
                if cursorCol > 0 { cursorCol -= 1 }
            case 0x09:
                // TAB — advance to the next 8-column tab stop, padding
                // with spaces. Most shells emit literal tabs in `ls`
                // output etc.
                let target = ((cursorCol / 8) + 1) * 8
                while cursorCol < target { writeChar(" ") }
                appendedRaw.append("\t")
            case 0x07:
                // BEL — silently dropped. We don't ring the system
                // bell for every shell completion.
                continue
            case 0..<0x20, 0x7F:
                // Other C0 controls and DEL — dropped.
                continue
            default:
                writeChar(Character(scalar))
                appendedRaw.unicodeScalars.append(scalar)
            }
        }
        version += 1
        trimIfNeeded()
    }

    /// Render the current screen as a single string with `\n` between
    /// rows. The result reflects every overwrite / erase that's happened
    /// so far — spinners that redraw in place show only their latest
    /// frame, progress bars show only their current state.
    func render() -> String {
        return lines.joined(separator: "\n")
    }

    /// UTF-8 byte length of `appendedRaw` — what `TerminalSession.read`
    /// uses for its offset markers.
    var appendedRawByteCount: Int {
        return appendedRaw.utf8.count
    }

    /// Read the delta in `appendedRaw` since the given marker.
    func readAppendedRaw(since marker: Int?) -> (text: String, marker: Int) {
        let total = appendedRaw.utf8.count
        let start = max(0, min(marker ?? 0, total))
        if start >= total { return ("", total) }
        let utf8 = Array(appendedRaw.utf8)
        let slice = Array(utf8[start..<total])
        return (String(decoding: slice, as: UTF8.self), total)
    }

    // MARK: - Cursor + line ops

    private func ensureRow(_ row: Int) {
        while row >= lines.count { lines.append("") }
    }

    private func writeChar(_ ch: Character) {
        ensureRow(cursorRow)
        var chars = Array(lines[cursorRow])
        if cursorCol > chars.count {
            // Pad — cursor positioning escapes can leave the cursor past
            // the end of the current line. Use spaces so the next write
            // doesn't end up shifted left of where the agent expected.
            chars.append(contentsOf: Array(repeating: Character(" "), count: cursorCol - chars.count))
        }
        if cursorCol == chars.count {
            chars.append(ch)
        } else {
            chars[cursorCol] = ch
        }
        lines[cursorRow] = String(chars)
        cursorCol += 1
    }

    private func trimIfNeeded() {
        if lines.count > maxLines {
            let drop = lines.count - maxLines
            lines.removeFirst(drop)
            // Cursor row is screen-relative — adjust so it still points
            // at the row the shell thinks is current.
            cursorRow = max(0, cursorRow - drop)
        }
    }

    // MARK: - Escape handling

    private func handleEscape(_ iter: inout String.UnicodeScalarView.Iterator) {
        guard let next = iter.next() else { return }
        switch next {
        case "[":
            handleCSI(&iter)
        case "]":
            // OSC — title-setting and friends. Consume until BEL or
            // ESC \ (string terminator) without applying anything.
            consumeOSC(&iter)
        case "(", ")":
            // Charset designators (G0/G1) — eat one byte, ignore.
            _ = iter.next()
        case "=", ">":
            // Application / numeric keypad — no-op.
            break
        case "M":
            // Reverse index (cursor up one line, scroll if at top). We
            // approximate as "cursor up, clamped to 0" — full scroll
            // region semantics aren't implemented.
            cursorRow = max(0, cursorRow - 1)
        default:
            // Single-byte ESC sequences we don't care about (charset
            // selection, DECSC/DECRC, etc.). Drop and move on.
            break
        }
    }

    private func consumeOSC(_ iter: inout String.UnicodeScalarView.Iterator) {
        while let c = iter.next() {
            if c.value == 0x07 { return }
            if c.value == 0x1B {
                _ = iter.next() // consume the \
                return
            }
        }
    }

    private func handleCSI(_ iter: inout String.UnicodeScalarView.Iterator) {
        // Collect the parameter / intermediate bytes until we hit a
        // final byte in 0x40..0x7E. CSI format is:
        //   ESC [ <params 0x30..0x3F>* <intermediates 0x20..0x2F>* <final 0x40..0x7E>
        var paramBytes = ""
        var finalByte: Unicode.Scalar = " "
        while let c = iter.next() {
            if c.value >= 0x40 && c.value <= 0x7E {
                finalByte = c
                break
            }
            paramBytes.unicodeScalars.append(c)
        }

        // Private-mode sequences (DECSET / DECRST) start with `?` —
        // alt-screen toggle, cursor visibility, mouse modes, etc. We
        // don't model them. Dropping silently is the right move:
        // applications that test for our response to DSR will already
        // fall back to assuming a basic terminal.
        if paramBytes.hasPrefix("?") || paramBytes.hasPrefix(">") {
            return
        }

        // Parse `;`-separated integer params with a 0-default. An empty
        // CSI (just `ESC [ A`) yields `[]`, and most commands treat
        // that as "use the default for this op".
        let parts: [Int] = paramBytes.isEmpty
            ? []
            : paramBytes.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let firstParam = parts.first ?? 0
        // Many movement ops treat `0` as `1` — "move 0 cells" is meaningless.
        let movementN = firstParam == 0 ? 1 : firstParam

        switch finalByte {
        case "A":
            cursorRow = max(0, cursorRow - movementN)
        case "B", "e":
            cursorRow += movementN
            ensureRow(cursorRow)
        case "C", "a":
            cursorCol += movementN
        case "D":
            cursorCol = max(0, cursorCol - movementN)
        case "E":
            cursorRow += movementN
            cursorCol = 0
            ensureRow(cursorRow)
        case "F":
            cursorRow = max(0, cursorRow - movementN)
            cursorCol = 0
        case "G", "`":
            // CHA: move to column N (1-indexed)
            cursorCol = max(0, movementN - 1)
        case "H", "f":
            // CUP: cursor position. Normally screen-relative against a
            // 24-row viewport — without alt-screen we approximate the
            // viewport as "the last 24 lines of the buffer." Good enough
            // for spinners that redraw in a fixed row near the bottom.
            let row = (parts.first ?? 1) == 0 ? 1 : (parts.first ?? 1)
            let col = parts.count > 1 ? (parts[1] == 0 ? 1 : parts[1]) : 1
            let viewportTop = max(0, lines.count - 24)
            cursorRow = viewportTop + max(0, row - 1)
            cursorCol = max(0, col - 1)
            ensureRow(cursorRow)
        case "d":
            // VPA: move to row N (1-indexed), keep column.
            let row = movementN
            let viewportTop = max(0, lines.count - 24)
            cursorRow = viewportTop + max(0, row - 1)
            ensureRow(cursorRow)
        case "J":
            handleEraseDisplay(mode: firstParam)
        case "K":
            handleEraseLine(mode: firstParam)
        case "S":
            // Scroll up N lines (drop top, insert blanks at bottom).
            scrollUp(n: movementN)
        case "T":
            // Scroll down — rarely used by shells. No-op.
            break
        case "m":
            // SGR (colors / bold / etc.). Visual styling is out of scope
            // for the in-app terminal; we render plain text. Drop.
            break
        default:
            break
        }
    }

    private func handleEraseLine(mode: Int) {
        ensureRow(cursorRow)
        var chars = Array(lines[cursorRow])
        switch mode {
        case 0:
            // Erase from cursor to end of line.
            if cursorCol < chars.count {
                chars = Array(chars.prefix(cursorCol))
            }
        case 1:
            // Erase from start of line to cursor (inclusive). Erased
            // cells become spaces so the cursor's column stays valid.
            let upto = min(cursorCol, max(0, chars.count - 1))
            if upto >= 0 && !chars.isEmpty {
                for i in 0...upto { chars[i] = " " }
            }
        case 2:
            // Erase entire line.
            chars = []
        default:
            return
        }
        lines[cursorRow] = String(chars)
    }

    private func handleEraseDisplay(mode: Int) {
        switch mode {
        case 0:
            // Erase from cursor to end of display: truncate current
            // line at cursor, drop everything after.
            ensureRow(cursorRow)
            let chars = Array(lines[cursorRow])
            lines[cursorRow] = String(chars.prefix(cursorCol))
            if cursorRow + 1 < lines.count {
                lines.removeSubrange((cursorRow + 1)...)
            }
        case 1:
            // Erase from start of display to cursor: blank everything
            // above + the chunk of the current line up to the cursor.
            for i in 0..<cursorRow {
                lines[i] = ""
            }
            ensureRow(cursorRow)
            var chars = Array(lines[cursorRow])
            let upto = min(cursorCol, max(0, chars.count - 1))
            if upto >= 0 && !chars.isEmpty {
                for i in 0...upto { chars[i] = " " }
            }
            lines[cursorRow] = String(chars)
        case 2, 3:
            // Erase entire display (mode 3 also clears scrollback —
            // we don't distinguish; both collapse to a blank screen).
            lines = [""]
            cursorRow = 0
            cursorCol = 0
        default:
            return
        }
    }

    private func scrollUp(n: Int) {
        if n <= 0 { return }
        let drop = min(n, lines.count)
        lines.removeFirst(drop)
        if lines.isEmpty { lines = [""] }
        cursorRow = max(0, cursorRow - drop)
    }
}
