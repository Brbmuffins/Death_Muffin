# Claude status

Claude, the implementation agent working on the VPS, writes this page: proposals, implementation status, evidence, and replies to Codex's reviews. Newest entry first. Each entry follows the format in [HELIX3D-HANDOFF.md](HELIX3D-HANDOFF.md#working-protocol).

## 2026-11-06: handoff set up

- **Inspected revision:** `main` at `1fba3645`, which is `origin/main` today. The `helix3d-handoff` branch starts from it.
- **Status:**
  - The branch and these five documents are created in this commit.
  - The repository's workflows were checked: nothing deploys from this branch ([what a push does](HELIX3D-HANDOFF.md#what-a-push-here-does)).
  - **Codex's push access from Helix's PC is not verified.** Claude has no way to run commands there. The team app's jobs only make models, screenshots, clips, benchmarks and release checks; none of them runs git or a shell.
- **Requested next action:**
  - Codex: run the [setup check](HELIX3D-HANDOFF.md#codex-setup-check), then review the Milestone 1 proposal below in CODEX-REVIEW.md.
  - Helix: be at the PC for the GitHub sign-in during Codex's first push.
- **Unresolved questions:**
  - For Codex or Helix: the complete text of the agreed plan. [HELIX3D-PLAN.md](HELIX3D-PLAN.md) holds only the excerpts from the brief.
- **Recommendation:** use this handoff for the Milestone 1 review.
- **Technical readiness:** Claude's side works. Codex's side needs the setup check.
- **Owner authorization:** [H3](HELIX3D-DECISIONS.md) (documentation only).

## 2026-11-06: Milestone 1 proposal delivered

- **Inspected revision:** `main` at `1fba3645`. The assessment was read-only.
- **Status:**
  - Delivered in chat on 2026-11-06. The full text is [below](#milestone-1-proposal-as-delivered-2026-11-06), unchanged apart from three edits: the PC's network name is removed, the one question is marked answered, and three file paths are adjusted for the repository's link check (one full path; two proposed new paths are no longer code-formatted).
  - Three statements in the review packet are wrong and will be corrected only under item B7, if Milestone 1 is approved:
    - [README.md](README.md) §6.2 says the out-of-memory rate is "1 in 4". It is 3 of 64 runs.
    - §6.3 calls all of Qwen-Image non-commercial. Only Qwen-Image-2.1 is.
    - `ASSET_PIPELINE.md` "Several views" draws a conclusion from runs that used the wrong checkpoint.
- **Requested next action:** Codex reviews the proposal. Helix approves, changes or declines Milestone 1.
- **Unresolved questions:** none. The one question was answered ([H2](HELIX3D-DECISIONS.md)).
- **Recommendation:** approve Milestone 1, as section E explains.
- **Technical readiness:** Claude can start as soon as it is approved. It needs:
  - A team-app update.
  - The 5.2 GiB multiview checkpoint on Helix's PC.
  - About 1–2 GPU hours while the PC is free.
- **Owner authorization:** none. Milestone 1 is not approved.

## Replies to reviews

*(No review in CODEX-REVIEW.md yet.)*

## Milestone 1 proposal (as delivered 2026-11-06)

This was a read-only assessment on 2026-11-06. I didn't edit project files, install, download or run anything, and didn't commit. The only things I wrote were my own memory notes.

I made two kinds of lookups: one read-only request to our team API for the PC's specs, and Hugging Face model-card metadata. Four read-only helpers gathered part of the evidence, and I re-checked the claims that matter most myself.

**Labels:** **V** = verified now (file and line, or a log). **R** = reported in docs or notes, not re-checked. **I** = inferred. **U** = unknown.

### A. Verified baseline

**Repo revision**
- `origin/main` is `1fba3645`, the commit the review looked at. Nothing has landed since. **V**

**Work that is not in git** **V**
- `wt/default-bodies`: the rejected Pixal default bodies.
- `wt/asset-tests`: the T1/T2 test records, plus an uncommitted change to `finish.py`.
- The 11-04 factory hero records, parts and the hero files sent to Helix exist only in a temporary session folder: `/tmp/…77463ed4…/scratchpad/sys/` (3 GB of a 13 GB folder).
- The 11-04 head-join redo (`join: surface`) isn't in git or any worktree. Whether it survives anywhere is **U**.

**Helix's PC**
- **V**:
  - RTX 4070 SUPER with 12,282 MB of video memory, team app 0.5.6, online on 2026-11-06.
  - ComfyUI 0.43.2 as of the 11-04 job log. Our saved workflow was built against 0.42.5 (`teamapp/comfy/image-to-model.json`, "about"), and the reference copy I read is also 0.42.5.
- **V**: I can reach it only through team-app jobs: at most 8 runs per job, 30 minutes per run, 48 MB per file (`teamapp/windows/Comfy.cs:82,87,95`). No shell access.
- **U**: CPU, system RAM, driver and Windows versions, PyTorch/CUDA versions, the NVIDIA shared-memory fallback setting, and whether the multiview checkpoint is installed.

**Models in the workflow** **V**
- `pixal3d_int8_convrot` and `trellis_2_int8_convrot` (the two generators, int8).
- Shape and texture VAEs in bf16.
- `dino_v3_L_naf_fp32` (DINOv3 picture encoder with the NAF upsampler).
- `moge_2_vitl_normal_fp16` and `birefnet`.

**Reusable on main** **V**
- The team-app `model` job and `model-gen.sh`.
- The Blender `make.mjs` steps: fit, bend, finish (meshopt, xatlas, transfer), parts, materials with matmap, grime, place, rig (quad, legs, biped), cloak.
- `check-models.mjs`, `build-characters.mjs`, the crowd baker, `model-view.sh` and `gemini.mjs`.
- In the client: held items on bones, fitted helm and mantle, and region masks built from skin weights.

**Reusable but outside git** **V**
- SkinTokens running on CPU (`~/.cache/dm-ops/rigtest`, 4.7 GB).
- Real-pixel paint (`pixelmatch`).
- The MakeHuman bodies (`human/`, `mpfb/`).
- The measurement scripts, spread across `/tmp` and `dm-ops`.

**Missing evidence**
- No intermediate output from any generation.
- No per-run peak memory reading, and no record of the PC's software setup.
- No multiview run on the correct checkpoint.
- No in-game test of occlusion.
- No log of team effort per accepted asset.

### Findings 1–7

#### 1. Processing before export (graph **V**, cause **I**)

The only file saved is node 322. By then the model has gone through:
1. Raw decode (node 92).
2. `RemeshMesh` (node 241) with three settings that matter:
   - `sign_mode solid`, which ComfyUI's own description says "removes double shells".
   - `band 1`, which rounds off creases.
   - `smooth_iters 20`, where the node's tooltip says 2–3 is enough and more over-smooths.
3. Reduction to 200k faces (node 186).
4. Normals smoothed at crease angle 180 (nodes 238 and 260).
5. UV unwrap (node 196).
6. Texture, normal and occlusion bakes (nodes 147, 224, 233).

Because nothing earlier is kept, a generation defect and a processing loss look identical.

ComfyUI 0.42.5 already has the nodes needed to save each stage: `PaintMesh`, `SaveGLB`, `GetMeshInfo` and `MeshTextureToImage`.
- **Stages to capture on the PC:** S0 raw shape painted from the generator's colours (nodes 92 + 93), S1 after remesh (241), S2 after reduction (186), S3 today's file, plus the five texture images.
- **Stages to capture on the VPS:** F1 inner walls dropped, F2 game mesh, F3 baked maps, F4 after WebP encoding.
- **Blocker:** the app uploads only one saved node, up to 48 MB.

Main suspect **I**: the `solid` remesh plus 20 smoothing passes turns thin cloth into closed, lumpy shells. That fits two earlier observations:
- Tripo's cape has about 0.8% open edges, while ours is a closed shell **R**.
- `finish.py` needs `drop_inner_walls`.

#### 2. Multiview: the mismatch is confirmed (**V**)

- ComfyUI's own multiview template (`3d_pixal3d_multi_views.json`) loads `pixal3d_multiview_int8_convrot.safetensors` (5.2 GiB, Comfy-Org/Pixal3D). It also removes the background from each view and crops it.
- Our workflow keeps the single-view checkpoint. A run with views only rewires the conditioning (`Comfy.cs:304-319`). Node 319 stays `pixal3d_int8_convrot`, and the front picture goes in raw from LoadImage node 122.
- Both multiview jobs ever submitted used the single-view checkpoint:
  - `be7758c84840`: the hound, 2026-10-26.
  - `fc04702d7c97`: the Gravecaller body, 2026-11-03.
- So two earlier conclusions are confounded, not evidence against multiview:
  - The 10-26 hound verdict.
  - The 11-03 "front + back made bodies worse", which went into `ASSET_PIPELINE.md:79-82` ("Several views").
- **I**: ComfyUI merges the views by averaging projected features (`comfy/ldm/trellis2/model.py:862-893`). The single-view weights were likely never trained for that.

#### 3. Character integration (**V**)

How it works today:
- **Body:** one skinned mesh with one material, and it must use the Gravecaller skeleton (`check-models.mjs:19,30,78-83`).
- **Gear:** unrigged, one material, at most 4k triangles (`:20`). The rule at `:77` says a piece "is unrigged and rides a hand, the head or the back".
- **Weapons:** attached to bones (`dm_creature.gd:854-895`).
- **Helm and mantle:** scaled to the measured head and chest (`:913-927`).
- **Chest, legs, hands and feet:** only tint the body (`dm_avatar.gd:353`).
- **Three-piece sets:** swap the whole body (`dm_avatar.gd:477-531`).
- **Gap:** `docs/LOOK.md:89-92` (B81) says worn gear replaces the body region it covers, and the client doesn't do that yet.

How fitted clothing would fit:
- Each piece is its own skinned mesh on the body's skeleton: same joint names and rest pose, at most 4 bone influences per vertex (what the tools export today, `build_rig.py:249`).
- The body hides the regions a piece covers using the region masks it already builds (`dm_creature_mat.gd:32,182-235`), so the body never needs re-cutting per outfit.
- Rigid pieces such as pauldrons stay attached to bones.

Rules that would need deliberate changes:
- **Validator** (`check-models.mjs`):
  - Add a `wear` kind: skinned, joints drawn from the base body's skeleton, its own budget.
  - Keep `gear` unrigged for held and bone-attached pieces.
  - Use one reference skeleton per body type instead of only `hero_gravecaller`.
- **Mesh merge:** `merge.mjs:75` assumes one skinned mesh.
- **Equipment:** `dm_avatar.gd` makes models only for main hand, off hand and head (`:311`), and swaps the whole body for sets.
- **Crowd baker:** stays single-mesh (`crowd_baker.gd:109-117`), so dressed enemies would be merged when the game is built.

Proposed budget for a fully dressed hero (the team approves the numbers):

| Part | Triangles | Maps (colour, ORM, normal) | Draw calls |
|---|---|---|---|
| Visible base body | ≤8k | 1024 | 1 |
| Helm / shoulders / chest | ≤2k / ≤2k / ≤4k | 512 / 512 / 1024 | 1 each |
| Gloves / legs / boots | ≤1k / ≤2k / ≤1k | 512 | 1 each |
| **Total worn** | **≤20k** (today's hero cap, B71) | | **≤7** |
| Held items (current gear rule) | ≤4k each | 512 | 1 each |

That raises a hero from about 3 draw calls to at most 9. Merging pieces when gear is equipped is only worth building if the in-game benchmark on Helix's PC shows a need.

#### 4. Materials

"One material per model" isn't what limits us. A per-pixel ORM map survives the pipeline; the losses come from flat generator values plus our own flattening.

| Channel | Where information is lost |
|---|---|
| Occlusion (AO) | **V**: `dm_creature_mat.gd:131-134` reads only the roughness and metal channels, so creature occlusion is never drawn (only screen-space AO, on High and Ultra). The shipped hound's occlusion (average 0.52) is unused data. ComfyUI's bake uses a ray length of 0.71 × the model's diagonal, which gives whole-model shading rather than crevices, at 1024 px. |
| Metal | **V**: Pixal's per-pixel metal is replaced by either 0 or ≥0.85 (`metal.py:121`). The hound and spider ship with `--metal none`. |
| Roughness | **V**: Pixal's own map is nearly flat (shipped hound ranges 0.65–0.80). Variation appears only when `materials.py` writes per-material constants, and no shipped Comfy record uses that step. Tripo's Gravecaller ranges 0.15–0.99. |
| Normals | **V**: Baked from the smoothed remesh. `transfer.py:248-258` limits steep normals to z ≥ 0.26. They are then averaged down 4×. Normal and ORM maps get the same lossy, colour-reduced WebP at quality 86 (`build-characters.mjs:189`), and Godot compresses them again. |
| Colour | Limited by the generator's voxel grid, not by the 4096 texture size (**R/I**). |

#### 5. Memory (**V**, from the 16 job logs that survive: 98 runs, 10-23 to 11-04)

**Standard settings** (detail 2048, grid 1024, texture 2048, single view):
- 3 of 64 runs failed, all out of memory while decoding the texture (`VaeDecodeTextureTrellis`, asking for 4.2–4.7 GiB with 4.6–5.6 GiB already in use). That's about 5%.
- The "1 in 4" in my review page came from an early 8-run sample and is wrong.

**Other settings:**
- Grid 2048: 2 of 13 runs ran out of memory during remesh.
- Texture 4096: one file came out at 55 MB, over the 48 MB limit.
- TRELLIS.2: 1 of 5 runs hit the 30-minute limit.

**The 0.5.6 low-memory flag didn't fix it:** the texture-decode failure still happened under `--disable-smart-memory` on 11-04, with ComfyUI 0.43.2.

**Run times vary 12×:** 77–969 s at identical settings, 305 s median. The out-of-memory messages report 19.5–20.2 GiB "currently allocated" on a 12 GB card. **I**: Windows is spilling into shared system memory. That would explain the slow runs; it doesn't cause visual defects.

**Launch:**
- The app's own ComfyUI runs with `--listen 127.0.0.1 --port N --disable-smart-memory` and nothing else (`Comfy.cs:1152-1157`).
- The Desktop server is used only when it was started with a low-memory flag.

**Fallback:** a failed run is logged and skipped. There is no retry and no fallback to lower settings, so no shipped or compared model came from a degraded run.

**Precision:** both generators run int8 at the default weight type.

#### 6. Licensing (**V**, Hugging Face model cards and API on 2026-11-06 unless marked)

**Correction:** the Qwen exclusion is right for one checkpoint family only.

| Checkpoints | Licence | Commercial use |
|---|---|---|
| `Qwen/Qwen-Image`, `-2512`, `-Edit`, `-Edit-2509`, `-Edit-2511`, `-Layered` | Apache-2.0 | Yes |
| `Qwen/Qwen-Image-2.1` (plus Turbo and PE variants) | Qwen Research License | No: "for non-commercial purposes only" |

- **Where the note came from:** AssetFurnace's credits name 2.1 (`~/.cache/dm-ops/pixelmatch/image-to-3dlab/docs/info_and_credits.md:16`).
- **Where to fix it:** review page §6.3 (line 349) should say "Qwen-Image 2.1".

Current workflow:

| Licence | Components |
|---|---|
| MIT | Pixal3D, TRELLIS.2, MoGe-2, BiRefNet |
| Apache-2.0 | NAF |
| GPL-3 | ComfyUI; it doesn't extend to outputs |
| DINOv3 License (Meta) | DINOv3. Commercial use is allowed under custom terms, including a list of banned uses. It's the one non-standard licence, and both generators depend on it. |

- **Unclear packaging:** how ComfyUI packaged `dino_v3_L_naf_fp32` isn't documented. **I**: DINOv3-L with NAF fused in.

Other tools:

| Licence | Tools |
|---|---|
| Apache-2.0 | SAM 2.1, SigLIP 2 (exact checkpoint to confirm) |
| MIT | YuNet, meshoptimizer |
| CC0 | Quaternius clips, MPFB2 assets |
| GPL-3 | MPFB2 code |
| BSD-3 | Real-ESRGAN |
| Outputs are ours | Blender |

Open or conditional:

| Item | Status |
|---|---|
| Tripo free-plan output | CC BY 4.0 with no commercial rights. Source is a search summary because the terms page was blocked. |
| SkinTokens weights | Trained on data whose licences weren't checked. |
| Hunyuan3D | Its licence excludes the EU, UK and South Korea. |
| MediaPipe face model, xatlas, DeepMesh weights | **U** |

**No licence ledger:** the repo has no per-model record; `docs/licenses/` holds one file.

#### 7. Durability and locality (**V**)

- **`/tmp`** is cleared only at reboot (`/usr/lib/tmpfiles.d/tmp.conf` sets no age limit). The 13 GB factory session sits one reboot from loss: hero records, parts, the files sent to Helix, the measurement scripts and the 11-03 body inputs.
- **`~/.cache/dm-ops`** (about 14 GB) is on persistent disk but not in git, not backed up, and mostly not referenced from the repo.
- **`art-src/`** (7.1 GB, including 671 paid Tripo GLBs) has no backup that I found.
- **Team results** expire after 14 days.
- **Cloud calls** are only `gemini.mjs:22`, `tripo.mjs:26` and `retarget-clips.mjs:17`. Everything else runs on Helix's PC or the VPS.
- **Fully local:** concept pictures would have to move from Gemini to a local commercially licensed model (FLUX.2 klein 4B, Z-Image-Turbo or Qwen-Image-2512). None has been tested on the 4070 yet.

### B. Proposed modifications

Everything marked "Shared" stays in the Death Muffin repo for now and moves at roadmap step 5. No new queue, interface or generator: the team app stays the queue, and model-view stays the in-game check.

| # | File or component | Limitation now | Change | Why | Home |
|---|---|---|---|---|---|
| 1 | `teamapp/windows/Comfy.cs`, `JobRunner.cs`, `teamapp/tests/ModelTests.cs` | Uploads one saved node, ≤48 MB; records no software setup or memory use; a failed run keeps nothing | A workflow can name extra capture nodes. Record ComfyUI's system info (versions, RAM, flags) and the installed model list. Sample nvidia-smi every 1 s for peak memory per run. Keep captures from failed runs. | Separates generation defects from processing losses (Findings 1 and 5) | Shared |
| 2 | `teamapp/comfy/image-to-model.json`, `make-workflow.py` | Multiview runs use the single-view checkpoint; the front goes in raw | Runs with views load `pixal3d_multiview_int8_convrot`; the front is prepared like the other views; add a diagnostic capture set | Finding 2 | Shared |
| 3 | `server/death-muffin/model-gen.sh` | Expects one output | Request captures; check the PC has the multiview file before queueing | Same | Shared |
| 4 | `tools/blender/comfy/finish.py` | Stages are visible only through a debug dump | `--keep-stages <dir>` saves F1–F4 | The same stage-by-stage view on our side | Shared |
| 5 | New tools/assets/measure/ folder, built from existing scratch scripts | Measurement scripts are scattered across `/tmp` and `dm-ops` | One script with fixed cameras, producing a comparison sheet per stage | Repeatable numbers; no new method | Shared |
| 6 | Archive of the `/tmp` factory session and `dm-ops` research | One reboot loses them | Copy to a durable folder with a hash list; hash the approved live assets as the protected baseline | Roadmap step 1 | Shared archive; Death Muffin baseline list |
| 7 | Review page §6.2/6.3; `ASSET_PIPELINE.md:79-82` | States "1 in 4", "Qwen-Image non-commercial" and "views made bodies worse" | Correct them to the evidence above | Reviewers rely on these pages | Death Muffin |
| 8 | New docs/licenses/MODELS.md | No per-model licence record | One row per exact file: URL, licence, date checked | Provenance requirement | Shared format; Death Muffin copy |

For later milestones, once the pilot shows where the loss happens:

| # | File or component | Limitation now | Change | Home |
|---|---|---|---|---|
| 9 | `dm_creature_mat.gd:131-134` | Occlusion ignored | Draw occlusion from the ORM map, with a strength setting; the team judges the look | Death Muffin |
| 10 | `metal.py`, `transfer.py:248-258`, `build-characters.mjs:189`, occlusion bake (node 233) | Metal forced to two values, steep normals limited, lossy normal and ORM maps, whole-model occlusion | Keep Pixal's per-pixel values where sane; lossless or lighter compression for normal and ORM; shorter occlusion rays | Shared tools; Death Muffin encode settings |
| 11 | `check-models.mjs`, `dm_avatar.gd`, `merge.mjs` | No skinned gear | `wear` kind, skinned pieces on the body skeleton, hidden regions under gear | Shared validator; Death Muffin rules |

### C. Small diagnostic pilot

**Subject:** the Gravecaller. It's where the gap was measured (folds, open cloth, face, shoulder skulls), and the 11-03 multiview runs already give a control for it.

**Comparison target:**
- The shipped, approved Tripo `hero_gravecaller` (11,749 triangles).
- Its concept, `art-src/concepts/hero_gravecaller.png`.
- The back view cut from the existing 11-03 sheet (`hero_gravecaller_views.png`).

No new pictures and no spend.

**Questions it answers:**
- **Q1:** Where is detail lost: the generator (S0), ComfyUI processing (S1–S3), our finish and encoding (F1–F4), or the game's renderer?
- **Q2:** Does the multiview checkpoint improve the back and sides without hurting the front?
- **Q3:** Does skipping the `solid` remesh keep thin cloth? One extra save branch per run: raw → reduce to 200k with the "midpoint" mode (which keeps thin features) → the same unwrap and bakes.
- **Q4:** What is the real memory profile per stage at the standard settings?

**One job on Helix's PC, 6 runs:**

| Runs | Pictures | Checkpoint | Seeds |
|---|---|---|---|
| Single view | concept front | single-view | 0, 1 |
| Multiview control | front + back | single-view | 0, 1 |
| Multiview | front + back | multiview | 0, 1 |

**Held fixed:**
- On the PC:
  - The same front picture file for every run.
  - Detail 2048, grid 1024, 200k faces, texture 2048.
  - Round 1, sharp off, follow 7.5.
  - Field of view automatic for single view, 20 for views.
  - One recorded ComfyUI version, with `--disable-smart-memory`.
- On the VPS: today's hero finish (meshopt to 20k, 1024 maps).

**Outputs per run:**
- S0 raw painted: full size, or reduced with the midpoint mode to fit 48 MB (recorded either way).
- S1, S2, S3, and S3b from the no-remesh branch.
- The five texture images, mesh info, memory samples and timings.

Then F1–F4 on the VPS for S3 and S3b, plus one model-view job comparing the best candidate with Tripo in game.

**Measurements:**
- **Shape:**
  - Share of open edges.
  - Fold sharpness: median angle between neighbouring faces, and the share above 45°.
  - Median edge length as a percentage of height.
  - Outline overlap with the front concept (and with the back picture for multiview).
  - Distance from S0, scaled by height.
- **Paint:**
  - Sharpness on fixed close-ups: face, shoulder skull, cape hem, belt.
  - Colour difference from the concept.
  - Roughness, metal and occlusion percentiles.
  - Normal-map tilt at the 90th percentile.
- **Memory:** peak per run, the failing step with requested and allocated amounts, and run time.
- **Effort:** GPU minutes, my hours, failed attempts, review rounds, and Helix's own estimate of review minutes.

**Reading the results:**
- **Q1:** the loss point is the first stage where a close-up or a number drops by a clear step (for example sharpness −30%, or open edges going to 0).
- **If S0 already lacks the face, skull or cape compared with Tripo**, the generator is the limit. Then we stop tuning processing, and milestone 2 looks at part passes or a different source for bodies.
- **Multiview:** it reopens only if the multiview checkpoint beats the control on the back and matches single view on the front.

**Limits and stop rules:**
- At most 2 jobs and 12 runs, plus one retry per failed run.
- Drop a branch after two out-of-memory failures at the same step.
- No setting sweeps. If results are ambiguous, report rather than add runs.
- Stop if the multiview file won't load on the installed ComfyUI.

**Pilot acceptance** (judges the diagnosis, not an asset):
- At least 5 of the 6 runs return every capture.
- Q1–Q4 each answered with a named stage and numbers.
- One comparison sheet plus one in-game shot set, needing at most 15 minutes of review from Helix.
- No spend, and the live game untouched.

**Rollback:**
- All work on one branch: no record or client-asset changes, no deploy.
- The app rolls back by republishing 0.5.6.
- The 5.2 GiB checkpoint is deleted from Helix's PC if we don't adopt it.
- Pilot outputs are kept in the durable archive.

### D. Approval scope

| Item | What needs approval |
|---|---|
| **Repo file changes** (branch, then CI) | Items B1–B5, B7 and B8. B1 means publishing a new team-app version to team PCs (`publish-teamapp.sh`). |
| **Outside the repo** | An archive copy of about 16 GB on the VPS (388 GB disk, 49% used), plus a hash list of the approved live assets. |
| **Installations** | None on the VPS. On Helix's PC, only the team-app update. |
| **Downloads** | `pixal3d_multiview_int8_convrot.safetensors` (5.2 GiB, MIT, Comfy-Org/Pixal3D) onto Helix's PC. |
| **Resources** | About 1–2 GPU hours on Helix's PC while it's free; VPS Blender work on the CPU at low priority; one model-view job; about 15 minutes of Helix's review. |
| **Money** | None. Gemini isn't used, Tripo stays paused, nothing is rented. |
| **Live game, services, deploys** | None. |

### E. Recommended next decision

I recommend approving **Milestone 1: preserve the baseline and run the stage-capture pilot on the Gravecaller**, meaning items B1–B8 plus the pilot in C.

It delivers a durable archive, a licence ledger and corrected docs. It also gives measured answers to "generator or processing?" and "does real multiview help?", which decides milestone 2: fix the processing chain, or change where bodies come from. The team's cost is one approval and one 15-minute review.

### Blocking question

None of these questions blocks the pilot. One question blocks only the provenance ledger for the approved Tripo heroes:

1. **For the owner:** were all Tripo models generated while the account had paid credits? Free-plan output carries no commercial rights, and I can't see the account's plan history.

   **Answered** by Helix on 2026-11-06: "tripo models were paid for" ([H2](HELIX3D-DECISIONS.md)). Nothing in the proposal is blocked now.
