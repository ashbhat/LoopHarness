# Security Policy

## Reporting a vulnerability

Please report security issues privately by opening a
[GitHub security advisory](https://github.com/) on the repository (or email
the maintainer) rather than filing a public issue. We aim to acknowledge
reports within a few days.

## Credential model

LoopHarness never bundles API keys. Keys are entered in-app and stored in the
Apple Keychain (`intel/Settings/KeyStore.swift`). `Info.plist` entries use
`$(VAR)` placeholders, which `KeyStore` treats as *absent* — falling back to
the in-app entry flow. Nothing in this repository is a live credential.

## Automated scanning

Every push and pull request runs Gitleaks
(`.github/workflows/secret-scan.yml`). A detected secret fails CI.

---

## ⚠️ Secret rotation checklist (ACTION REQUIRED)

This repository is a **clean export**. However, the keys below previously
existed in the source working tree / backup history and **must be treated as
compromised**. Sanitizing files does *not* un-leak a key that lived on disk.
Rotate every credential below in its provider dashboard.

**Recommended order** (highest blast radius / billable first):

| # | Provider | Where it was | Action | Done |
|---|----------|--------------|--------|:----:|
| 1 | **OpenAI** | `Info.plist` (iOS + Mac) — `sk-proj-…` project key | Revoke the key at platform.openai.com → API keys; create a new one; set spend limits | ☐ |
| 2 | **ElevenLabs** | `Info.plist` — `sk_…` | Regenerate key in ElevenLabs profile/API settings | ☐ |
| 3 | **Deepgram** | `Info.plist` — 40-hex key | Delete & recreate the API key in Deepgram console | ☐ |
| 4 | **Exa** | `Info.plist` — UUID key | Rotate key in Exa dashboard | ☐ |
| 5 | **Cursor** | `Info.plist` (iOS) — `crsr_…` | Revoke/rotate in Cursor account settings | ☐ |
| 6 | **Notion** | `scripts/*.py` — `ntn_…` integration token | Refresh the internal integration secret in Notion → My integrations; the personal page ID it referenced was also exposed | ☐ |
| 7 | **Obsidian relay** | `Info.plist` — bearer + personal ngrok URL | Generate a new relay bearer token; rotate/replace the ngrok reserved domain | ☐ |
| 8 | **Backend** (`Cloud.swift`) | `super_secret_key` shared-secret placeholder + private dev hostname | If a real backend exists, rotate its `SECRET_KEY` and treat the prior signing scheme as known | ☐ |

> **Apple Team ID.** Not strictly a secret (it's embedded in any shipped
> binary), but it ties the repo to a specific developer account. LoopHarness
> keeps it out of the tree by reading `DEVELOPMENT_TEAM` from a gitignored
> `Secrets.xcconfig` referenced as the project's base configuration.
> See `Secrets.xcconfig.example`.

After rotating, also confirm:

- [ ] The original private backup repository is **kept private** — it still
      contains the live keys in its history. Do not make it public.
- [ ] No CI/deployment system still references the old keys.
- [ ] `git log -p` on this `LoopHarness` repo shows the keys never entered its
      history (it starts from a clean root commit).

See [`docs/SECRET_AUDIT.md`](docs/SECRET_AUDIT.md) and
[`docs/PERSONAL_DATA_AUDIT.md`](docs/PERSONAL_DATA_AUDIT.md) for the full
inventory and remediation record.
