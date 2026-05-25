# Agent Instructions

## Branching and PRs

- **Open all PRs against `develop`**, not `main`.
- `develop` is the integration branch where agent work lands first.
- A scheduled job automatically opens a PR from `develop` to `main` once per day, so there is no need to target `main` directly.

## Workflow

1. Branch from `develop`.
2. Make your changes.
3. Open a PR back into `develop`.
4. The daily `develop` → `main` PR will pick up your merged work automatically.
