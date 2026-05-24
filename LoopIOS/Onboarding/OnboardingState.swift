//
//  OnboardingState.swift
//  Loop (iOS)
//
//  Single source of truth for whether the user has finished the iOS onboarding
//  flow described in LoopIOS/Specs/3_ios_onboarding_spec.md. Backed by
//  UserDefaults so the answer survives a relaunch — important because step 2
//  (action button setup) sends the user out to the system Settings app, and
//  the user often comes back via swipe rather than a clean app foreground.
//

import Foundation

enum OnboardingState {
    private static let isCompleteKey = "loop.ios.onboarding.completed"
    private static let lastStepKey   = "loop.ios.onboarding.lastStep"

    static var isComplete: Bool {
        get { iCloudKVSDefaults.shared.bool(forKey: isCompleteKey) }
        set { iCloudKVSDefaults.shared.set(newValue, forKey: isCompleteKey) }
    }

    /// Step the user reached on a previous run (0…2). Lets us resume past the
    /// welcome page if the user backgrounded the app mid-flow — common during
    /// the action button step, since the user leaves the app to add the
    /// shortcut in Settings.
    static var lastStep: Int {
        get { iCloudKVSDefaults.shared.integer(forKey: lastStepKey) }
        set { iCloudKVSDefaults.shared.set(newValue, forKey: lastStepKey) }
    }
}
