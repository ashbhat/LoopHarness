//
//  SubAgentNotifications.swift
//  Loop
//
//  Delivers a local notification when a sub-agent finishes while the app is
//  backgrounded (iOS) or inactive (Mac). The manager checks app-state before
//  calling in — this file is concerned only with how a notification gets
//  posted, not when.
//

import Foundation
import UserNotifications

enum SubAgentNotifications {
    /// Drop a local notification announcing that a sub-agent finished. Best-
    /// effort: if the user hasn't granted notification permission yet we
    /// silently bail (asking from inside a background completion handler
    /// would feel rude).
    static func deliver(for agent: SubAgent) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            // .ephemeral is iOS-only (App Clips); guard so the macOS build
            // doesn't try to reference it.
            var granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            #if os(iOS)
            if settings.authorizationStatus == .ephemeral { granted = true }
            #endif
            guard granted else { return }

            let content = UNMutableNotificationContent()
            switch agent.state {
            case .completed:
                content.title = "Sub-agent finished"
            case .failed:
                content.title = "Sub-agent failed"
            default:
                content.title = "Sub-agent finished"
            }
            content.body = agent.result ?? agent.displayTitle
            content.sound = .default
            content.userInfo = [
                "sub_agent_id": agent.id,
                "conversation_id": agent.parentConversationId
            ]

            let request = UNNotificationRequest(
                identifier: "loop.subagent.\(agent.id)",
                content: content,
                trigger: nil // fire immediately
            )
            center.add(request, withCompletionHandler: nil)
        }
    }
}
