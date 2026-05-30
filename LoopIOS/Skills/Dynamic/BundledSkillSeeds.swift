//
//  BundledSkillSeeds.swift
//  Loop
//
//  Seeds the Workspace/Skills folder with starter skills on first launch.
//
//  We don't ship .js files as bundle resources — instead each seed's source is
//  a Swift string literal here, written into the workspace on first launch.
//  Keeps the file layout in the Xcode project trivial and avoids resource-
//  copy build phases.
//
//  There are currently no bundled seeds (`all` is empty), so this is a no-op;
//  the machinery is kept so a starter skill can be added later by appending a
//  `Seed` to `all`.
//

import Foundation

enum BundledSkillSeeds {

    /// One bundled skill: name, manifest description + parameter schema,
    /// and the literal JS source. Add new entries to `all` to ship starters.
    struct Seed {
        let name: String
        let description: String
        let parameters: [String: Any]
        let source: String
    }

    /// Run on AgentHarness init. For each seed, write it into the workspace
    /// only if the folder doesn't already exist — so user edits / deletions
    /// stick across launches and we never clobber custom changes.
    static func seedIfNeeded() {
        let registry = DynamicSkillRegistry.shared
        let fm = FileManager.default
        let root = registry.skillsRoot

        for seed in all {
            let folder = root.appendingPathComponent(seed.name, isDirectory: true)
            if fm.fileExists(atPath: folder.path) { continue }
            do {
                _ = try registry.writeSkill(
                    name: seed.name,
                    description: seed.description,
                    parameters: seed.parameters,
                    source: seed.source
                )
                print("BundledSkillSeeds: seeded \(seed.name)")
            } catch {
                print("BundledSkillSeeds: failed to seed \(seed.name) — \(error)")
            }
        }
    }

    static let all: [Seed] = []
}
