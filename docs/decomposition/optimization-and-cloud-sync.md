# Optimization + Cloud Sync (Phase 1) — Staged Decomposition

- **Status:** DRAFT — awaiting explicit user approval (no implementation until approved)
- **Date:** 2026-09-07 (revised same day: phase 1 scope = cloud storage + heavy performance optimization + CLI; LLM attribution is Phase 2, `project-time-attribution.md`)
- **Branch:** `feat/project-time-attribution`
- **Methodology:** staged-decomposition (each stage produces a named, independently verifiable artifact; real fixtures, never imagination)

---

## Product summary

Phase 1 builds the foundation with one CLI (`retrace`, subcommands grow across stages) and two engineering tracks:

- **Track A — Heavy performance optimization:** cut local compute (CPU/energy/latency) and storage growth in the capture → dedup → OCR → encode pipeline **without sacrificing recording, image, OCR, or search quality**. Every optimization lands only behind a quality gate measured against a real baseline.
- **Track B — Cloud storage sync:** back up video chunks + DB snapshots to **Backblaze B2** (S3-compatible, ~$6.95/TB/mo at research time — recheck at implementation), revision-aware because finalized chunks can be rewritten by redaction/deletion.

Tracks are independent after Stage 0. Recommended execution: B1 first (data protection soonest), then A1–A3 interleaved with B2–B4 as measurements allow.

### Locked decisions

| Decision | Value |
|---|---|
| Provider | Backblaze B2 (approved 2026-09-07) |
| CLI | Single executable `retrace` (`Sources/RetraceCLI/`, pattern: `Sources/TestMostRecentFrame`); Phase 2 adds `export`/`report`/`correct` subcommands |
| Local footprint | CLI is read-only against app data; never initializes `AppCoordinator`/`ServiceContainer` |
| Mutations | Chunks are mutable (redaction rewrites via backup-URL replace) — sync is revision-aware |
| Deletions | Tombstones by default; hard-delete only via explicit command |
| Quality policy | No optimization lands without passing its Stage 0 quality gate on the real corpus |
| Credentials | Env/keychain; never in repo |

## A — What exists and is trusted

| Artifact | Trusted for | Known limitations |
|---|---|---|
| `Capture/CaptureManager.swift` + `Capture/Deduplication/FrameDeduplicator.swift` | Adaptive capture + dedup behavior | Similarity appears computed twice on the diagnostic/`shouldKeepFrame` path — candidate, unmeasured |
| `Processing/FrameProcessingQueue.swift`, `Processing/OCR/VisionOCR.swift`, `FullFrameOCRCache.swift` | Durable OCR queue, tile/region reuse | Some paths perform avoidable image conversions — candidate, unmeasured |
| `Storage/VideoEncoder/HEVCEncoder.swift` | Hardware HEVC encoding (working) | Headroom unmeasured |
| `Storage/FileManager/DirectoryManager.swift` | Chunk layout `chunks/YYYYMM/DD/<videoID>` | — |
| `Storage/StorageManager.swift` (`SegmentRewriteArtifacts`, line 16) | Proof chunks get mutated: backup URL → replace, recovery modes | Sync must detect changed content, not assume immutability |
| `Database/ReadConnectionSupport.swift` | Read-only DB open incl. key retrieval | Live WAL writes make naive copies unsafe — snapshots must use the SQLite backup API |
| `video`/`segment`/`frame` tables | Authoritative file metadata for manifests | — |
| `App/RetentionManager.swift` | Local deletions happen | Cloud deletion policy needed |
| `Shared/Logging.swift` `Log.recordLatency` | Existing latency instrumentation | p50/p95 baselines not yet recorded for our paths |

## D — Observable end state

1. `retrace baseline` produces a re-runnable performance + quality + storage report (CPU/energy/latency p50–p95, OCR quality reference, visual quality samples, storage inventory).
2. Landed optimizations measurably reduce CPU/energy/storage growth while quality gates stay green (frame-retention sets identical or quality-neutral, OCR output equality, visual readability preserved, search unchanged, UI smoke checks pass per root `AGENTS.md` rule 6).
3. `retrace sync` incrementally uploads chunks + consistent DB snapshots to B2; idempotent, resumable, revision-aware, tombstoning deletions; bandwidth/cost reported.
4. `retrace status | verify | restore --day YYYY-MM-DD` work end-to-end; a restore opens read-only.
5. All of it safe to run while Retrace is recording; `daily_metrics` instrumentation for sync runs; credentials never in repo.

---

## Isolation — the hard components

Two things must not leak:

1. **The sync manifest** — one authoritative record of uploaded objects, hashes, revisions. Inferred-from-listing state silently diverges on rewrites/crashes. Lives in `Storage/CloudSync/`; single consumer: the CLI.
2. **The quality-gate harness** — Stage 0's measurement scripts + corpus comparisons are the only arbiter of "no quality loss." Optimizations may not weaken their own gates; gate scripts live committed and re-runnable, owned by this phase (invoked per-module in that module's tests where behavioral).

Forbidden: `UI/` importing sync internals; sync writing anywhere in local storage except its own manifest DB; landing any Track A change whose gate result isn't committed alongside it.

---

## Stages

### Stage 0 — Baseline & inventory (shared instrumentation; everything depends on it)

- **Produces:** committed, re-runnable baseline: (a) capture/OCR/encode CPU + energy + `Log.recordLatency` p50/p95 during real sessions; (b) OCR quality reference — Vision OCR output frozen over the corpus; (c) encoded-frame visual quality samples; (d) storage inventory — object count, sizes, monthly growth, mutation/rewrite frequency; (e) live-DB snapshot consistency check (SQLite backup API vs naive copy while recording).
- **Verified by:** scripts run twice, numbers stable within noise; outputs committed as the fixture/gate baseline; inventory reconciles with `video` table counts.
- **Why separate:** optimization without a baseline is unfalsifiable; sync cost model needs real object counts; quality gates need a frozen reference. This is the stage that makes every later "verified by" honest.
- **Reality check:** the author's real machine, real recording sessions, real storage root.

### Track A — Performance optimization (quality-gated)

#### Stage A1 — Dedup/similarity double computation

- **Produces:** fix in `Capture/` removing the duplicate similarity computation (diagnostic + `shouldKeepFrame` adaptive path).
- **Verified by:** corpus replay yields a bit-identical retained-frame ID sequence; measured CPU reduction in the capture loop; capture latency p95 not worse; module tests pass.
- **Why separate:** smallest, provably behavior-preserving change; lands the gate workflow on an easy case first.
- **Reality check:** Stage 0 baseline numbers.

#### Stage A2 — OCR image-conversion reduction

- **Produces:** removal of avoidable pixel conversions on OCR paths in `Processing/`, plus decode/tile-reuse where equivalence is proven.
- **Verified by:** OCR output equality gate vs the frozen Stage 0 reference across the whole corpus (any diff must be proven quality-neutral and explicitly approved); per-frame CPU/time delta measured; processing-queue tests pass.
- **Why separate:** OCR text is the evidence Phase 2 attributes against — equality is mandatory before landing, and it needs its own gate.
- **Reality check:** Stage 0 OCR reference on real frames.

#### Stage A3 — Encode/storage efficiency (highest-risk gate)

- **Produces:** measured-only changes to encoder settings or segment policies **where visual quality gates prove no readability loss**; otherwise a documented no-op with the numbers that justified rejection.
- **Verified by:** visual quality gate vs baseline samples; storage growth delta; root `AGENTS.md` rule-6 UI smoke checks (timeline reopen, search overlay, storage picker) pass.
- **Why separate:** this is where "aggressive" could destroy future attribution evidence; it gets the hardest gate and must be independently auditable.
- **Reality check:** Stage 0 visual + storage baselines.

### Track B — Cloud sync

#### Stage B1 — Manifest + B2 client + CLI skeleton

- **Produces:** `Storage/CloudSync/`: content-addressed manifest (local SQLite: key, SHA-256, size, revision, upload state), S3-client wrapper for B2 (library decision here: Soto vs aws-sdk-swift vs minimal REST, documented), `retrace` executable with `status` reading the manifest.
- **Verified by:** manifest crash-safety tests (kill mid-record → reopen consistent); one opt-in live B2 smoke (put/get/delete one object, credentials via env); library rationale committed.
- **Why separate:** upload correctness and crash resumability are testable with zero policy; the manifest substrate is the trust anchor for everything above.
- **Reality check:** real chunk files from Stage 0 inventory.

#### Stage B2 — Incremental upload + revision policy

- **Produces:** `retrace sync`: new chunks upload; hash change → new revision + tombstone of prior; retention deletions → tombstones; deltas only.
- **Verified by:** end-to-end on the real corpus: initial sync → simulated rewrite (existing segment-rewrite test machinery) → re-sync touches only the mutated object; crash-injection mid-upload resumes without duplicates; bandwidth report matches bytes transferred.
- **Why separate:** the data-trust layer; policy bugs (silent overwrite, missed rewrite) must be independently provable before DB snapshots ride on top.
- **Reality check:** real mutation patterns measured in Stage 0.

#### Stage B3 — DB snapshot sync

- **Produces:** consistent DB snapshots via SQLite backup API → compressed (encrypted if a master key is configured) upload on cadence; snapshot lineage in the manifest.
- **Verified by:** restored snapshot opens read-only; snapshot taken during active recording passes integrity check; FTS-included vs rebuild decision measured and recorded.
- **Why separate:** live-WAL consistency is its own failure domain.
- **Reality check:** live database during a real recording session.

#### Stage B4 — Verify, restore, metrics

- **Produces:** `retrace verify` (remote hash spot-checks), `retrace restore --day`, polished `status`, cost/bandwidth reporting, `daily_metrics` emission, final `AGENTS.md` updates (`Storage/AGENTS.md` for CloudSync; root tree for `Sources/RetraceCLI/`).
- **Verified by:** full backup → verify → restore cycle on real data; restored day opens via read-only connection; metrics recorded; docs current.
- **Why separate:** restore is the acceptance test that makes backup real.
- **Reality check:** a real restore of a real recorded day.

---

## Unknowns (explicit)

1. **Which optimization candidates survive measurement** — Stage 0 may show some "obvious" wins are noise; the gate decides, not intuition.
2. **Energy measurement tooling** on macOS for the baseline (Xcode Energy Gauge vs `powermetrics`) — chosen in Stage 0.
3. **B2 current pricing + request-class costs** — recheck at B1; cost model updated from Stage 0 object counts.
4. **S3 client library** — decided at B1 with rationale.
5. **Cloud-copy encryption policy** — pass-through vs re-encrypt vs never-plaintext-upload (default lean: never upload plaintext); explicit decision before B3.
6. **DB snapshot size** — FTS inclusion vs rebuild-on-restore; measured at B3.
7. **Bandwidth throttling during user activity** — policy after B2 measurements.
8. **Local-disk eviction (cloud-only mode)** — out of scope; future workstream once backup is proven.
9. **Encoder headroom** — A3 may legitimately conclude "no change"; that is a valid outcome, not a failure.

## Fixture plan

- Stage 0 baseline outputs = the frozen reference corpus for all quality gates (real sessions, real frames, real storage).
- Track A gates replay that corpus; any diff is evidence, never edited away.
- Track B mutation fixtures = existing segment-rewrite test machinery on real files; crash injection at deterministic kill points; live B2 smoke opt-in, never in CI.
- Nothing hand-typed from imagination.

## Conventions compliance

- Same worktree/branch; conventional commits per stage; GitHub issues `perf(pipeline): quality-gated local pipeline optimization` and `feat(sync): B2 cloud backup via retrace CLI` created before the respective tracks start; PRs fully built, linked, never auto-merged.
