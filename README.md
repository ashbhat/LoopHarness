# LoopHarness

> An open, local-first agent harness for iOS and macOS. Persistent memory,
> autonomous sub-agents, a pluggable skill system, and a voice pipeline —
> running on your device, with your own API keys.

LoopHarness is the open-source codebase behind **Loop**, a personal AI assistant.
It is a *general agent harness*: a runtime that takes natural-language input
(typed or spoken), routes it through a skill/tool dispatcher, can spawn
sub-agents for long-running work, and persists what it learns across
conversations.

> [!IMPORTANT]
> **Bring your own keys.** LoopHarness ships with **no** API keys. You provide
> your own (OpenAI, Deepgram, ElevenLabs, Exa, etc.) in-app under
> **Settings → Integrations**; they are stored in the system Keychain and
> never leave your device except to the provider you configured.

---

## Features

- **Agent harness** — a turn-based runtime (`LoopIOS/AgentHarness/`) that
  orchestrates model calls, tool/skill dispatch, and context management.
- **Skill system** — modular, self-describing tools under `LoopIOS/Skills/`
  (FileSystem, Exa web search, Obsidian, Notion, Music, Git, URL fetch, and
  dynamically authored skills).
- **Persistent memory** — local Markdown-based memory and conversation
  storage; the agent reads and writes its own long-term knowledge.
- **Sub-agents** — spawn isolated agents for multi-step background tasks
  (`LoopIOS/SubAgents/`).
- **Voice pipeline** — push-to-talk capture, Deepgram STT, ElevenLabs/Apple
  TTS, and speech sanitization (`LoopIOS/SpeechPipeline/`, `LoopMac/`).
- **Obsidian integration** — read/write an Obsidian vault through a
  self-hosted relay.
- **Scheduling** — background task scheduling for periodic/idle work.
- **Local-first** — credentials in the Keychain, memory/conversations on
  device; you choose which providers it talks to.

## Architecture

```
LoopIOS/               iOS app
  AgentHarness/         turn loop, slash commands, skill dispatch
  Skills/               pluggable tools (FileSystem, Exa, Obsidian, Notion, …)
  SubAgents/            isolated multi-step agents
  SpeechPipeline/       STT/TTS + sanitization
  Settings/KeyStore     Keychain-first credential store
  Data/                 conversation + memory persistence
LoopMac/               macOS app (menu-bar, voice, terminal skill)
LoopShare/             iOS share extension
LoopIOSShare/ LoopMacShare/   share-extension targets
scripts/               Python helper/deploy utilities
Loop.xcodeproj         the Xcode project (app product name: "Loop")
```

See [`docs/`](docs/) for license rationale.

## Setup

**Requirements:** macOS with Xcode 15+, an Apple Developer account (free tier
is fine for local builds).

1. Clone, then copy `Secrets.xcconfig.example` → `Secrets.xcconfig` and
   set `DEVELOPMENT_TEAM` to your 10-char Apple Developer Team ID. The
   project's base configuration already references `Secrets.xcconfig` (which
   is gitignored), so no Xcode GUI step is needed.
2. Open `Loop.xcodeproj` in Xcode and confirm your team under
   **Signing & Capabilities** (it should already be populated from the
   xcconfig). Leaving `DEVELOPMENT_TEAM` blank is fine for simulator builds.
3. Build & run the **Loop** scheme (iOS) or **LoopMac** scheme (macOS).
4. On first launch, open **Settings → Integrations** and add the API keys
   for the providers you want (at minimum an LLM key).

Optional: to bake API keys in at build time instead of entering them in-app,
add them to the same `Secrets.xcconfig` (see comments in
`Secrets.xcconfig.example`). For the Python scripts, copy `.env.example` →
`.env`.

## Security & privacy

This repository contains no live credentials. Keys are entered in-app and
stored in the Apple Keychain; see [`SECURITY.md`](SECURITY.md) for the full
security policy. Secret scanning runs in CI on every push
(`.github/workflows/secret-scan.yml`). To report a vulnerability, see
`SECURITY.md`.

## Integrations

### Higgsfield — AI video generation

Loop can generate cinematic videos through the
[Higgsfield Cloud](https://cloud.higgsfield.ai/) API. The integration
surfaces three agent tools:

| Tool | Purpose |
|------|---------|
| `higgsfield_generate_video` | Start a generation job (returns a `request_id` immediately). |
| `higgsfield_check_video` | Poll a job's status; returns `video_url` when complete. |
| `higgsfield_list_models` | List available models (Sora 2, Veo 3, Kling 2.1, Seedance, DoP, Flux, Soul). |

**Setup:** paste your `KEY_ID:KEY_SECRET` credentials (from
*cloud.higgsfield.ai → API Keys*) into **Settings → Keys → Higgsfield**.
The key is stored in the Keychain and never leaves your device except to
Higgsfield's servers.

**Async job pattern:** generation is asynchronous — `higgsfield_generate_video`
returns instantly with a `request_id`. The agent then polls
`higgsfield_check_video` until the status reaches `completed` (or a terminal
state like `failed` / `nsfw`). Pricing is credit-based on Higgsfield Cloud;
failed or moderation-flagged jobs are automatically refunded.

If the API key is not set, any Higgsfield tool call returns
`{"error": "higgsfield_not_connected"}` with a hint to configure the key.

## Status

Early open-source release. APIs and structure will change. Contributions and
issues welcome.

## License

[Apache-2.0](LICENSE) — see [`docs/LICENSE_RECOMMENDATION.md`](docs/LICENSE_RECOMMENDATION.md)
for the rationale behind this choice.
