//
//  CalendarSkill.swift
//  Loop
//
//  Lets Loop see and act on the user's calendar via EventKit. EventKit
//  natively surfaces every calendar the user has added to iOS / macOS
//  Calendar settings — Google, iCloud, Exchange, Office365 — so we get
//  multi-provider coverage without per-service OAuth.
//
//  v1 tools:
//    - list_upcoming_events: read-only, "what's coming up in the next N hours"
//    - check_calendar_availability: read-only, "am I free between X and Y"
//    - create_calendar_event: side-effecting; on iOS we route through a
//      host that presents EKEventEditViewController so the user reviews
//      + confirms before save (this is the spec's "confirmation checkpoint
//      before external side effects"). On Mac we save directly because
//      EKEventEditViewController doesn't exist there.
//

import Foundation
import EventKit

/// Host plumbing that lets the skill ask the iOS UI layer to present a
/// system event editor for user confirmation. MessagingVC conforms.
/// `proposedEvent` is fully populated with the AI's suggested values; the
/// completion fires once the user has saved, cancelled, or deleted in the
/// presented sheet.
protocol CalendarSkillHost: AnyObject {
    func calendarSkillRequestsEventEditor(forEvent event: EKEvent,
                                          eventStore: EKEventStore,
                                          completion: @escaping (CalendarEditOutcome) -> Void)
}

enum CalendarEditOutcome: String {
    case saved
    case cancelled
    case deleted
    case failed
}

final class CalendarSkill {
    static let shared = CalendarSkill()

    /// Set by MessagingVC.viewDidLoad on iOS so user-facing flows
    /// (event creation) can present a native editor. Mac leaves this nil
    /// and the skill falls back to direct save.
    weak var host: CalendarSkillHost?

    /// Owned by the skill so authorization state is consistent across calls.
    /// EventKit treats reusing one store across the app lifetime as the
    /// recommended pattern.
    let eventStore = EKEventStore()

    private init() {}

    // MARK: - System prompt + tool schema

    static let systemPromptFragment: String = """
You can read the user's calendar and propose events through these tools:
- list_upcoming_events: list the user's upcoming events over the next N hours (default 24). Useful for "what's on my calendar today?" or "what does this afternoon look like?"
- check_calendar_availability: report busy/free windows for a date range. Useful before proposing a meeting time so you don't double-book.
- create_calendar_event: propose a new calendar event with title, start/end, optional location, notes, attendee emails. On iOS this opens the native event editor for the user to review and tap Save — that user tap IS the confirmation; you don't need to ask again. If the tool returns `cancelled`, drop the proposal.

Workflow tips:
- Always check availability before proposing a meeting time.
- Dates must be ISO 8601 with timezone (e.g. "2026-05-12T15:30:00-07:00").
- For "this afternoon" / "tomorrow" type asks, resolve the date relative to the current local time stamped in this system prompt.
- The user's calendar already includes their Google, iCloud, and Exchange accounts if they've added them to their device — you don't need a separate Google account connection.
"""

    static let tools: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "list_upcoming_events",
                "description": "List the user's upcoming calendar events from now through `hours` hours from now. Defaults to 24 hours.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "hours": [
                            "type": "integer",
                            "description": "How many hours ahead to look. Defaults to 24."
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum events to return. Defaults to 20."
                        ]
                    ],
                    "required": []
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "check_calendar_availability",
                "description": "List the user's busy windows between two ISO 8601 datetimes. Useful before suggesting meeting times.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "start_iso": [
                            "type": "string",
                            "description": "ISO 8601 datetime to start checking from (e.g. \"2026-05-12T09:00:00-07:00\")."
                        ],
                        "end_iso": [
                            "type": "string",
                            "description": "ISO 8601 datetime to stop checking at."
                        ]
                    ],
                    "required": ["start_iso", "end_iso"]
                ]
            ]
        ],
        [
            "type": "function",
            "function": [
                "name": "create_calendar_event",
                "description": "Propose a calendar event for the user to confirm. On iOS this opens the native event editor pre-filled with the supplied fields; the user reviews and taps Save (or Cancel). The tool result reports the outcome.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Event title."
                        ],
                        "start_iso": [
                            "type": "string",
                            "description": "ISO 8601 start datetime with timezone."
                        ],
                        "end_iso": [
                            "type": "string",
                            "description": "ISO 8601 end datetime with timezone."
                        ],
                        "location": [
                            "type": "string",
                            "description": "Optional location string."
                        ],
                        "notes": [
                            "type": "string",
                            "description": "Optional notes / description."
                        ],
                        "attendee_emails": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional list of attendee email addresses. Note: EventKit cannot programmatically add attendees, so the event editor pre-fills these in the notes; the user adds them manually in the editor sheet."
                        ]
                    ],
                    "required": ["title", "start_iso", "end_iso"]
                ]
            ]
        ]
    ]

    static let toolNames: Set<String> = [
        "list_upcoming_events",
        "check_calendar_availability",
        "create_calendar_event"
    ]

    func handles(functionName: String) -> Bool {
        return Self.toolNames.contains(functionName)
    }

    func statusText(for call: FunctionCallStruct) -> String? {
        switch call.name {
        case "list_upcoming_events":      return "checking your calendar"
        case "check_calendar_availability": return "checking your availability"
        case "create_calendar_event":
            if let title = call.arguments["title"] as? String, !title.isEmpty {
                return "drafting \"\(title)\" on your calendar"
            }
            return "drafting calendar event"
        default: return nil
        }
    }

    // MARK: - Dispatch

    func handle(functionCall: FunctionCallStruct,
                completion: @escaping (MessageStruct) -> Void) {
        let args = functionCall.arguments
        let name = functionCall.name

        // Auth check up front so every tool gets the same prompt-permission
        // error shape if the user hasn't granted Calendars access yet.
        requestAccessIfNeeded { granted in
            guard granted else {
                completion(Self.functionMessage(name: name, payload: [
                    "error": "calendar_permission_denied",
                    "hint": "The user hasn't granted calendar access yet. Tell them to open Settings → Integrations → Google Calendar and tap Connect, or to enable Loop in iOS Settings → Privacy → Calendars."
                ]))
                return
            }

            switch name {
            case "list_upcoming_events":
                let hours = (args["hours"] as? Int) ?? 24
                let limit = (args["limit"] as? Int) ?? 20
                self.listUpcomingEvents(hours: hours, limit: limit, completion: completion)
            case "check_calendar_availability":
                guard let startISO = args["start_iso"] as? String,
                      let endISO = args["end_iso"] as? String,
                      let start = Self.parseISO(startISO),
                      let end = Self.parseISO(endISO) else {
                    completion(self.missingArgs(for: name, expected: "start_iso, end_iso"))
                    return
                }
                self.checkAvailability(start: start, end: end, completion: completion)
            case "create_calendar_event":
                guard let title = args["title"] as? String,
                      let startISO = args["start_iso"] as? String,
                      let endISO = args["end_iso"] as? String,
                      let start = Self.parseISO(startISO),
                      let end = Self.parseISO(endISO) else {
                    completion(self.missingArgs(for: name, expected: "title, start_iso, end_iso"))
                    return
                }
                self.createEvent(title: title,
                                 start: start,
                                 end: end,
                                 location: args["location"] as? String,
                                 notes: args["notes"] as? String,
                                 attendeeEmails: args["attendee_emails"] as? [String],
                                 completion: completion)
            default:
                completion(MessageStruct(role: "assistant",
                                         content: "I don't know how to handle the calendar tool '\(name)'."))
            }
        }
    }

    // MARK: - Authorization

    /// Resolves to true if the app has full-access read+write to Calendars.
    /// On iOS 17+ uses the new requestFullAccessToEvents API; older OSes
    /// fall back to requestAccess(to:completion:). All paths complete on the
    /// main thread because callers may immediately update UI off the result.
    func requestAccessIfNeeded(completion: @escaping (Bool) -> Void) {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .authorized:
            DispatchQueue.main.async { completion(true) }
        case .denied, .restricted, .writeOnly:
            DispatchQueue.main.async { completion(false) }
        case .notDetermined:
            if #available(iOS 17.0, macOS 14.0, *) {
                eventStore.requestFullAccessToEvents { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            } else {
                eventStore.requestAccess(to: .event) { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            }
        @unknown default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    /// Cheap synchronous probe for the UI layer (`IntegrationsVC` row state).
    /// Doesn't trigger a permission prompt; if the answer is `.notDetermined`
    /// the UI shows "Tap to connect" and triggers the real request on tap.
    var currentAuthorizationStatus: EKAuthorizationStatus {
        return EKEventStore.authorizationStatus(for: .event)
    }

    // MARK: - Tool handlers

    private func listUpcomingEvents(hours: Int, limit: Int, completion: @escaping (MessageStruct) -> Void) {
        let start = Date()
        let end = start.addingTimeInterval(TimeInterval(max(hours, 1)) * 3600)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate).prefix(max(limit, 1))
        let payload: [String: Any] = [
            "events": events.map(Self.serialize(_:)),
            "window_start": Self.iso8601String(start),
            "window_end": Self.iso8601String(end),
        ]
        completion(Self.functionMessage(name: "list_upcoming_events", payload: payload))
    }

    private func checkAvailability(start: Date, end: Date, completion: @escaping (MessageStruct) -> Void) {
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let busy = eventStore.events(matching: predicate)
            .filter { $0.availability != .free }
            .map { (event: EKEvent) -> [String: Any] in
                return [
                    "title": event.title ?? "(no title)",
                    "start": Self.iso8601String(event.startDate),
                    "end": Self.iso8601String(event.endDate),
                ]
            }
        let payload: [String: Any] = [
            "window_start": Self.iso8601String(start),
            "window_end": Self.iso8601String(end),
            "busy": busy,
            "is_free": busy.isEmpty
        ]
        completion(Self.functionMessage(name: "check_calendar_availability", payload: payload))
    }

    private func createEvent(title: String,
                             start: Date,
                             end: Date,
                             location: String?,
                             notes: String?,
                             attendeeEmails: [String]?,
                             completion: @escaping (MessageStruct) -> Void) {
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        // EventKit doesn't expose programmatic attendee writes. Stuff the
        // proposed list into notes so the user sees it in the editor and
        // can add the real participants via the native attendee field.
        var noteParts: [String] = []
        if let notes = notes, !notes.isEmpty { noteParts.append(notes) }
        if let emails = attendeeEmails, !emails.isEmpty {
            noteParts.append("Suggested attendees: " + emails.joined(separator: ", "))
        }
        if !noteParts.isEmpty { event.notes = noteParts.joined(separator: "\n\n") }
        event.calendar = eventStore.defaultCalendarForNewEvents

        // iOS path: route through the host so the user gets the native
        // editor. The user's tap on Save IS the confirmation — no need to
        // ask in chat first.
        if let host = host {
            host.calendarSkillRequestsEventEditor(forEvent: event, eventStore: eventStore) { outcome in
                let payload: [String: Any] = [
                    "outcome": outcome.rawValue,
                    "title": title,
                    "start": Self.iso8601String(start),
                    "end": Self.iso8601String(end),
                ]
                completion(Self.functionMessage(name: "create_calendar_event", payload: payload))
            }
            return
        }

        // Mac (or any caller without a host): save directly. Mac users are
        // already confirming via the recorder bar's send button — the chat
        // turn is itself the confirmation step.
        do {
            try eventStore.save(event, span: .thisEvent)
            let payload: [String: Any] = [
                "outcome": "saved",
                "event_id": event.eventIdentifier ?? "",
                "title": title,
                "start": Self.iso8601String(start),
                "end": Self.iso8601String(end),
            ]
            completion(Self.functionMessage(name: "create_calendar_event", payload: payload))
        } catch {
            completion(Self.functionMessage(name: "create_calendar_event", payload: [
                "outcome": "failed",
                "error": error.localizedDescription
            ]))
        }
    }

    // MARK: - Helpers

    private func missingArgs(for name: String, expected: String) -> MessageStruct {
        return MessageStruct(role: "assistant",
                             content: "I need \(expected) to call \(name). Please provide them.")
    }

    private static func functionMessage(name: String, payload: Any) -> MessageStruct {
        let json: String
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let str = String(data: data, encoding: .utf8) {
            json = str
        } else {
            json = "{}"
        }
        return MessageStruct(role: "function", content: json, name: name)
    }

    /// ISO 8601 parser that tolerates the two flavors the model is likely
    /// to emit: with-fractional-seconds and without.
    private static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    private static func iso8601String(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static func serialize(_ event: EKEvent) -> [String: Any] {
        return [
            "title": event.title ?? "(no title)",
            "start": iso8601String(event.startDate),
            "end": iso8601String(event.endDate),
            "location": event.location ?? "",
            "calendar": event.calendar?.title ?? "",
            "all_day": event.isAllDay,
            "notes": event.notes ?? ""
        ]
    }
}
