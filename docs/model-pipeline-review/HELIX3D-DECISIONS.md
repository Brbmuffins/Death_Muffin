# Helix3D decisions

This page records only accepted decisions and explicit approvals from Helix or the owner, quoting their words. An agent's recommendation, a review verdict or technical readiness is not a decision and is not recorded here.

**How to add an entry**
- Use the next number.
- Give the date, who decided, where they said it, a short verbatim quote, and what it allows and does not allow.
- The agent that heard the decision records it. If the other agent thinks an entry is wrong, it says so in its own file; it doesn't edit the entry.
- An entry is never rewritten. A later decision that changes it says which entry it replaces.

## Decisions

### H1: Helix3D planning direction (2026-11-06)

- **Who and where:** Helix, in the assignment brief given to Claude.
- **Words:**
  - "Our agreed direction is to modify, separate, and extend the existing pipeline into Helix3D while preserving the full vision."
  - "We have approved the planning direction only."
- **Allows:**
  - The requirements and seven-step roadmap quoted in [HELIX3D-PLAN.md](HELIX3D-PLAN.md).
  - A read-only assessment and a first-milestone proposal. Claude delivered both on 2026-11-06.
- **Does not allow:** any implementation. "Each implementation milestone requires a separately approved scope." The assignment also excluded file edits, installs, model downloads, generation, build or performance jobs, spending, service changes, commits and deploys.

### H2: Tripo models were bought on paid credits (2026-11-06)

- **Who and where:** Helix, in reply to the Milestone 1 proposal's only open question.
- **Words:** "tripo models were paid for"
- **Means:** the licence ledger records every Tripo model as paid-plan output.
- **Does not allow:** Tripo spending, which stays paused.

### H3: This documentation handoff (2026-11-06)

- **Who and where:** Helix, in the handoff setup brief given to Claude.
- **Allows:**
  - Creating the `helix3d-handoff` branch and these five documents in `docs/model-pipeline-review/`.
  - Setting up normal GitHub sign-in on Helix's PC with Helix's own account.
  - A small documentation-only commit from each side to prove access.
- **Words:** "Documentation-only is our working scope". "Do not merge it into the game's production branch as part of this assignment."
- **Does not allow:**
  - Game changes, generation jobs, spending or deploys.
  - Installations, unless explained and approved first.
  - Copying or sharing any credential.

## Not approved yet

- **Milestone 1:** preserve the baseline, plus the stage-capture pilot on the Gravecaller. See [CLAUDE-STATUS.md](CLAUDE-STATUS.md#milestone-1-proposal-as-delivered-2026-11-06), section D, for exactly what it would need approved.
