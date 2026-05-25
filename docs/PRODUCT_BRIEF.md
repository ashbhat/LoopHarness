# Loop — Product Brief

A primer for the creative team building Loop's website, identity, and visual
language. The goal of this doc is to convey what Loop *is*, who it's for, and
what makes it feel different from the wall of "AI assistant" products it will
sit next to.

---

## What Loop is

**Loop is a personal AI assistant that lives on your own devices.**

It runs as native apps for **iOS**, **macOS** (menu-bar + window), and
**visionOS**. You can type to it, talk to it (push-to-talk), or trigger it
from a Share Sheet. It can remember you across conversations, take real
actions in the tools you already use, and quietly do work in the background
while you're doing something else.

Under the hood is an open-source runtime called **LoopHarness** — the agent
loop, the skill/tool system, the memory store, the voice pipeline. Loop is
the product; LoopHarness is the engine. The website should sell **Loop**;
the existence of LoopHarness is part of the trust story (you can see exactly
what it's doing, and you can run it yourself).

## What makes Loop different

Most AI assistants are someone else's web app that occasionally calls a tool.
Loop is the opposite shape:

1. **It lives on your devices, not in a tab.**
   A real iOS app. A real macOS menu-bar app. A real visionOS app. It is
   present the way Messages or Notes is present — not the way a website is.

2. **You bring your own keys.**
   Loop ships with no API keys baked in. Users plug in their own (OpenAI,
   Deepgram, ElevenLabs, Exa, etc.) and those keys go into the Apple
   Keychain. Nothing routes through a Loop server, because there isn't one.

3. **It has memory of *you*.**
   Loop maintains a long-term, Markdown-based memory store on device. Over
   time it learns your role, your projects, your preferences, the people in
   your life, the way you like to be talked to. The user can read and edit
   every memory — it's not a black box.

4. **It does work, not just chat.**
   Loop has a growing library of *skills* — modular tools that let it act
   in the real world: read/write your Obsidian vault, query Notion, check
   your calendar, control Music, fetch from the web, search with Exa, post a
   tweet, open a PR on GitHub, run a terminal command, summarize a PDF, pull
   Apple Health data, generate an image or short video, schedule a future
   task, and so on. New skills get added regularly; Loop can also *author its
   own skills* at runtime.

5. **It can keep working when you walk away.**
   Loop can spawn **sub-agents** — isolated agents that go off and do
   multi-step work in the background (research a topic, draft something,
   monitor an external state) and report back. There's a scheduler for
   recurring or idle work.

6. **It's voice-first when you want it to be.**
   On Mac there's a global push-to-talk hotkey: hold a key, speak, release,
   listen. The Vision target leans even harder into voice + an animated orb
   avatar. STT and TTS are pluggable (Deepgram, ElevenLabs, or Apple's
   built-ins).

7. **It is open source.**
   Apache-2.0. Anyone can read the entire codebase, fork it, or run their
   own build. This is a deliberate trust signal — Loop touches your calendar,
   your notes, your health data; you should be able to see what it's doing.

## Who Loop is for

The primary user is someone who already lives inside their tools — a
**maker**, **operator**, **founder**, **researcher**, or **technical
creative** — who wants:

- a single conversational surface across their devices,
- an assistant that actually knows them, instead of starting from zero
  every session,
- the ability to wire it up to *their* stack (Obsidian, Notion, GitHub,
  Calendar, Music, Health, etc.),
- control over their data and their model provider.

It is **not** an enterprise SaaS, not a customer-support bot, not a
chat-with-your-PDFs tool. It's closer in spirit to a personal operating
layer — the assistant character from sci-fi, but made of real, inspectable
parts.

## The shape of a Loop interaction

A few concrete vignettes the design team can hold in their head:

- **At the desk.** A founder is in their editor. They hold the Mac
  hotkey: *"open the doc I was editing last night and add a section on
  pricing — pull the numbers from the Notion page called Q3 Plan."* Loop
  speaks back as it works, opens the doc, edits it, and confirms.

- **On the phone.** Walking between meetings, they tap the iOS app and
  speak: *"start a sub-agent — go research the three companies on my
  calendar today and leave me notes in Obsidian."* The sub-agent runs in
  the background; a notification arrives when it's done.

- **In the headset.** In the Vision app, an animated orb listens. They
  ask it about their week. It pulls from calendar, mail, health, recent
  notes — and answers as ambient voice with a soft visual response.

- **Over time.** Loop remembers that they prefer terse answers, that
  "the client" means a specific person, that Thursdays are no-meeting days.
  None of that had to be configured.

## Surfaces / form factors

The brand will need to live across a few distinct surfaces:

- **iOS app** — full conversational UI, message bubbles, share-sheet
  extension, side drawer, settings.
- **macOS app** — menu-bar presence, floating recorder window, full
  conversation windows, settings, sub-agent inspector, scheduled-task UI.
- **visionOS app** — voice-led, orb-avatar centric, ambient.
- **Website** (what the creative team is building) — the front door.
  Should explain Loop to someone who has never heard of it, demonstrate
  what it feels like to use, and route the technically curious into the
  open-source repo.

## Brand cues to pull from

Things that feel true to Loop and worth leaning into:

- **The name.** *Loop* — the turn loop of an agent (listen → think →
  act → listen), but also a loop you bring someone into. Both readings
  are intentional. A circle, a return, a continuous thread.
- **An assistant with a body.** The Vision target has an **orb avatar**
  that pulses and reacts to voice. That orb is a strong candidate for a
  recurring visual motif across surfaces.
- **Local and personal.** The opposite of a server farm. Think more like
  a well-made object on your desk than a SaaS dashboard.
- **Markdown, plain text, your file system.** Loop's memory and notes
  are real Markdown files in real folders. The aesthetic should hint at
  legibility, ownership, craft — not glossy "AI magic."
- **Voice as a first-class input.** Visual language should accommodate
  the absence of a screen — sound, motion, ambient presence.
- **Open and inspectable.** Confident enough to publish its own
  source. This isn't a black box you have to trust; it's a tool you can
  read.

## Brand cues to avoid

The category is full of clichés. Loop should not look like:

- Generic "AI" gradient + sparkle aesthetic (lavender → cyan, magic
  wand iconography, etc.).
- Sci-fi HUD / circuit-board / cyberpunk visuals.
- Faceless enterprise SaaS (stock photography of diverse teams at
  laptops, "Trusted by" logo walls).
- A chatbot avatar with a human face or a cartoon mascot.
- Anything that implies Loop is a service running in the cloud that
  you log into. It isn't.

## Tone of voice

- **Direct, calm, literate.** Talks to the user like a competent
  collaborator, not a hype-driven product.
- **Concrete over abstract.** "Reads your Obsidian vault" beats
  "knowledge integration." "Holds a key and speaks" beats "frictionless
  voice experience."
- **Quietly confident about the open-source / local-first story.** Not
  preachy about it. It's a fact, not a manifesto.
- **First-person comfortable.** Loop can refer to itself. It is a
  *who*, not a *what* — but a restrained one, no forced personality.

## One-liners (working drafts)

Useful as starting points for headlines / meta descriptions. Not final.

- *A personal AI assistant that lives on your devices.*
- *Loop runs on your Mac, your phone, and your headset — with your keys,
  your tools, and your memory.*
- *The assistant from sci-fi, made of real, inspectable parts.*
- *Hold a key. Speak. Loop listens, remembers, and gets to work.*

## What the website needs to do

In rough priority order:

1. **Communicate the product in 5 seconds** — what it is, what
   surfaces it runs on, what it feels like.
2. **Show it in motion** — voice, the orb, a real interaction across
   devices. Static screenshots will undersell it.
3. **Make the local-first / BYOK story land** as a feature, not a
   caveat — this is a differentiator most competitors literally cannot
   match.
4. **Route the curious** — download/TestFlight for end users, GitHub
   for builders, a short "how it works" for the skeptical.
5. **Set tone.** Even visitors who don't install should leave with a
   clear sense of who Loop is for and what it stands for.

## Reference points (for orientation, not imitation)

- The texture and confidence of **Linear**'s product site (without the
  enterprise edges).
- The "object on your desk" feeling of **Things** or **iA Writer**
  rather than the "platform" feeling of a typical AI startup.
- The voice/ambient interaction model of **Siri** or the Movie *Her*'s
  OS — but grounded, useful, and inspectable rather than ethereal.

---

*Maintained by the Loop team. Questions, corrections, or things this
doc should also cover — open an issue or ping Ash.*
