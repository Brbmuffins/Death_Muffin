# Helix3D plan

> **Status: the full agreed plan is pending.** Helix and Codex planned Helix3D's architecture before this handoff existed. Claude has never seen the complete text of that plan, so this page does not reconstruct it. Until it is added here, by a recorded decision ([HELIX3D-DECISIONS.md](HELIX3D-DECISIONS.md)), the plan consists of the excerpts below and nothing more.

## Stated so far

These excerpts come verbatim from the assignment brief Helix gave Claude on 2026-11-06, as recorded in decision [H1](HELIX3D-DECISIONS.md). They are part of the plan, not the whole of it.

**Goal**

> The goal is a system where our team can describe an asset, select the game, approve a concept, and receive a polished, validated, commercially usable game asset with minimal intervention.
>
> Helix3D should support multiple games, with Death Muffin as its first integration and quality benchmark. It should become a separate project with reusable production tools and independent game profiles.

**Direction**

> Our agreed direction is to modify, separate, and extend the existing pipeline into Helix3D while preserving the full vision. Reuse working foundations, improve weak components, and replace components where evidence shows they cannot meet the requirements.

**Requirements**

> * Production targets Helix's RTX 4070 Super with 12GB VRAM.
> * Generation and processing must ultimately operate locally without required cloud inference.
> * Prioritize polished, cohesive quality over speed.
> * Keep production near-free; do not assume new hardware, subscriptions, or paid services.
> * Document commercial-use eligibility and provenance across the complete workflow.
> * Human approval governs concepts, final appearance, and production release.
> * Use hybrid characters: reusable bodies and rigs, modular equipment, and AI-assisted generation.
> * Support independent game profiles and replaceable generation methods.
> * Preserve existing approved assets during development.
> * Account for the fact that the team has no manual 3D modeler.
>
> For Death Muffin, use its documented grimy painted realism and approved existing heroes as quality references. Preserve the existing animation quality.

**Roadmap**

> 1. Verify and preserve the existing baseline.
> 2. Diagnose quality losses and 12GB reliability.
> 3. Prove one complete character workflow before expanding to all heroes.
> 4. Establish modular bodies and equipment compatibility.
> 5. Consolidate proven tools into shared Helix3D workflows.
> 6. Validate production, recovery, and game integration.
> 7. Verify reuse with a second game profile.
>
> Each implementation milestone requires a separately approved scope. A successful generation job or functioning interface alone does not establish success.
>
> The main productivity measure is total team effort per accepted asset, including failed attempts, review, and corrections.

## Proposals against this plan

- **Milestone 1** (roadmap steps 1 and 2): Claude's proposal is in [CLAUDE-STATUS.md](CLAUDE-STATUS.md#milestone-1-proposal-as-delivered-2026-11-06). It is not approved.

## Changing this page

Any change to this page names the decision in HELIX3D-DECISIONS.md that made it. Adding the full plan text is such a change: whoever holds it (Helix or Codex) adds it here with a decision entry that says Helix agreed to that text.
