# CLAUDE.md

Guidance for AI coding agents working in **gigpkgs** (Gig's nixpkgs overlay — a
super-nixpkgs for the fleet).

## Branching & releases (roll-flow)

gigpkgs uses **roll-flow** (`github:gignsky/roll-flow/develop`) for branch and
release management. Name working branches accordingly.

- **Branch naming:** `roll/<issue#>-<MMDD>-<slug>`
  (e.g. `roll/3-0716-sequential-ids` — issue number, `MMDD` date, short slug).
- **Promotion model:** `roll/*` → `rolling` → `main` (`main` is the stable branch).
- **Cut rolls from `rolling`** and open PRs back **into `rolling`**; `rolling` is
  later promoted to `main`.

Configuration lives in `.roll-flow.toml` (`rolling_branch = "rolling"`,
`stable_branch = "main"`, `roll_prefix = "roll/"`).
