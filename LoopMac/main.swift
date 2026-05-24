//
//  main.swift
//  LoopMac
//
//  Top-level entry point. Using main.swift (instead of @main) so the run loop
//  binding to NSApplication is unambiguous: AppKit apps launched without a
//  Main.storyboard need an explicit `NSApp.run()` after wiring the delegate.
//

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
