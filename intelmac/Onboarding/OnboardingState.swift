//
//  OnboardingState.swift
//  LoopMac
//
//  Single source of truth for whether the user has finished the onboarding
//  flow described in intel/Specs/3_mac_onboarding_spec.md. Backed by
//  UserDefaults so the answer survives a relaunch — important because
//  step 2 (Accessibility) requires a system permission grant that the user
//  often confirms by relaunching Loop.
//

import Foundation

enum MacOnboardingState {
    private static let isCompleteKey = "loop.mac.onboarding.completed"
    private static let lastStepKey   = "loop.mac.onboarding.lastStep"

    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: isCompleteKey) }
        set { UserDefaults.standard.set(newValue, forKey: isCompleteKey) }
    }

    /// Step the user reached on a previous run (0…3). Lets us resume past
    /// the welcome page if the user quit/relaunched mid-flow — common
    /// during the Accessibility step, since granting access often needs a
    /// relaunch to take effect.
    static var lastStep: Int {
        get { UserDefaults.standard.integer(forKey: lastStepKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastStepKey) }
    }
}
