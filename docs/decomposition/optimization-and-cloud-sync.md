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
| `Capture/CaptureManager.swift` + `Capture/Deduplication/FrameDeduplicator.swift` | Adaptive capture + dedup behavior | **Audit-confirmed (2026-09-07):** similarity computed twice — `CaptureManager.swift:857` (logging) then `shouldKeepFrame` at :858 → `FrameDeduplicator.swift:34`. ~10k sampled pixels ×2; first frames/dimension changes exempt; the dHash path is NOT used here |
| `Processing/FrameProcessingQueue.swift`, `Processing/OCR/VisionOCR.swift`, `FullFrameOCRCache.swift` | Durable OCR queue, tile/region reuse | **Audit-confirmed:** finalized-video OCR does a lossy TIFF/JPEG round trip (CGImage→NSImage→TIFF→JPEG 0.8→decode→BGRA: `StorageManager.swift:725,1230`, `FrameProcessingQueue.swift:1368,1582`); live Vision path is clean (CGDataProvider→`VNImageRequestHandler`, `VisionOCR.swift:619,713`); active-segment OCR reads WAL raw, no JPEG |
| `Database/Queries/NodeQueries.swift` (`insertBatch`:43) | Node insertion | **Audit-found:** prepared statement but NO enclosing transaction — one autocommit per OCR node |
| `Storage/VideoEncoder/HEVCEncoder.swift` | Hardware HEVC encoding (working) | Headroom unmeasured |
| `Storage/FileManager/DirectoryManager.swift` | Chunk layout `chunks/YYYYMM/DD/<videoID>` | — |
| `Storage/StorageManager.swift` (`SegmentRewriteArtifacts`, line 16) | Proof chunks get mutated: backup URL → replace, recovery modes | Sync must detect changed content, not assume immutability |
| `Database/ReadConnectionSupport.swift` | Read-only DB open incl. key retrieval | Live WAL writes make naive copies unsafe — snapshots must use the SQLite backup API |
| `video`/`segment`/`frame` tables | Authoritative file metadata for manifests | — |
| `App/RetentionManager.swift` | Local deletions happen | Cloud deletion policy needed |
| `Shared/Logging.swift` `Log.recordLatency` | Latency instrumentation | **Audit finding:** hot paths have no direct `recordLatency` calls; harvestable instead: `[Queue-DIAG] … COMPLETED` (processing duration), `[DB-ACTOR] HOLD` (censored at 200 ms threshold), `[PERF]` p50/p95 summaries, `timeline.live_ocr.total_ms` (UI, keep separate). Stage 0 must add or harvest deliberately |

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

### Track A — Performance optimization (quality-gated; candidates audit-verified 2026-09-07, magnitudes are hypotheses until Stage 0 measures)

#### Stage A1 — Dedup similarity reuse

- **Produces:** fix passing the already-computed similarity into `shouldKeepFrame` (keep no-reference/dimension guards), removing the second ~10k-pixel scan (`CaptureManager.swift:857-858`, `FrameDeduplicator.swift:34`).
- **Verified by:** corpus replay yields a bit-identical retained-frame ID sequence; measured CPU reduction; capture latency p95 not worse; module tests pass.
- **Why separate:** smallest provably behavior-preserving change; lands the gate workflow first.
- **Reality check:** Stage 0 baseline numbers.

#### Stage A2 — OCR-path efficiency (JPEG round trip, tile partition, ledger snapshots)

- **Produces:** (a) eliminate the finalized-video OCR TIFF/JPEG round trip by returning decoded BGRA through a storage API — **input pixels change** (lossy JPEG removed), so OCR output equivalence is a mandatory measured gate (text, confidence, boxes, search recall on real frames); (b) partition cached regions against changed tiles only, O(R×T)→O(T+R×C) with exactly-equal affected/unaffected lists required (`FullFrameOCRCache.swift:88`, `TileChangeDetector.swift:24`); (c) lightweight totals snapshots for the memory-attribution ledger instead of full sorted materializations (`VisionOCR.swift:314`, `Logging.swift:1077,1130`).
- **Verified by:** per-subchange gates: (a) OCR-output equivalence or approved quality-neutral diff; (b) exactly-equal partition results on real tile/region sets; (c) identical totals/order with measured CPU reduction.
- **Why separate:** OCR text is the Phase 2 evidence; (a) is the only change allowed to alter OCR output at all, and only through an explicit quality-neutral verdict.
- **Reality check:** Stage 0 OCR reference on real frames.

#### Stage A3 — DB node-insert transaction batching

- **Produces:** wrap `NodeQueries.insertBatch` stepping in one transaction inside a single actor operation (`FrameProcessingQueue.swift:1293`, `NodeQueries.swift:43`, `DatabaseManager.swift:361`); N autocommits → 1.
- **Verified by:** replay real OCR results into a disposable DB; batch latency, commit count, WAL bytes measured; node ordering, offsets, encrypted text, rollback semantics unchanged.
- **Why separate:** audit rank #1 (impact × confidence ÷ risk); touches durability semantics so it needs its own crash-safety verification.
- **Reality check:** real OCR replay corpus.

#### Stage A4 — Idle wakeups + encoder backpressure + storage policy (highest-risk gate)

- **Produces:** (a) wake idle OCR workers on enqueue instead of 100 ms polling (`FrameProcessingQueue.swift:1127`, `DatabaseManager.swift:4010`) — lost-wakeup prevention required; (b) replace encoder readiness 1 ms sleep-polling (up to ~1000 wakeups/s backpressured, `HEVCEncoder.swift:513`) with readiness-driven suspension preserving cancellation/order/exactly-once append; (c) encoder settings/segment policy changes ONLY where Stage 0 visual gates prove no readability loss, else documented no-op.
- **Verified by:** idle-wakeup and enqueue-to-start p95 measurements; append latency under backlog; visual quality gate; root `AGENTS.md` rule-6 UI smoke checks.
- **Why separate:** scheduling/backpressure changes can introduce rare race bugs; they land last, behind the strongest verification.
- **Reality check:** Stage 0 baselines.

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
