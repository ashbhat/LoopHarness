//
//  BundledSkillSeeds.swift
//  Loop
//
//  Seeds the Workspace/Skills folder with starter skills on first launch so
//  the user can run a real, working hot-loaded skill immediately. Without
//  this, the spec's "create a skill that summarizes Polymarket" user story
//  would require the user (or model) to author the JS by hand before there's
//  any proof the runtime works.
//
//  We don't ship .js files as bundle resources — instead the seed source is a
//  Swift string literal here, written into the workspace on first launch.
//  Keeps the file layout in the Xcode project trivial and avoids resource-
//  copy build phases.
//

import Foundation

enum BundledSkillSeeds {

    /// One bundled skill: name, manifest description + parameter schema,
    /// and the literal JS source. Add new entries here to ship more
    /// starters.
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

    static let all: [Seed] = [polymarketTrending]

    // MARK: - Polymarket

    /// Hits Gamma — Polymarket's public REST API for market data — pulls the
    /// top markets by 24h volume, and composes a short summary that doubles
    /// as a snapshot of what the world is currently betting on. No auth
    /// required.
    private static let polymarketTrending = Seed(
        name: "polymarket_trending",
        description: "Fetch the top trending Polymarket markets and summarize the major events the world is currently betting on.",
        parameters: [
            "type": "object",
            "properties": [
                "limit": [
                    "type": "integer",
                    "description": "How many trending markets to summarize. Defaults to 8."
                ]
            ],
            "required": [String]()
        ],
        source: #"""
        // Polymarket trending markets → world-events digest.
        //
        // The Gamma API at https://gamma-api.polymarket.com/markets is a
        // public, unauthenticated JSON endpoint. We sort by 24h volume to get
        // a feed of "what people are actually putting money on right now"
        // and turn that into a short summary the model can read back.
        async function run(args, host) {
            const limit = (args && args.limit) || 8;
            host.log("Fetching trending Polymarket markets...");

            const url = "https://gamma-api.polymarket.com/markets"
                + "?active=true&closed=false&order=volume24hr&ascending=false"
                + "&limit=" + encodeURIComponent(limit);

            const res = await host.http({
                url: url,
                method: "GET",
                headers: { "Accept": "application/json" }
            });

            if (res.status !== 200 || !res.json) {
                return {
                    status: "error",
                    error: "Polymarket Gamma returned HTTP " + res.status,
                    body: (res.body || "").slice(0, 500)
                };
            }

            const rows = Array.isArray(res.json) ? res.json : [];
            if (rows.length === 0) {
                return {
                    summary: "Polymarket returned no active markets — try again in a moment.",
                    markets: []
                };
            }

            host.log("Got " + rows.length + " markets, summarizing...");

            // Each market has a `question` and `outcomePrices` (array of JSON-
            // encoded probability strings). Pull the yes-price for the primary
            // outcome so we have a single number to talk about.
            const markets = rows.map(function(m) {
                let yes = null;
                try {
                    const prices = typeof m.outcomePrices === 'string'
                        ? JSON.parse(m.outcomePrices)
                        : (m.outcomePrices || []);
                    if (prices.length > 0) yes = parseFloat(prices[0]);
                } catch (e) {}
                return {
                    question: m.question || m.slug || "(untitled market)",
                    yes_probability: yes,
                    volume_24hr: m.volume24hr || 0,
                    end_date: m.endDate || null,
                    slug: m.slug || null
                };
            });

            const lines = markets.slice(0, limit).map(function(m, i) {
                const pct = (m.yes_probability != null)
                    ? Math.round(m.yes_probability * 100) + "%"
                    : "??";
                return (i + 1) + ". " + m.question + " — " + pct + " yes";
            });

            const summary =
                "Top " + lines.length + " markets by 24h volume:\n" + lines.join("\n");

            return {
                summary: summary,
                markets: markets,
                fetched_at: new Date().toISOString()
            };
        }
        """#
    )
}
