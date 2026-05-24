# Personal-Data Audit — intel → LoopHarness export

Privacy review performed on the source working tree before export. Records
what personal/internal data was found and how it was handled.

## Summary

| Action | Count |
|---|---|
| Excluded entirely | 11 paths |
| Replaced with synthetic / generic | 5 |
| Sanitized in place | 8 |
| Reviewed, kept (no PII) | — |

## Excluded entirely (never copied into LoopHarness)

- `build/` — tracked build tree; held copies of live keys, a
  `settings.local.json`, copied specs, and thousands of absolute
  `/Users/<user>/...` paths.
- `.claude/`, `.vscode/`, `LoopIOS/Specs/.claude/` — AI-assistant / editor
  local scratch config (hardcoded personal paths).
- `eiffel_tower_notes.md` — personal scratch note.
- `voice_pipeline_redesign.md` — internal unreleased design doc (personal
  paths, references to a separate private project).
- `what_aviso_can_do.md` — describes a separate, unrelated private project.
- `agents.md` (root) — personal to-do/notes.
- `exp/directions.py` — real San Francisco home/test addresses.
- `scripts/test_notion_notes.py`, `scripts/add_to_digital_vault.py` — live
  Notion token + private workspace page IDs (also a Phase-1 secret finding).
- `LoopIOS/sample.png`, `LoopIOS/sample_18bit.png` — photo of a real
  identifiable person; unreferenced by any code.
- `**/.DS_Store`, `**/xcuserdata/`, `*.xcuserstate` — macOS/Xcode per-user
  state; directory names embedded the owner's username.

## Replaced with synthetic / generic

| Path | Was | Now |
|---|---|---|
| `readme.md` | stale "VoterGuide" copy | new `README.md` for LoopHarness |
| `LoopIOS/Specs/done/self_improvment_spec.md` | "Ash, SF, builds products"; "Ash's dog is named Luna" | "Alex, NYC, builds products"; "The user's dog is named Rex" |
| `LoopIOS/Specs/done/obsidian_spec.md` | real iCloud vault path; an itinerary naming a real person and real local events | `~/Library/.../<Your Vault>` placeholder; generic synthetic itinerary |
| `LoopIOS/Specs/done/obsidian_integration_guide.md` | real reserved ngrok host | `your-domain.ngrok-free.dev` |
| `exp/directions.py` | real addresses | excluded entirely (above) |

## Sanitized in place

| Path | Change |
|---|---|
| `LoopIOS/Info.plist`, `LoopMac/Info.plist` | keys + ngrok URL → `$(VAR)` placeholders |
| `LoopIOS/SpeechPipeline/SpeechSanitizer.swift` | comment example personal path → `/Users/you/…` |
| `LoopMac/TerminalSkill.swift` | tool-description example personal path → `/Users/you/code/my-repo` |
| `Loop.xcodeproj/project.pbxproj` | `DEVELOPMENT_TEAM` removed; sourced from gitignored `Secrets.xcconfig` |

## Reviewed and intentionally kept

- `// Created by Ash Bhat` source headers — standard authorship attribution
  for an owner-published OSS project. Not a leak.
- `aura-2-luna-en` / "Luna" in `MessagingVC.swift` & `MacTTS.swift` — a
  Deepgram TTS *voice name*, unrelated to the personal example.
- `com.bhat.intel*` identifiers — public app identifiers; optional
  rebranding deferred to Phase 3 (repository restructuring).

## Result

No personal notes, private infrastructure paths, real addresses, third-party
names, or identifiable media remain in the LoopHarness working tree.
