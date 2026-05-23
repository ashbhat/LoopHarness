# License Recommendation

> Decision pending — no `LICENSE` file is committed yet. Until one is added,
> all rights are reserved by the author. This document is a recommendation
> for the maintainer to choose from (Phase 6.1).

## Options compared

| License | Permissiveness | Patent grant | Copyleft | Best when you want… |
|---|---|---|---|---|
| **MIT** | Maximal | No explicit | None | Widest adoption, minimal friction, embed-anywhere |
| **Apache-2.0** | Maximal | **Yes (explicit)** | None | Wide adoption *plus* patent protection & contributor clarity |
| **GPL-3.0** | Strong copyleft | Yes | Strong | Force downstream forks to stay open |
| **Source-available** (BSL/Elastic/PolyForm) | Restricted | Varies | N/A | Block commercial competitors while keeping source public |

## Recommendation: **Apache-2.0**

Rationale for LoopHarness specifically:

1. **Adoption** — for a developer platform meant to attract contributors and
   integrators, a permissive license maximizes uptake. MIT and Apache-2.0
   both achieve this; GPL deters commercial/app-store adoption (and iOS App
   Store distribution has known GPL friction).
2. **Patent grant** — LoopHarness involves agent orchestration, voice pipeline,
   and skill-dispatch techniques. Apache-2.0's explicit patent license
   protects users and contributors in a way MIT does not, which matters as
   the project and its contributor base grow.
3. **Contributor clarity** — Apache-2.0's contribution terms (§5) reduce the
   need for a separate CLA for most projects.
4. **Strategic optionality** — permissive licensing keeps the door open for
   a future hosted/commercial offering without relicensing pain. If
   protecting against a cloud competitor later becomes a priority, a
   source-available license (e.g. BSL with a time-delayed Apache conversion)
   is the fallback — but that is premature at launch and harms early
   community trust.

### Next steps for the maintainer

- [ ] Decide: **Apache-2.0** (recommended) vs MIT vs source-available.
- [ ] Add a top-level `LICENSE` file with the chosen license text.
- [ ] Add SPDX headers or a license note as desired.
- [ ] Update the License section of `README.md`.
- [ ] (Apache-2.0) optionally add a `NOTICE` file.
- [ ] Run the third-party dependency license audit (Phase 6.2) before
      finalizing — confirm no incompatible bundled code/assets.
