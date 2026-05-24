//
//  MusicMoodMap.swift
//  Loop
//
//  Translates a short mood vocabulary the model uses ("focused", "calm",
//  "energetic", …) into MusicKit search keywords + filter hints. Used by
//  MusicSkill's set_music_mood and find_music tools, and also documented in
//  MusicSkill.systemPromptFragment so the model uses the same vocabulary.
//

import Foundation

enum MusicMood: String, CaseIterable {
    case focused
    case calm
    case energetic
    case melancholy
    case upbeat
    case ambient
    case study
    case workout
    case sleep

    /// Search query handed to `MusicCatalogSearchRequest`. Intentionally a
    /// short curated phrase rather than a single keyword — Apple Music's
    /// catalog is large enough that mood phrases like "lo-fi study beats"
    /// produce more focused hits than bare keywords.
    var searchQuery: String {
        switch self {
        case .focused:    return "deep focus instrumental"
        case .calm:       return "calm ambient"
        case .energetic:  return "energetic upbeat playlist"
        case .melancholy: return "melancholy piano"
        case .upbeat:     return "feel good upbeat"
        case .ambient:    return "ambient soundscape"
        case .study:      return "lo-fi study beats"
        case .workout:    return "workout high energy"
        case .sleep:      return "sleep ambient piano"
        }
    }

    /// Whether the mood is intrinsically instrumental (vocals would fight
    /// with conversation). Used to default `instrumental_only=true` when
    /// the agent picks a focus/study/sleep mood.
    var prefersInstrumental: Bool {
        switch self {
        case .focused, .study, .ambient, .sleep, .calm:
            return true
        case .energetic, .melancholy, .upbeat, .workout:
            return false
        }
    }
}

enum MusicMoodMap {

    /// Best-effort parse of a free-form mood string from the model. Falls
    /// through to `.calm` if nothing matches so the agent never gets stuck.
    static func parse(_ raw: String?) -> MusicMood {
        guard let raw = raw?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .calm }

        if let direct = MusicMood(rawValue: raw) { return direct }

        // A small set of synonyms — keeps the model's life easy.
        switch raw {
        case "focus", "concentration", "deep work", "deepwork":  return .focused
        case "relaxed", "chill", "mellow", "soft":               return .calm
        case "happy", "happy mood", "good vibes":                return .upbeat
        case "sad", "blue", "down":                              return .melancholy
        case "background", "wallpaper":                          return .ambient
        case "studying", "homework", "reading":                  return .study
        case "exercise", "running", "lifting", "gym":            return .workout
        case "bedtime", "night", "rest":                         return .sleep
        case "hype", "pump", "pumped", "high energy":            return .energetic
        default:                                                  return .calm
        }
    }

    /// The list of accepted mood words baked into the system prompt so the
    /// model uses the same vocabulary the parser knows about.
    static let vocabularyList: String = MusicMood.allCases
        .map { $0.rawValue }
        .joined(separator: ", ")
}
