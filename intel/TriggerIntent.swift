//
//  TriggerIntent.swift
//  intel
//
//  Created by Ash Bhat on 12/31/25.
//

import AppIntents
import UIKit

struct StartDictationIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Dictation"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        // your logic here
//        return .result()
        if let sceneDelegate = await currentSceneDelegate() {
            await sceneDelegate.handleMicURL()
        }
        return .result()
    }
    
    @MainActor
    func currentSceneDelegate() -> SceneDelegate? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .delegate as? SceneDelegate
    }
}

/// Surfaces `StartDictationIntent` as a first-class App Shortcut.
///
/// Without this provider the intent only registers after the app's first
/// launch and never auto-populates; declaring it here makes the action
/// available in the Shortcuts app, Spotlight, Siri, and the Action Button
/// list without any user setup. App Shortcut phrases must reference
/// `\(.applicationName)`, which resolves from the app's display/bundle name.
struct LoopAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartDictationIntent(),
            phrases: [
                "Start dictation in \(.applicationName)",
                "Start \(.applicationName) dictation",
                "Dictate with \(.applicationName)"
            ],
            shortTitle: "Start Dictation",
            systemImageName: "mic.fill"
        )
    }
}
