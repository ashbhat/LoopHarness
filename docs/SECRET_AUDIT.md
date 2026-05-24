# Secret Audit — intel → LoopHarness export

Performed on the source working tree prior to the clean export. Values are
redacted; this document records *what was found and how it was remediated*,
not the secrets themselves. See [`../SECURITY.md`](../SECURITY.md) for the
rotation checklist.

## Summary

| Severity | Count | Categories |
|---|---|---|
| CRITICAL | 8 | Live API keys/tokens (OpenAI, ElevenLabs, Deepgram, Exa, Cursor, Obsidian, Notion ×2) |
| HIGH | 3 | Personal ngrok endpoint (×2), Apple Team ID |
| MEDIUM | 3 | Backend HMAC placeholder, demo bearer string, private backend hostname |
| LOW | 2 | Bundle/iCloud identifiers, doc placeholders |

## CRITICAL — live credentials (remediated + must rotate)

| Source (original) | Key | Remediation in LoopHarness |
|---|---|---|
| `LoopIOS/Info.plist`, `LoopMac/Info.plist` | `DEEPGRAM_API_KEY` | value → `$(DEEPGRAM_API_KEY)` placeholder |
| same | `ELEVEN_LABS_KEY` | → `$(ELEVEN_LABS_KEY)` |
| same | `EXA_API_KEY` | → `$(EXA_API_KEY)` |
| same | `OPENAI_API_KEY` (`sk-proj-…`) | → `$(OPENAI_API_KEY)` |
| `LoopIOS/Info.plist` (iOS) | `CURSOR_API_KEY` | → `$(CURSOR_API_KEY)` |
| same | `OBSIDIAN_API_KEY` | → `$(OBSIDIAN_API_KEY)` |
| `scripts/test_notion_notes.py`, `scripts/add_to_digital_vault.py` | Notion `ntn_…` token + private page ID | **files excluded from export entirely** |

`KeyStore.infoPlistValue` already treats a `$(`-prefixed value as absent and
falls back to the in-app Keychain entry flow, so the placeholder form is the
intended, build-safe state.

## HIGH

| Source | Finding | Remediation |
|---|---|---|
| `Info.plist` ×2 | `OBSIDIAN_BASE_URL` = personal reserved ngrok domain | → `$(OBSIDIAN_BASE_URL)` |
| `Loop.xcodeproj/project.pbxproj` (8×) | `DEVELOPMENT_TEAM = <team id>` | removed from pbxproj; sourced from gitignored `Secrets.xcconfig` (referenced as the project's base configuration). Contributors set their own team in their local copy of `Secrets.xcconfig`. |

## MEDIUM (`LoopIOS/Data/Cloud.swift`)

The `Cloud` class was sanitized in the initial export and has since been
stripped to a thin `chat()` shim that forwards to `AgentHarness` (the
original docgen backend never existed in OSS form, so the dead surface
was removed). The findings below are kept for historical context.

| Finding | Assessment | Remediation |
|---|---|---|
| `secretKey = "super_secret_key"` | literal placeholder, not a real secret (SHA-256 signing stub) | dead code removed |
| `"Bearer image_gen_token_123"` (×3) | placeholder-style demo bearer in dead Notion backend code | dead code removed; NotionSkill uses direct API |
| `url = "<private dev hostname>"` | private dev hostname | dead code removed |

## LOW

- `com.bhat.intel*` bundle / `iCloud.com.bhat.intel` / `group.com.bhat.intel`
  identifiers: public app identifiers, not secrets. Kept (owner-published).
  Optional rebrand is a Phase-3 follow-up.
- `LoopIOS/Specs/done/obsidian_integration_guide.md`: placeholder-only token
  references; the real ngrok host was scrubbed.

## Files excluded from the export (not copied into LoopHarness)

```
build/                 (2,687 artifacts — also held copies of every key above)
.claude/  .vscode/  LoopIOS/Specs/.claude/
scripts/test_notion_notes.py     scripts/add_to_digital_vault.py   scripts/__pycache__/
exp/  (real addresses in directions.py)
eiffel_tower_notes.md  voice_pipeline_redesign.md  what_aviso_can_do.md  agents.md
LoopIOS/sample.png  LoopIOS/sample_18bit.png  (unreferenced; real face)
**/.DS_Store  **/xcuserdata/  *.xcuserstate  intel.xcodeproj/ (empty stub)
readme.md (stale "VoterGuide" — replaced with new README.md)
```

## Result

The LoopHarness working tree contains no live credentials. Because the new
repository starts from a fresh `git init`, no secret ever enters its history.
Rotation of the previously-exposed keys is still required — see
[`../SECURITY.md`](../SECURITY.md).
