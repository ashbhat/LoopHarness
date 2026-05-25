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
    private static let assistantNameKey = "loop.assistantName"
    private static let actionButtonSkippedKey = "loop.ios.onboarding.actionButtonSkipped"
    private static let actionButtonBoundKey = "loop.ios.onboarding.actionButtonBound"
    private static let actionButtonReminderDismissedAtKey = "loop.ios.onboarding.actionButtonReminderDismissedAt"

    static var isComplete: Bool {
        get { iCloudKVSDefaults.shared.bool(forKey: isCompleteKey) }
        set { iCloudKVSDefaults.shared.set(newValue, forKey: isCompleteKey) }
    }

    /// Step the user reached on a previous run. Lets us resume past the welcome
    /// page if the user backgrounded the app mid-flow — common during the
    /// action button step, since the user leaves the app to add the shortcut
    /// in Settings. Stored as the raw value of `OnboardingCoordinator.StepID`.
    static var lastStep: Int {
        get { iCloudKVSDefaults.shared.integer(forKey: lastStepKey) }
        set { iCloudKVSDefaults.shared.set(newValue, forKey: lastStepKey) }
    }

    /// What the user wants to call the assistant. Defaults to "Loop" when the
    /// user accepts the suggestion or hasn't set anything yet. Synced via
    /// iCloudKVSDefaults so cross-device naming stays consistent.
    static var assistantName: String {
        get { iCloudKVSDefaults.shared.string(forKey: assistantNameKey) ?? "Loop" }
        set { iCloudKVSDefaults.shared.set(newValue, forKey: assistantNameKey) }
    }

    /// User tapped "Skip for now" on the action button walkthrough. Triggers
    /// the persistent reminder banner in MainVC until the button is bound (or
    /// the user dismisses the banner for a while via `actionButtonReminderDismissedAt`).
    static var actionButtonSkipped: Bool {
        get { iCloudKVSDefaults.shared.bool(forKey: actionButtonSkippedKey) }
        set { iCloudKVSDefaults.shared.set(newValue, forKey: actionButtonSkippedKey) }
    }

    /// True once `SceneDelegate.handleMicURL()` has ever fired — proof the
    /// user actually bound the Action Button to Loop's Start Dictation
    /// shortcut. Permanently hides the reminder banner once true.
    static var actionButtonBound: Bool {
        get { iCloudKVSDefaults.shared.bool(forKey: actionButtonBoundKey) }
        set { iCloudKVSDefaults.shared.set(newValue, forKey: actionButtonBoundKey) }
    }

    /// Last time the user tapped `x` on the reminder banner, stored as
    /// integer seconds since epoch (iCloudKVSDefaults only exposes Bool / Int /
    /// String accessors — second-precision is plenty for a 7-day cadence).
    /// Nil → never dismissed.
    static var actionButtonReminderDismissedAt: Date? {
        get {
            let t = iCloudKVSDefaults.shared.integer(forKey: actionButtonReminderDismissedAtKey)
            return t > 0 ? Date(timeIntervalSince1970: TimeInterval(t)) : nil
        }
        set {
            iCloudKVSDefaults.shared.set(Int(newValue?.timeIntervalSince1970 ?? 0),
                                         forKey: actionButtonReminderDismissedAtKey)
        }
    }

    /// Should the persistent action-button reminder banner show in MainVC right now?
    /// True when the user skipped during onboarding, has not yet bound the
    /// button, and either never dismissed the banner or last dismissed it
    /// more than 7 days ago.
    static var shouldShowActionButtonReminder: Bool {
        guard actionButtonSkipped, !actionButtonBound else { return false }
        guard let dismissedAt = actionButtonReminderDismissedAt else { return true }
        return Date().timeIntervalSince(dismissedAt) > 7 * 24 * 60 * 60
    }
}
