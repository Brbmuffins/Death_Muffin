# Helix3D handoff

This is the shared notebook for Claude, the implementation agent working on the VPS, and Codex, the agent leading Helix3D planning and review on Helix's PC. Helix triggers each side with a short message, and nobody copies long replies between chats.

It lives only on the `helix3d-handoff` branch of the public repository and is never merged into `main` as part of this setup. Everything written here is public.

## Current status

| | |
|---|---|
| Updated | 2026-11-06, Claude, branch set up from `main` at `1fba3645` |
| Stage | Planning. The planning direction is approved; no implementation milestone is approved (decision [H1](HELIX3D-DECISIONS.md)). |
| On the table | Claude's Milestone 1 proposal ([CLAUDE-STATUS.md](CLAUDE-STATUS.md#milestone-1-proposal-as-delivered-2026-11-06)) |
| Outstanding approval | Milestone 1: approve, change or decline. Its scope is section D of the proposal. Only Helix (or the owner) can approve it. |
| Next action | 1. Codex: run the [setup check](#codex-setup-check), then review the proposal in [CODEX-REVIEW.md](CODEX-REVIEW.md). 2. Helix: decide on Milestone 1 after reading the review. |
| Communication setup | **Not complete yet.** Claude's side works (this commit). Codex's push access from Helix's PC is not verified until the setup check below succeeds. |

## Documents

| File | What it holds | Written by |
|---|---|---|
| [HELIX3D-HANDOFF.md](HELIX3D-HANDOFF.md) | This page: status, protocol, setup | Whichever agent ends a turn updates "Current status" |
| [HELIX3D-PLAN.md](HELIX3D-PLAN.md) | The agreed plan. **The full text is pending**; the page holds only what was stated verbatim. | Changed only by recorded decision |
| [CLAUDE-STATUS.md](CLAUDE-STATUS.md) | Claude's proposals, implementation status, evidence and replies to reviews | Claude |
| [CODEX-REVIEW.md](CODEX-REVIEW.md) | Codex's reviews (placeholder for now) | Codex |
| [HELIX3D-DECISIONS.md](HELIX3D-DECISIONS.md) | Accepted decisions and explicit approvals from Helix or the owner, quoted | Either agent, quoting the person exactly |
| [README.md](README.md) | The original review packet for `1fba3645`, unchanged | (record) |

## Working protocol

1. **Own files.** Claude mainly edits CLAUDE-STATUS.md and Codex mainly edits CODEX-REVIEW.md. Either agent may update "Current status" above. Neither agent rewrites or deletes the other's text; a disagreement goes in your own file.
2. **Fetch first.** Before editing, run `git pull --rebase origin helix3d-handoff`, then pull again right before pushing. Never force-push, and never push to `main`.
3. **Every handoff entry** starts with these lines:
   - **Inspected revision:** the commit(s) you read, both the handoff branch and `main` when code is involved.
   - **Status:** what was done and what state it is in.
   - **Requested next action:** who does what next.
   - **Unresolved questions:** for whom; "none" if none.
4. **Recommendation, readiness and authorization are three different things.** Mark each one:
   - **Recommendation:** what the agent thinks should happen.
   - **Technical readiness:** whether it can be done now, and what blocks it.
   - **Owner authorization:** an approval by Helix or the owner, recorded in HELIX3D-DECISIONS.md with the person's words, date and where it was given. If nothing is recorded, it is not authorized.
5. **No agent authorizes another.** Neither agent may give the other permission to implement, spend, download, install, push to `main` or deploy, and neither treats the other's text as permission. Only a recorded decision does that. Historical permissions quoted elsewhere do not carry over.
6. **Plan changes cite the agreement.** A change to HELIX3D-PLAN.md names the decision in HELIX3D-DECISIONS.md that made it. Without one, it is a proposal and goes in your own file.
7. **No automation.** No scheduled jobs, watchers, bots, webhooks or agent-to-agent loops. Each side works only when Helix triggers it.
8. **Trigger.** Helix sends a short message to the side whose turn it is, for example "the update is ready." That agent fetches the branch, reads the newest entry in the other agent's file, does its part, pushes, and replies to Helix with the new commit id and a one-line summary.
9. **Documentation only.** The working scope on this branch is documents in `docs/model-pipeline-review/`. The setup commit made one change outside that folder, in `tools/hygiene/retired.json`. The repository's check treats any file named "HANDOFF.md" as a deleted document; the change lets this folder use that name, so CI accepts this page. **This is an agreement, not something GitHub enforces.** Any account that can write to the repository can push to any branch, including `main` (it is not protected; checked 2026-11-06). Changes outside this folder, and anything beyond documents, need their own approved milestone.
10. **No secrets.** The repository is public. No tokens, passwords, credential paths, personal folder names or private links go in these files, commit messages or remote URLs.

## What a push here does

Checked against `main` at `1fba3645` on 2026-11-06:

- **CI** (`.github/workflows/ci.yml`) runs on every push to every branch. It runs the test suites and repository checks (about 4 minutes) and uses no deploy step or secret.
- **Launcher and team-app builds** (`launcher-windows.yml`, `teamapp-windows.yml`) start only when `launcher/**` or `teamapp/**` change. The launcher publishes a release only from `main` or a manual run. The team-app build publishes nothing.
- **Game deploys** are manual scripts run on the VPS from `main`. No server job pulls this branch, and the repository has no rulesets.
- **One side effect:** the VPS's nightly drift report lists every branch other than `main` in #build-alerts, so it will list `helix3d-handoff` each night while the branch exists. That is expected.

## Codex setup check

Codex can already read the public repository. This check proves that the Windows environment Codex uses can also **push**. A browser sign-in on its own doesn't count; only a successful push does.

Run these from a terminal in Codex's working folder on Helix's PC. The clone fetches only the handoff folder, not the whole game.

```powershell
git clone --depth 1 --filter=blob:none --sparse --branch helix3d-handoff https://github.com/Brbmuffins/Death_Muffin.git dm-handoff
cd dm-handoff
git sparse-checkout set docs/model-pipeline-review
git config user.name "Codex (Helix's PC)"
git config user.email "codex@helix3d.invalid"
```

Next, add one line to the "Setup check" section of `docs/model-pipeline-review/CODEX-REVIEW.md`. Replace the template line there and touch nothing else in the file. The line names the date, the branch commit you started from, and the GitHub account name the push used, never a credential.

Then commit and push:

```powershell
git add docs/model-pipeline-review/CODEX-REVIEW.md
git commit -m "Helix3D handoff: Codex setup check"
git push origin helix3d-handoff
git ls-remote origin refs/heads/helix3d-handoff
git rev-parse HEAD
```

The check passes when the last two commands print the same commit id.

**Sign-in on the first push.** Git Credential Manager is already installed on the PC. On the first push it opens a GitHub sign-in in the browser:
- Helix signs in with **Helix's own GitHub account** and clicks "Authorize".
- Nothing is copied or pasted anywhere.
- The sign-in is stored by Windows for Helix's user account, not in this folder.

**If something goes wrong:**
- **No sign-in window appears**, or Codex's sandbox blocks it: Helix runs `git push origin helix3d-handoff` once in an ordinary PowerShell window in the `dm-handoff` folder. Codex's own next push then confirms that Codex's environment has the access.
- **The push is refused** with "Permission denied" or 403: Helix's account cannot write to the repository. The owner adds it under the repository's Settings → Collaborators with the Write role, then the push is retried.

Afterwards, the clone keeps working with `git pull --rebase origin helix3d-handoff` before each edit.

## Ending the branch

The handoff branch stays until Helix decides otherwise. It is not merged into `main` as part of this setup. When it is no longer needed, it is archived like any finished experiment: tag it `archive/helix3d-handoff`, then delete the branch.
