//
//  HotKeyMonitor.swift
//  LoopMac
//
//  Listens for the control + fn modifier combo across the whole system. We
//  use NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) so the user
//  can trigger Loop from any app, not just when Loop is frontmost.
//
//  Global monitors require Accessibility permission. On first launch we
//  prompt; subsequent launches read the granted state silently.
//

import AppKit

final class HotKeyMonitor {
    /// Fires when the combo is tapped and released before `holdThreshold`.
    /// A tap means "I want the recorder bar focused for typing," not "record."
    var onTap: (() -> Void)?
    /// Fires once the user has held the combo past `holdThreshold` — i.e. they
    /// committed to push-to-talk recording rather than a quick tap.
    var onHoldBegan: (() -> Void)?
    /// Fires when the combo is released after `onHoldBegan` already fired.
    /// Not called for taps that never crossed the threshold.
    var onHoldEnded: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var combinationActive = false
    private var holdTimer: Timer?
    private var holdFired = false
    /// How long the user must hold ctrl+fn before we treat the press as a
    /// "hold to record" rather than a "tap to type." 200ms is short enough
    /// that recording still feels immediate but long enough that a quick
    /// chord doesn't accidentally start the mic.
    private let holdThreshold: TimeInterval = 0.2

    func start() {
        ensureAccessibility()

        // Global monitor: fires when the app is NOT frontmost.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
        }
        // Local monitor: fires when Loop IS frontmost. Both are required to
        // catch the modifier in every state.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stop() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }

    private func handle(event: NSEvent) {
        let flags = event.modifierFlags
        // We want the press where BOTH control and function are held; release
        // on either coming up.
        let comboHeld = flags.contains(.control) && flags.contains(.function)
        if comboHeld && !combinationActive {
            combinationActive = true
            holdFired = false
            scheduleHoldTimer()
        } else if !comboHeld && combinationActive {
            combinationActive = false
            cancelHoldTimer()
            if holdFired {
                holdFired = false
                DispatchQueue.main.async { [weak self] in self?.onHoldEnded?() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.onTap?() }
            }
        }
    }

    private func scheduleHoldTimer() {
        cancelHoldTimer()
        // Timer.scheduledTimer attaches to the current runloop; the global/
        // local NSEvent monitors deliver on the main thread, so this lands on
        // the main runloop where the timer can actually fire.
        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { [weak self] _ in
            guard let self = self, self.combinationActive else { return }
            self.holdFired = true
            self.onHoldBegan?()
        }
    }

    private func cancelHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = nil
    }

    /// Triggers the Accessibility permission prompt if not already granted.
    /// Without it, NSEvent.addGlobalMonitorForEvents silently no-ops on
    /// .flagsChanged for keys outside the application.
    ///
    /// We check trust with the *unprompted* `AXIsProcessTrusted()` first and
    /// only fall back to the prompting variant when we're actually not
    /// trusted. The prompting variant can re-surface the system "you have
    /// granted Loop accessibility" notification in some macOS versions even
    /// when access is already granted — gating on the cheap check first
    /// keeps subsequent launches silent.
    private func ensureAccessibility() {
        if AXIsProcessTrusted() { return }
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts)
        print("⚠️ HotKeyMonitor: Accessibility not yet granted. Approve in System Settings → Privacy & Security → Accessibility, then relaunch Loop.")
    }
}
