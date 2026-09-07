# Project Time Attribution — Staged Decomposition

- **Status:** DRAFT — awaiting explicit user approval (no implementation until approved)
- **Date:** 2026-09-07
- **Branch:** `feat/project-time-attribution`
- **Methodology:** staged-decomposition (A → intermediate stages → D; each stage produces a named, independently verifiable artifact; fixtures come from real recordings, never imagination)

---

## Product summary

Ship, for every Retrace user, a daily project-time report: per-project durations with activity descriptions, produced by multimodal LLM analysis of recorded screen history. Projects are **dynamic** — the system auto-detects new work and reuses existing projects across days. Local compute is minimized: OCR stays on-device (Apple Vision, free); frames, OCR text, and metadata are analyzed in the cloud.

### Locked decisions (from design dialogue, 2026-09-07)

| Decision | Value |
|---|---|
| Every-frame model | **Gemini 3.5 Flash-Lite** (GA) — structured output + function calling, 1M context |
| Escalation model | **Gemini 3.8 Flash** — new/ambiguous project clusters only |
| Frame preparation | Downscale to ≤768px, `media_resolution=low` (~280 tokens/frame, not 1120 default) |
| Batching | Overnight **Batch API** (JSONL, idempotency keys, 50% discount); Batch is **not idempotent on retry** — keys tracked locally |
| Caching | Implicit context caching (default-on ≥2.5) for the project-roster system prompt |
| Continuity | Learned anchors (repo names, domains, title patterns) + embedding centroids (Gemini embeddings, $0.006/M) — day-2+ mostly free |
| OCR | Stays local. Cloud OCR rejected ($100+/mo/user vs free) |
| Storage sync (B2/R2) | **Separate workstream, separate doc** — not a prerequisite |
| Budget | ~$5–12/user/month approved (see cost model) |
| First deliverable | Read-only CLI; in-app UI comes later |
| Key handling | BYO API key (env/config); no keys in repo |

### Cost model (to be pinned with `countTokens` in Stage 3)

Assumes 2,000 retained frames/day, 280 tokens/frame, ~100K text input, ~60K structured output:

- Input: (2,000 × 280 + 100K) × $0.30/M ≈ $0.20/day
- Output: 60K × $2.50/M ≈ $0.15/day
- Realtime ≈ $10.5/mo → **batched ≈ $5.3/mo** → escalation adds ~$1–2/mo
- **Working estimate: $5–12/user/month.** Anchor continuity should reduce this over time; the cost ledger measures reality.

---

## A — What exists and is trusted

| Artifact | Trusted for | Known limitations |
|---|---|---|
| `Database/ReadConnectionSupport.swift` (`SQLiteReadOnlyConnectionFactory`) | Read-only DB open incl. key retrieval | Snapshot consistency vs in-flight media writes not guaranteed — export must fence |
| `segment` / `frame` / `node` / `video` tables | Real recorded evidence schema | — |
| `Database/Queries/AppSegmentQueries.swift` | Heuristic app-usage estimate | Gap→previous-app with 120s cap; **not** ground truth |
| `App/DataAdapter.swift` | Native/Rewind query patterns, paging | Default 500-row caps; URL backfill makes some URLs non-contemporaneous |
| `Storage/ImageExtractor.swift` | Decoding frames from finalized video | Unfinalized frames only via raw WAL; redaction can rewrite videos post-hoc |
| Processing OCR text in `node` | On-device text extraction | Two ingestion paths (finalized video → JPEG → pixels; WAL) |
| `Shared/AppPaths.swift` | Configurable storage roots | — |
| **Forbidden as bootstrap** | — | `AppCoordinator` / `ServiceContainer` run migrations, retention, recovery, workers. The CLI must never initialize them (`Sources/TestMostRecentFrame` is a negative example) |

**Timing invariant (critical):** frames are packed into video at a nominal 30 FPS while capture occurs seconds apart. All time accounting uses **real capture timestamps**, never playback time.

## D — Observable end state

1. New CLI (`retrace-attribution`) runs read-only against a Retrace database, no app side effects, safe while recording is active.
2. For any chosen day it produces a **daily ledger**: stable project IDs across days, per-project durations, activity descriptions, evidence links (frame IDs), explicit unknown/unattributed time, and a cost report (tokens, $, model versions).
3. Every retained frame of that day is analyzed multimodally (3.5 Flash-Lite, structured output); ambiguous/new clusters escalate to 3.8 Flash.
4. Day-2+ behavior: confirmed projects auto-match via anchors at near-zero LLM cost; genuinely new work is detected, named, and added.
5. User corrections (rename/merge/reassign) feed back into anchors and change next-day behavior.
6. Ships with BYO key, cost ceiling guard, and `daily_metrics` instrumentation for runs.

---

## Isolation — the hard component

The genuinely hard part is **attribution reconciliation**: merging anchor matches, model candidates, real capture timestamps, idle/lock gaps, and user corrections into one consistent ledger without double-counting or silent assignment.

- **Location:** new top-level module `Attribution/` (own `AGENTS.md`), created in Stage 1 alongside the CLI target `Sources/AttributionCLI/` (pattern: existing `Sources/TestMostRecentFrame`).
- **Single consumer:** the reporting stage. Nothing else may import `Attribution/Reconciliation/`.
- **Forbidden importers of reconciliation:** `UI/`, `Capture/`, `Storage/`, `App/`, `Database/`. Reconciliation consumes an evidence-pack abstraction and must not know where evidence came from.
- **Forbidden imports inside the CLI:** `App/` (coordinator/container), any module-mutating code path.

---

## Stages

### Stage 0 — Evidence contract + real corpus (instrumentation first)

- **Produces:** `evidence-pack-v1` schema (segments, real capture timestamps, app/title/URL metadata, OCR text refs, downscaled frame refs, available lock/idle evidence, provenance hashes) + 3–5 real days exported from the author's Retrace database into a local fixtures directory (private, out of git; schema + sanitized samples committed).
- **Verified by:** schema validation of every exported day; row counts reconcile against direct SQL; spot-check exported frames against DB frame records; read-only assertion (source DB untouched, verified by mtime + open flags).
- **Why separate:** every later stage's tests are built from this corpus. Frame volume, segment shapes, and idle patterns measured here replace assumptions; guessed fixtures are the exact failure mode this methodology exists to prevent.
- **Reality check:** the author's actual recorded working days, including multi-project switching.

### Stage 1 — Read-only evidence exporter CLI

- **Produces:** executable `retrace-attribution export --day YYYY-MM-DD --out DIR`: read-only DB access, frame decode + downscale (≤768px JPEG), OCR text assembly, manifest with provenance (frameID → source, SHA-256). First commit creates `Attribution/` + `AGENTS.md` entries.
- **Verified by:** end-to-end run against the real DB; output validates against Stage 0 schema; grep gate script asserting zero imports of `App/` in the CLI target; runs concurrently with a live recording session without side effects.
- **Why separate:** the harness and reconciliation must develop against a stable export contract; exporter correctness is independently checkable without any LLM work.
- **Reality check:** built and measured on the Stage 0 corpus.

### Stage 2 — Observed-case catalog + human labels

- **Produces:** `docs/decomposition/observed-catalog.md` enumerating segment shapes actually observed (per-app editing, browsing per-site, terminal, meetings, idle/lock gaps, URL-backfill anomalies, rapid project switching) with frequencies; plus **human-labeled project boundaries for ≥2 full days** (the user performs labeling; a simple labeling aid over the evidence pack is allowed).
- **Verified by:** coverage check — every segment in the labeled days maps to at least one catalog case; label file passes its own schema.
- **Why separate:** project-time semantics are human judgments (what owns a boundary, what counts as unknown). Reconciliation tests in Stage 5 are written from these labels; inventing them would bless imagination.
- **Reality check:** directly from Stage 0/1 exports.

### Stage 3 — Gemini harness (transport, not intelligence)

- **Produces:** `Attribution/Harness/`: request builder (frames + OCR + cached roster layout, `media_resolution=low`, responseSchema), `countTokens` pre-flight (pins the real cost table), Batch JSONL submit/poll with **local idempotency-key ledger**, retry policy, spend ceiling guard, cost ledger, and recorded-response fixtures (canned JSON) for offline replay. Swift SDK (Firebase AI Logic standalone) vs thin REST client decided here.
- **Verified by:** countTokens report within ±20% of the cost model above; offline replay suite passes with no network; one opt-in live smoke call over one hour of corpus; cost-ledger totals match provider-reported usage.
- **Why separate:** transport correctness (idempotency, spend caps, retries) is testable with zero attribution logic and isolates financial risk before intelligence is added.
- **Reality check:** real corpus frames; real token counts replace the estimate table.

### Stage 4 — Continuity: anchors + embeddings

- **Produces:** `Attribution/Continuity/`: anchor store (learned identifiers: repo names, domains, title patterns — harvested from confirmed assignments), embedding-centroid matcher (Gemini embeddings API), assignment logic → existing project | new-cluster flag. Stage 2 labels seed initial anchors.
- **Verified by:** tests against labeled days: exact-assignment rate ≥ threshold **derived from Stage 2 data, not invented now**; cold-start day detects the labeled new projects; measured LLM-bound segment reduction on day 2 vs day 1.
- **Why separate:** the cheap deterministic path must be proven before prompts lean on it; poisoned anchors would corrupt reconciliation silently.
- **Reality check:** Stage 2 labels.

### Stage 5 — Attribution reconciliation (hard component — tests FIRST)

- **Produces:** `Attribution/Reconciliation/`: interval construction from real capture timestamps, candidate merging (anchors + model output), boundary rules, unknown-time entries, no-double-count invariant; versioned `DailyLedger` (hash-chained to evidence). **Tests are written before implementation, from Stage 2 fixtures.**
- **Verified by:** duration-weighted attribution accuracy, per-project error within thresholds agreed with the user from label data, boundary quality, unknown coverage, zero-overlap invariant — all against real labeled days. A failing test against a real fixture is never edited to go green; the code is wrong.
- **Why separate:** this is the multi-source truth merger. Per methodology it needs its own module and single consumer; its bugs are ownership bugs that masquerade as report bugs.
- **Reality check:** labeled days from Stage 2.

### Stage 6 — Interpretation + escalation prompting

- **Produces:** versioned prompt + schema pairs: (a) per-batch frame labeling (3.5 Flash-Lite, terse JSON labels), (b) new-cluster naming/description (3.8 Flash), (c) daily activity summary. Prompt fixtures + model/prompt version stamps in the ledger.
- **Verified by:** schema validation 100% on replay; live opt-in run reviewed by the user on a genuinely new project; escalation rate and cost within guardrails.
- **Why separate:** prompt quality iterates independently of transport and reconciliation; version pinning keeps runs reproducible.
- **Reality check:** real ambiguous clusters surfaced by Stages 4–5 on the corpus.

### Stage 7 — Report, corrections, metrics

- **Produces:** `retrace-attribution report --day ...` (per-project table, descriptions, unknown time, cost); `retrace-attribution correct ...` (rename/merge/reassign → anchor feedback); `daily_metrics` emission; ledger versioning.
- **Verified by:** end-to-end on labeled days — totals match human labels within agreed tolerance; a correction verifiably changes next-day anchor matching; metrics recorded.
- **Why separate:** this is the user-facing contract and the feedback loop that makes day-2+ cheap; it must not entangle reconciliation internals.
- **Reality check:** labeled days + explicit user review.

### Explicitly separate workstreams (own decomposition docs, not this one)

- Capture/OCR/encoding performance optimization (requires its own quality baseline first)
- Cloud storage sync (B2/R2, revision + redaction-propagation policy)
- In-app UI integration of reports

---

## Unknowns (explicit — none of these are silently decided)

1. **Real retained-frames/day volume** — measured in Stage 0; cost model is sensitive to it.
2. **Idle/lock evidence completeness** in the DB today — if gaps exist, a capture-side evidence addition becomes its own small workstream; the CLI proceeds without it meanwhile (unknown time stays visible).
3. **Exact tokens/frame at `low` for 3.5 Flash-Lite** — 280 is the documented family table; pinned by countTokens in Stage 3.
4. **Swift SDK viability** (Firebase AI Logic standalone API-key auth) vs thin REST client — decided Stage 3.
5. **Attribution accuracy thresholds** — derived from Stage 2 labels with the user, before Stage 5 tests are written.
6. **Privacy copy for shipped users** (frames leave the device by design) — product decision before public release, not before CLI.
7. **Rewind-history scope** — assumed native-only for v1; Rewind import support deferred.
8. **Paid-tier rate limits under batch** — monitored via cost ledger from Stage 3 onward.
9. **Offline/non-computer work policy** — out of scope for v1; observed computer time only (pending user confirmation).

## Fixture plan

- Stage 0/1 export real days → private corpus (out of git; `.gitignore`d) + committed schema + sanitized samples.
- Stage 2 labels + catalog → the semantic ground truth for all attribution tests.
- Stage 3 records live API responses → replay fixtures so the entire pipeline is testable offline, deterministically, and free.
- Stage 5 tests are written **before** reconciliation code, against Stage 2 fixtures.
- No fixture anywhere in this feature is typed from imagination.

## Conventions compliance (agent-code-conventions)

- Worktree `.worktrees/project-time-attribution`, branch `feat/project-time-attribution`; this document is the first commit on the branch.
- After approval: GitHub issue `feat(attribution): project-time attribution CLI with Gemini harness` created before implementation; stages reference it.
- One conventional commit per stage artifact; PR opened fully built (implementation, tests, verification) and linked via `Refs`/`Fixes`; never auto-merged.
- Baseline `swift build`/`swift test` verification runs at the start of Stage 1 implementation (docs-only commits precede it).
