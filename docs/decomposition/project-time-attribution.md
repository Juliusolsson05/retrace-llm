# Project Time Attribution — Staged Decomposition

- **Status:** DRAFT — Phase 2. **Built only after `cloud-storage-sync.md` (Phase 1) ships.** No implementation until this decomposition is also explicitly approved.
- **Date:** 2026-09-07 (revised same day: build order changed to cloud → CLI → LLM; harness approach switched to an existing framework with project memory and auto-mapping)
- **Branch:** `feat/project-time-attribution`
- **Methodology:** staged-decomposition (each stage produces a named, independently verifiable artifact; real fixtures, never imagination)

---

## Product summary

Daily project-time report for every Retrace user: per-project durations with activity descriptions from multimodal analysis of recorded history. Projects are **dynamic** — auto-detected, auto-mapped, persistent in project memory. The agent harness runs on an **existing harness framework** (LangGraph or Pydantic AI — final pick at phase start) that provides persistence/memory, retries, and structured tool calls. The user never labels data; corrections are a product feature, not a data-preparation step.

### Locked decisions

| Decision | Value |
|---|---|
| Every-frame model | **Gemini 3.5 Flash-Lite** (GA) — structured output + function calling, 1M context |
| Escalation model | **Gemini 3.8 Flash** — new/ambiguous clusters only |
| Frame prep | ≤768px downscale, `media_resolution=low` (~280 tokens/frame, not 1120 default) |
| Batching | Overnight Batch API (JSONL, idempotency keys, 50% off); Batch is not idempotent on retry — keys tracked locally |
| Caching | Implicit context caching (default-on) for the project-roster system prompt |
| Harness | Existing framework — LangGraph (persistence + checkpointing) or Pydantic AI (agents + spend controls); decided at phase-2 start |
| Project memory | Harness-native persistent store: known projects, learned identifiers (repos, domains, title patterns), recent decisions |
| Auto-mapping | Harness maps observed activity → existing project from memory, or creates a new project when nothing matches |
| Deterministic math | Timestamps → durations → totals computed in plain code; the model never does arithmetic |
| OCR | Stays local (free); cloud OCR rejected ($100+/mo/user) |
| Budget | ~$5–12/user/month approved |
| Key handling | BYO API key (env/config); never in repo |

### Cost model (pin with `countTokens` in harness stage)

2,000 retained frames/day × 280 tok + ~100K text ≈ 660K input × $0.30/M ≈ $0.20/day; ~60K structured output × $2.50/M ≈ $0.15/day → realtime ≈ $10.5/mo, **batched ≈ $5.3/mo**, escalation +$1–2/mo. Working estimate **$5–12/user/month**; memory-based reuse should reduce it over time.

---

## A — What exists and is trusted

| Artifact | Trusted for | Known limitations |
|---|---|---|
| Phase 1 output: cloud sync + evidence on B2 | Durable evidence source | Sync policy constraints (tombstones, revisions) |
| `Database/ReadConnectionSupport.swift` | Read-only DB open incl. key retrieval | Snapshot vs in-flight writes — export fences |
| `segment`/`frame`/`node` tables | Real recorded evidence | URL backfill makes some URLs non-contemporaneous |
| `Storage/ImageExtractor.swift` | Frame decode from finalized video | Unfinalized frames only via WAL |
| OCR text in `node` | On-device text extraction | Two ingestion paths |
| **Forbidden bootstrap** | — | `AppCoordinator`/`ServiceContainer` run migrations, retention, workers — CLI must never initialize them |

**Timing invariant:** frames are packed at nominal 30 FPS while capture occurs seconds apart. All time accounting uses **real capture timestamps**, never playback time.

## D — Observable end state

1. CLI (`retrace-attribution`) runs read-only, no app side effects.
2. For any day: a **daily ledger** — per-project durations, activity descriptions, evidence links (frame IDs), explicit unknown time, cost report (tokens, $, model/prompt versions).
3. Every retained frame analyzed multimodally (3.5 Flash-Lite); new/ambiguous clusters escalate to 3.8 Flash.
4. Project memory persists across days: known projects auto-match at near-zero LLM cost; genuinely new work is detected, named, added to memory.
5. `retrace-attribution correct` (rename/merge/reassign) updates project memory and changes subsequent days' behavior — a product feature.
6. BYO key, spend ceiling guard, `daily_metrics` instrumentation.

---

## Isolation

The coordination risk is **state ownership**: what the harness believes (memory, decisions) vs what code computes (durations). Rule: the harness owns *decisions and memory*; plain code owns *arithmetic and the ledger format*.

- **Location:** `Attribution/` top-level module (own `AGENTS.md`, created in the first implementation commit of this phase) + `Sources/AttributionCLI/`.
- **Single consumer of the accounting layer:** the report command.
- **Forbidden:** `UI/`, `Capture/`, `Storage/`, `App/`, `Database/` importing attribution internals; attribution importing app bootstrap; the harness writing the ledger directly (it only proposes; code disposes).

---

## Stages

### Stage 0 — Evidence contract + real corpus

- **Produces:** `evidence-pack-v1` schema (segments, real capture timestamps, app/title/URL metadata, OCR text refs, downscaled frame refs, lock/idle evidence, provenance hashes) + 3–5 real exported days (private corpus, out of git; schema + sanitized samples committed).
- **Verified by:** schema validation of every day; counts reconcile with SQL; frame spot-checks; read-only assertion on the source DB.
- **Why separate:** every later stage builds on this corpus; real shapes and volumes replace assumptions.
- **Reality check:** the author's actual recorded working days.

### Stage 1 — Read-only evidence exporter CLI

- **Produces:** `retrace-attribution export --day ... --out DIR`: read-only DB access, frame decode + ≤768px downscale, OCR assembly, manifest with provenance. Creates `Attribution/` + AGENTS.md entries.
- **Verified by:** end-to-end on the real DB; schema conformance; grep gate asserting zero `App/` imports; concurrent-with-recording safety.
- **Why separate:** the harness develops against a stable export contract.
- **Reality check:** Stage 0 corpus.

### Stage 2 — Observed-case catalog (automated)

- **Produces:** `observed-catalog.md` — segment shapes and frequencies from the corpus, generated by committed scripts. User answers only blocking design questions (if any).
- **Verified by:** coverage check — every corpus segment maps to a catalog case; script-generated, not hand-typed.
- **Why separate:** prompts and memory schema must be designed against measured shapes.
- **Reality check:** Stage 0/1 exports.

### Stage 3 — Harness foundation on existing framework

- **Produces:** framework decision (LangGraph vs Pydantic AI, documented rationale) + running skeleton: agent graph with tools (query evidence, read/write project memory, request escalation), checkpointed persistence, `countTokens` pre-flight pinning real cost, Batch submission with local idempotency-key ledger, spend ceiling, cost ledger, recorded-response replay fixtures.
- **Verified by:** offline replay suite green (no network); countTokens within ±20% of the cost model; one opt-in live smoke over one corpus hour; crash/resume of a batch preserves exactly-once keys.
- **Why separate:** transport, persistence, and spend correctness are testable with zero attribution intelligence; isolates financial risk.
- **Reality check:** corpus frames, real token counts.

### Stage 4 — Project memory + auto-mapping

- **Produces:** memory schema (projects: id, names/aliases, learned identifiers — repos, domains, title patterns; decisions log) + the mapping agent: existing-project match from memory, or new-project proposal via 3.8 Flash escalation; terse structured labels per frame batch (3.5 Flash-Lite).
- **Verified by:** corpus replay — day 1 cold start yields a small sensible cluster set; day 2 memory reuse measurably reduces LLM-bound segments; a correction updates memory and changes subsequent matching (demonstrated on corpus).
- **Why separate:** memory correctness must be proven before reports depend on it; poisoned memory silently corrupts everything downstream.
- **Reality check:** real corpus days.

### Stage 5 — Deterministic accounting layer

- **Produces:** plain-code ledger builder: intervals from real capture timestamps + harness decisions → per-project durations, unknown time, no-double-count; versioned `DailyLedger` (hash-chained to evidence + prompt versions).
- **Verified by:** label-free invariant tests written before implementation against the real corpus: zero-overlap, sum(per-project) ≤ observed active time, non-negative unknown, deterministic replay from identical inputs, correction application monotonic.
- **Why separate:** arithmetic and truth-merging must not live inside prompt space; invariants are provable without any ground-truth labels.
- **Reality check:** real corpus invariants.

### Stage 6 — Report + corrections + metrics

- **Produces:** `retrace-attribution report --day ...` (per-project table, descriptions, unknown, cost); `correct` commands feeding project memory; `daily_metrics`; end-to-end docs.
- **Verified by:** report renders from ledger deterministically; corrections change next-day behavior on corpus; metrics recorded; user reviews real reports in normal use.
- **Why separate:** user-facing contract; feedback loop that makes day-2+ cheap.
- **Reality check:** real corpus + user's own use.

---

## Unknowns (explicit)

1. Real retained-frames/day volume — measured Stage 0; cost is sensitive to it.
2. Exact tokens/frame at `low` for 3.5 Flash-Lite — pinned Stage 3.
3. Framework pick (LangGraph vs Pydantic AI) — Stage 3, with rationale.
4. Language boundary — Swift exporter + Python harness is the leading shape (both candidate frameworks are Python); confirmed at Stage 3.
5. Accuracy is not claimed until real-use review; v1 guarantees invariants + visible unknowns (honest limitation — no upfront labels exist by design).
6. Idle/lock evidence completeness in the DB — if gapped, capture-side evidence becomes a small separate workstream; CLI proceeds meanwhile.
7. Privacy copy for shipped users (frames leave device by design) — before public release.
8. Rewind-history scope — native-only v1.
9. Offline/non-computer work — out of scope v1.

## Fixture plan

- Stage 0/1: real exported days (private corpus, gitignored) + committed schema + sanitized samples.
- Stage 2: script-generated catalog.
- Stage 3: recorded live API responses → replay fixtures for fully offline, deterministic, free pipeline tests.
- Stage 5: invariant tests written before code, against the real corpus.
- No fixture typed from imagination; no human labeling sessions.

## Conventions compliance

- Branch/worktree as Phase 1; conventional commits per stage; GitHub issue `feat(attribution): project-time attribution harness` created before this phase's implementation; PR fully built, linked, never auto-merged.
