# Optimization + Cloud Sync (Phase 1) — Staged Decomposition

- **Status:** Phase 1 implementation authorized in the fork. Stage 0 CLI substrate in progress; later stages remain gated by the verification requirements below.
- **Date:** 2026-09-07 (revised same day: phase 1 scope = cloud storage + heavy performance optimization + CLI; LLM attribution is Phase 2, `project-time-attribution.md`)
- **Branch:** `feat/phase1-foundation` (renamed from the planning branch; same isolated worktree)
- **Remote boundary:** only `https://github.com/Juliusolsson05/retrace-llm.git`. No upstream pushes, issues or PRs.
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
| CLI | Single executable `retrace` (`Sources/RetraceCLI/`; other Sources targets are layout examples only). Phase 1 establishes status/inventory and privacy-safe evidence access; Phase 2 consumes that contract for reports/project memory. |
| Local footprint | CLI is read-only against app data; never initializes `AppCoordinator`/`ServiceContainer` |
| Mutations | Chunks are mutable (redaction rewrites via backup-URL replace) — sync is revision-aware |
| Deletions | Backup retention and privacy deletion are separate. Tombstones alone are insufficient for redaction/user deletion; uploads stay disabled until prior-version and snapshot purge contracts are verified. |
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

Execution slices: first deliver `retrace help/status/baseline` with JSON aggregate
metadata and bounded inventory, no App bootstrap, no OCR content exposure and a
separate CLI-owned metrics store. SQLite/FileManager tests establish this safety
boundary. This slice does NOT complete the real recording/CPU/energy/OCR baseline.
Then collect controlled real sessions and exact counters before quality-sensitive
Track A changes. Integrity regressions can use disposable production-schema
databases independently; never label them recorded screenshot-quality evidence.

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

## Audited candidate backlog (swarm audit 2026-09-08, run `opt-hunt` — all magnitudes are static hypotheses until Stage 0 measures)

Historical leads from eight launched Codex agents follow. Six produced final reports;
App and non-timeline UI were interrupted and produced preliminary leads only. The
initial pipeline auditor was separate: nine Codex assignments total, seven final
reports and two partial reports. All available outputs have now been read, including
the Capture report recovered through the transcript reader. The verification tables
below supersede the initial rankings and numerical speedup speculation.

**Search** — serial per-hit frame hydration, N DB calls per search (`SearchManager.swift:115`); late relevance filtering after expensive hydration (`:145`); repeated metadata matching per hit (`ResultRanker.swift:113`); DateFormatter churn up to 8/query (`QueryParser.swift:132`); unbounded timing history (`SearchManager.swift:151,275`).

**Database** — FTS content+junction writes lack one encompassing transaction (`FTSQueries.swift:144`); in-page URL reads/writes revalidate schema (`FrameQueries.swift:284`); fallback search groups `doc_segment` before joining matches (`FTSManager.swift:296`); bulk deletion repeatedly prepares statements (`FrameQueries.swift:1218`); statement pointer overwrite leak in the legacy document path (`DocumentQueries.swift:47,134`). Exact SQL/commit counts and performance effects need tracing; the earlier 10-100x search estimate is withdrawn, not a measured result.

**Storage/WAL** — every append invalidates the offset index → header rescan (150 frames → 11,325 header reads; `WALManager.swift:244,307,1082`); path-cache miss enumerates the entire archive, O(M×N) under retention (`StorageManager.swift:1288`, `DirectoryManager.swift:70`); recovery rewrites raw pixels into new WALs (~4.63 GiB per 150 4K frames; `RecoveryManager.swift:745,756,763`); prefix repair loads full payloads when only metadata is needed (31.6 MiB/frame; `RecoveryManager.swift:579`); ImageExtractor lacks in-flight join → duplicate generator setups (`ImageExtractor.swift:418,639`).

**Capture/metadata** — repeated AX walks on URL misses, roughly half overlapping (`BrowserURLExtractor.swift:584,848,1208`); private-window detection N×(1+2M) AX calls per attempt (`CGWindowListCapture.swift:552`, `PrivateWindowDetector.swift:81`); full 4WH BGRA allocation before dedup (31.6 MiB @4K, ~15.8 MiB/s at 0.5 Hz; `CGWindowListCapture.swift:1355,1189`); duplicate window/app metadata enumerations per retained frame (`CaptureManager.swift:1085`, `AppInfoProvider.swift:152`); lock state checked after expensive exclusion work (`CGWindowListCapture.swift:328`).

**App/UI** — serial startup init chain; retention cleanup runs full orphan-node scan + conditional vacuum; date query groups full frame history per dashboard/calendar load (no cache); timeline disk-buffer clear on the main actor → navigation freeze (`SimpleTimelineViewModel.swift:3194,3136,7922`); filesystem probes in view builders per evaluation (`SimpleTimelineView.swift:942,958`); hide destroys the timeline hosting view → full reopen reconstruction (`TimelineWindowController.swift:1911,1981`, `TimelineTapeView.swift:438`); `NSImage(data:)` resumes on main (`SimpleTimelineViewModel.swift:10571,8778`); unstable block IDs on prepend/trim (`SimpleTimelineViewModel.swift:357`, `TimelineTapeView.swift:295`); dashboard range loads issue one storage query per day; saved-search thumbnails trigger full cache-dir scans; settings render path checks path availability.

**Memory/energy** — idle-retained video generators ~128 MiB (eviction only fires on access; `ImageExtractor.swift:160`); `previousFrame` BGRA retained after OCR drains, 31.6 MiB @4K (`ProcessingManager.swift:160`); scrambler inverse-permutation allocations 15–20 MiB (`ReversibleOCRScrambler.swift:251`); watchdog 100 ms heartbeat + 200 ms check ≈ 54k executions/hour incl. paused (`Logging.swift:1351`); eager debug-string logging writes synchronously to disk — reminder ticks alone 1,800 writes/hour (`Logging.swift:85`, `PauseReminderManager.swift:164`); hidden dashboard timer still fires, 3,600 callbacks/hidden-hour (`DashboardViewModel.swift:325`).

### Integrity red flags (verify, then file issues per conventions — do NOT optimize past these)

1. **WAL durable-frontier stale overwrite** — `WALManager.swift:270` persists the durable video frontier, but `:234` later saves writer session metadata that may overwrite it with stale values; crash window between appends. Verify + fix before any WAL write-path optimization.
2. **Checkpoint completion misreported** — `DatabaseManager.swift:3482` discards checkpoint result rows and treats `SQLITE_OK` as completion; a blocked checkpoint reads as success.
3. **Statement leak** — `DocumentQueries.swift:47,134` overwrites a prepared-statement pointer without finalizing the old statement. Retained bytes have not been measured; do not project hundreds of MB without a representative run.

## Codex finding verification (2026-09-08)

Scope: source and caller verification against worktree HEAD `4b62f51`, plus two
isolated SQLite API checks. **Confirmed code does not mean measured performance.**
No recordings were read, no application behavior was changed, and no end-to-end
capture, OCR, UI, recovery or throughput benchmark was run in this review.

Verdicts: **Confirmed** = mechanism/caller exists; **Conditional** = code exists but
the claimed frequency, benefit or symptom needs profiling; **Qualified** = original
wording overstates scope or misses an important safeguard. No aggregate app speedup
can be calculated by adding these candidates.

### Initial pipeline auditor

| Finding | Verdict and evidence | Verification gate |
|---|---|---|
| Similarity evaluated twice | Confirmed: `Capture/CaptureManager.swift:857-862`, `Capture/Deduplication/FrameDeduplicator.swift:25-38`. Same-size adaptive comparisons scan twice; first frames and changed dimensions do not. Pixel sampling, not dHash. | Same retained-frame decisions including mouse-movement policy; time the comparison separately from total capture. |
| Finalized-video OCR image conversions | Confirmed: `Processing/FrameProcessingQueue.swift:1356-1392`, `Storage/StorageManager.swift:725,1230-1236`. Finalized path uses JPEG; active WAL path does not. A Vision CGImage/CVPixelBuffer round trip is refuted by `Processing/OCR/VisionOCRHelpers.swift:80-103` and `VisionOCR.swift:713`. | Removing JPEG changes input pixels. Compare text, boxes, confidence and search behavior; improvement is not automatic. |
| Per-node commits | Confirmed on normal OCR insertion: `Database/Queries/NodeQueries.swift:43-79`, `Database/DatabaseManager.swift:2358-2392,302-361`. Tracing wrapper is not a transaction. | Commit/WAL counts and rollback tests. Audit shared writer-handle callers before adding transaction scope; no weaker durability settings. |
| Detailed memory snapshots in OCR | Confirmed: `Processing/OCR/VisionOCRResidualSupport.swift:137-145`, `Shared/Logging.swift:1077-1150`, repeated calls in `Processing/OCR/VisionOCR.swift:271-466`. | Profile sort/allocation cost; preserve residual accounting and backpressure inputs. |
| Idle OCR polling | Confirmed: `Processing/FrameProcessingQueue.swift:1093-1130`, `Database/DatabaseManager.swift:4006-4036`. Empty dequeue takes BEGIN IMMEDIATE/COMMIT. Disabled/power-paused workers use slower loops. | Idle activity and enqueue latency; no lost wakeups or starvation of recovered work. An empty transaction is not necessarily a disk flush. |
| Cached-region tile scans | Confirmed: `Processing/OCR/FullFrameOCRCache.swift:88-114`. Per-region scan of cached grid with changed-key filtering and early exit. | Exact affected/unaffected lists; measure actual tile sparsity, not just worst-case complexity. |
| Encoder readiness polling | Conditional: `Storage/VideoEncoder/HEVCEncoder.swift:513-524`. One-ms sleeps occur only while input is backpressured. | Measure stalled intervals; preserve timeout, cancellation, frame order and exactly-once append. No saving when always ready. |

### Search auditor

All five findings below are in the fallback SearchManager route: normal search first
uses DataAdapter (`App/AppCoordinator.swift:3219-3233`). They are not evidence that
every normal search incurs these costs.

| Finding | Verdict and evidence | Verification gate |
|---|---|---|
| Serial hydration | Confirmed: `Search/SearchManager.swift:111-138` awaits `getFrame` per hit. | Trace actual route and calls; preserve missing-frame behavior and result ordering when batching. |
| Late relevance filtering | Conditional: `Search/SearchManager.swift:142-145`; ranker does not mutate stored relevance score (`Search/Ranking/ResultRanker.swift:31-37`). | Measure rejected fraction; preserve threshold and tie/order behavior. No benefit if all pass. |
| Repeated metadata matching | Confirmed: `Search/Ranking/ResultRanker.swift:109-133` lowercases and builds filtered collections per result. | Measure repeated metadata frequency and allocations before adding a cache. |
| DateFormatter churn | Confirmed: `Search/QueryParser/QueryParser.swift:124-159` constructs up to four formatters before relative-date parsing. | Preserve format precedence, locale and timezone behavior; measure date-filter queries only. |
| Growing statistics array | Confirmed: `Search/SearchManager.swift:151,275` appends indefinitely and reduces for averages. | Check lifetime search count, memory and numerical averaging compatibility; not a large current-memory claim. |

### Database auditor

| Finding | Verdict and evidence | Verification gate |
|---|---|---|
| FTS replacement not atomic | Confirmed: `Database/Queries/FTSQueries.swift:136-164`; caller `Database/DatabaseManager.swift:2428-2445` adds no transaction. | Failure injection between deletes/inserts, statement trace and shared-connection ownership review. |
| Repeated URL schema work | Confirmed: `Database/Queries/FrameQueries.swift:175,194,230,284-328`. Schema checks and CREATE/DROP-if-exists precede normal reads/writes. Exact 34-statement claim not measured here. | Trace current and legacy schemas; any readiness cache must invalidate when DB/schema changes. |
| Global FTS grouping | Qualified: grouped subquery exists at `Database/FTSManager.swift:296-303,344-350`; it is fallback-only. Physical plan and claimed 10-100x gain are unverified. | EXPLAIN QUERY PLAN and representative query timings; preserve latest-doc and duplicate-frame semantics. |
| Bulk-delete prepare churn | Confirmed: `Database/Queries/FrameQueries.swift:1207-1257` invokes cleanup and prepares DELETE per frame. An outer transaction already exists. | Trace preparations, writer occupancy and shared-document cleanup semantics; do not claim a missing transaction. |
| Prepared-statement leak | Confirmed: `Database/Queries/DocumentQueries.swift:16-47,110-134` resets but overwrites the pointer; defer finalizes only the last statement. Import caller: `Migration/Importers/RewindImporter.swift:433`. | SQLite ownership probe reproduced the mechanism; production import leak/RSS regression test still needed. |
| Checkpoint reports success while busy | Confirmed: `Database/DatabaseManager.swift:3475-3494` ignores result rows. Isolated SQLite test returned SQLITE_OK with busy=1. | Reproduce through DatabaseManager with a held reader; retry based on checkpoint outcome, not just API return code. |

### Storage auditor

| Finding | Verdict and evidence | Verification gate |
|---|---|---|
| WAL offsets rebuilt after append | Confirmed: `Storage/WAL/WALManager.swift:244,307-311,1082-1124`; live registration caller `App/AppCoordinator.swift:1902`. Payloads are skipped, not reread. | Count reads/seeks on sequential append/register. 11,325 is the arithmetic sum for 150 complete rescans, not measured I/O. |
| Archive scans per cold path lookup | Confirmed: `Storage/StorageManager.swift:1276-1298`, `Storage/FileManager/DirectoryManager.swift:70-84`. Cache stores only the requested match. Retention calls this at `App/RetentionManager.swift:211`. | Measure cold lookup/retention; preserve ID matching, filesystem mutations and invalidation. |
| Recovery writes another raw WAL | Conditional: `Storage/WAL/RecoveryManager.swift:745-763` uses ordinary writers; `Storage/IncrementalSegmentWriter.swift:69-78` writes WAL first. Only re-encoding recovery takes this path. | Crash-safe recovery replay and logical bytes written; retain original WAL until output/DB are safe. Not normal-recording savings. |
| Metadata repair reads full pixels | Confirmed for missing-metadata prefix repair: `Storage/WAL/RecoveryManager.swift:561-587`. Existing-frame branch skips it. | Metadata-only API must still validate complete record bounds; compare repairs and measured I/O. |
| Duplicate generator setup/decode | Conditional: `Storage/ImageExtractor.swift:418-475,639-691` uses individually locked cache operations, not a get-or-create join. | Demonstrate concurrent misses on actual callers; preserve cancellation, timestamp and mutation invalidation. No measured fourfold saving. |
| Durable frontier overwritten by stale session | Confirmed code path: `Storage/WAL/WALManager.swift:227-270`, writer-held session at `Storage/IncrementalSegmentWriter.swift:71-78`. Coordinator updates only when flushed count advances (`App/AppCoordinator.swift:1976-1994`), so later append can reset sidecar frontier without restoring it that frame. | Production append/frontier/append test plus crash recovery; do not claim demonstrated frame loss from source inspection alone. |

### Capture/metadata auditor

| Finding | Verdict and evidence | Verification gate |
|---|---|---|
| Repeated URL AX fallbacks | Confirmed on misses: `Capture/Metadata/BrowserURLExtractor.swift:584-588,830-863,1208-1235`. Successful earlier methods exit. | AX-call counts by browser/outcome; preserve fallback coverage and capture-time identity. No measured 50% saving. |
| Repeated private-window AX enumeration | Confirmed per distinct uncached title: `Capture/ScreenCapture/CGWindowListCapture.swift:532-556`, `PrivateWindowDetector.swift:75-130`. Per-attempt title/PID caching already exists. | Multiwindow capture and exclusion tests; snapshot only within the decision, never reuse stale privacy decisions. |
| Full BGRA allocation before dedup | Confirmed: `Capture/ScreenCapture/CGWindowListCapture.swift:375-384,1348-1378`. 4WH is payload arithmetic. A second Shared helper invocation on every live frame is NOT established. | Allocation/ownership and masking tests; merging helpers alone does not remove work. |
| Repeated metadata window lookup | Confirmed on retained frames: `Capture/CaptureManager.swift:1075-1102`, `Capture/Metadata/AppInfoProvider.swift:149-179`. NSWorkspace is fallback, not normal per-frame lookup. | Preserve missing-field enrichment, display and browser identity; measure call counts. |
| Lock check after exclusion work | Confirmed: `Capture/ScreenCapture/CGWindowListCapture.swift:328-333`. Monitor is notification-driven. Locked-attempt frequency remains unknown. | Early check plus existing later check; measure while awake/locked and verify unlock resumption. |

### Timeline auditor

| Finding | Verdict and evidence | Verification gate |
|---|---|---|
| Main-actor disk-buffer cleanup | Confirmed: VM is MainActor (`UI/ViewModels/SimpleTimelineViewModel.swift:555`); cleanup does synchronous enumeration/deletion at `:3136,3153-3233`, navigation caller `:7922`. | UI p95 versus cache size; async cleanup must not delete newly written data. No measured freeze duration. |
| Filesystem probes in video view builder | Confirmed: `UI/Views/FullscreenTimeline/SimpleTimelineView.swift:918-968`. | Main-thread file activity while scrubbing; preserve growing-file/missing-file readiness. |
| Reopen reconstructs presentation | Qualified: `UI/Views/FullscreenTimeline/TimelineWindowController.swift:1894-1914,1947-1987` deliberately destroys views and purges decoders to reduce hidden memory. | Compare reopen hitch versus hidden footprint; do not retain all players as an automatic fix. |
| Still-image construction on main | Conditional: `UI/ViewModels/SimpleTimelineViewModel.swift:10571-10587` constructs NSImage on main. Heavy decoding may be lazy. | Profile through first draw; constructor location alone does not prove decode cost. |
| Index-based tape identity | Confirmed: `UI/ViewModels/SimpleTimelineViewModel.swift:357-358`, `UI/Views/FullscreenTimeline/TimelineTapeView.swift:295`. | Trace visible-view lifetimes on prepend/trim; preserve intentional block merges/splits and virtualization. |
| Snapshot completion lacks publication | Confirmed mechanism: private cache/revision at `UI/ViewModels/SimpleTimelineViewModel.swift:2152-2153`, async assignment `:2293-2294`; earlier tag-map publication `:5447-5449` can precede completion. | Delayed-completion UI test; stale indicators are a plausible race, not reproduced here. |

### Memory and energy auditor

| Finding | Verdict and evidence | Verification gate |
|---|---|---|
| Generator idle expiry only on access | Qualified: `Storage/ImageExtractor.swift:149-183`; explicit purge exists and timeline hide invokes it (`UI/Views/FullscreenTimeline/TimelineWindowController.swift:1911-1913`). | Profile idle with window still open. 128 MiB is an internal estimate, not measured retained RSS. |
| Previous OCR frame retained | Confirmed: `Processing/ProcessingManager.swift:160` assigns even after full-frame OCR; explicit invalidation clears it at `:336-356`. | Measure idle/pause lifetime; clearing trades memory for a full OCR pass on resume. |
| Scrambler permutation allocations | Conditional: `Shared/ReversibleOCRScrambler.swift:251-269,433-458`; prime-like dimensions can fall back to pixel blocks. | Profile actual patch sizes and exact round-trip compatibility. Allocation arithmetic is not observed peak memory. |
| Watchdog periodic activity | Confirmed schedules: `Shared/Logging.swift:1349-1366`. 10+5 callbacks/second is nominal activity, NOT measured hardware wakeups or energy. | Energy/System Trace; preserve hang detection and recovery policy. |
| Eager debug logging/file writes | Confirmed: `Shared/Logging.swift:85-98,273-293,410-429`; reminder logs at `UI/Components/PauseReminderManager.swift:164`. Verbose console-only logging has a separate path. | Measure write syscalls/CPU; buffered writes are not per-message fsync or guaranteed physical disk writes. |
| Hidden dashboard timer | Qualified: `UI/ViewModels/DashboardViewModel.swift:322-343` still schedules callbacks/tasks but skips DB/status refresh when hidden and coalesces overlap. | Measure idle callbacks; do not describe it as hidden full-dashboard querying. |

### Interrupted App and non-timeline UI leads

These were not complete Codex reviews. Parent source verification supplies the
references and qualifications below; Claude is independently reviewing these areas.

| Lead | Verdict and evidence | Verification gate |
|---|---|---|
| Serial startup initialization | Conditional: `App/ServiceContainer.swift:229-358`; database/FTS/storage/adapter have real dependencies and side effects. | Startup critical-path trace before parallelizing; serial order itself is not a bug. |
| Retention orphan scan and vacuum | Qualified: `App/RetentionManager.swift:161` skips all cleanup for Forever; `:231-238` scans nodes during configured cleanup and vacuums only past deletion thresholds. | Measure configured retention separately from baseline startup; preserve cleanup correctness. |
| Distinct-date aggregation | Confirmed in adapter: `App/DataAdapter.swift:5046-5072,5122-5172`. Source-boundary/visibility filters apply; no result cache in this method. | Query plan and repeated dashboard/calendar loads; maintain timezone/filter/source invalidation. |
| Per-day dashboard storage loads | Confirmed: `UI/ViewModels/DashboardViewModel.swift:1960-2022`; DB estimates already batched, storage calls serial per day. Range caching exists at `:1732-1744`. | Measure cache-miss ranges and existing storage latency metrics; not every timer tick. |
| Thumbnail directory scan on each save | Confirmed: `UI/ViewModels/SearchViewModel.swift:724-737,758-795`; trimming runs detached, not on main. TIFF materialization is before detach. | I/O/CPU under thumbnail bursts; coalesce trimming without breaking limits or racing writes. |
| Settings path probes in rendering | Confirmed: `UI/Views/Settings/SettingsView.swift:241-257`, references in `Sections/StorageSettingsView.swift:166-177,235-246`. | Main-thread file activity on slow/offline volumes; distinguish render probes from background picker validation. |

### Verification evidence and limits

- Isolated C probe using system SQLite 3.51.0: after reset/clear, preparing into the
  same pointer and finalizing only the new statement leaves **one live statement**.
- Held-reader WAL probe: `PRAGMA wal_checkpoint(TRUNCATE)` returned row
  `busy=1, log=4, checkpointed=3` while `sqlite3_exec` returned **0 / SQLITE_OK**.
- Probe source: temporary `retrace_sqlite_review.c` outside the repository. It used
  disposable databases only. These test SQLite API contracts, not Retrace's entire
  SQLCipher/actor/recovery integration. Initial probe cleanup needed to account for
  retained WAL/SHM sidecars; rerun passed both checks and cleanup.
- Existing writer/read pooling, cached ranking scores, notification-driven lock
  monitoring, coalesced timeline startup, visibility-gated dashboard work, explicit
  decoder purges and configured retention guards must remain intact.
- Read-only CLI access must avoid query helpers that perform schema maintenance
  (notably in-page URL getters). The plan still needs Phase 1 evidence/data exposure
  rather than deferring all `export` work until the LLM phase.
- No production fixes, benchmark-derived speedups, quality guarantees, cloud uploads
  or full application test-suite results are claimed by this verification pass.

## Claude cross-review reconciliation (2026-09-08)

All four Claude reviewers completed in run `claude-audit-retry`; their full visible
reports were read. They provide independent source review, not benchmark evidence.
The conclusions below incorporate parent checks rather than accepting every claim.

### Confirmed bugs and tracking

| Issue | Verified conclusion | Limit |
|---|---|---|
| [#3](https://github.com/Juliusolsson05/retrace-llm/issues/3) | Retention raw DELETE at `App/RetentionManager.swift:410-416` bypasses `FTSQueries.deleteForFrame`. `doc_segment` has no foreign key (`Database/Migrations/V1_InitialSchema.swift:228-233`), unlike node's cascade at `:111`. No frame-to-FTS cleanup trigger was found. Obsolete indexed text can survive retention. | Full RetentionManager regression still required; do not equate invisible search results with deleted stored content. |
| [#4](https://github.com/Juliusolsson05/retrace-llm/issues/4) | Writer-held WAL metadata overwrites the disk-only durable frontier on the next append. `App/AppCoordinator.swift:1976` only updates again when flushed count advances. | Confirmed ownership defect, not demonstrated frame loss. Raw WAL can still allow recovery; the exact fraction of time frontier is zero is unmeasured. |
| [#5](https://github.com/Juliusolsson05/retrace-llm/issues/5) | Document statement overwrite leaks a locally owned statement. Live OCR bypasses this legacy import path. Deferred close at `Database/DatabaseManager.swift:501` does not repair ownership. | SQLite contract reproduced; production-method statement-count and import tests pending. |
| [#6](https://github.com/Juliusolsson05/retrace-llm/issues/6) | Explicit checkpoint ignores busy result row. Current reach includes close; planned concurrent CLI readers make handling important. | SQLite contract reproduced, not full app concurrency test. Proper SQLite backup does not depend on a successful prior checkpoint. |

These are bug records, not completed fixes. Issues distinguish observed source/API
evidence from proposed reproduction steps; no private data was posted.

### Additional useful findings

- Dashboard total-storage calculation recursively walks `chunks/` inside the
  StorageManager actor (`Storage/StorageManager.swift:1470-1493,1560-1583`). This is
  distinct from per-day queries and can contend with storage work. Existing DB file
  sizes may be stale for active files, so a simple SUM is not automatically equivalent.
- Process monitor drops its tally when hidden (`UI/Components/ProcessCPUMonitor.swift:554-558`),
  reloads at `:1473-1480`, and re-encodes/writes at `:1726-1737`. Measure actual tally
  size, CPU and I/O against the intentional memory-saving policy before changing it.
- Settings retention progress updates every 50 ms for 10 s
  (`UI/Views/Settings/Sections/SettingsUtilityActions.swift:32-50`), potentially
  amplifying the already verified render-time path probes. Scheduled updates do not
  prove exactly 200 SwiftUI body evaluations; rendering can coalesce them.
- Dashboard visible refresh includes crash-report discovery
  (`UI/ViewModels/DashboardViewModel.swift:322-340`). Hidden refresh is guarded.
  Thumbnail cache publications also warrant SwiftUI profiling; multiple publications
  do not by themselves prove a fixed number of full-card renders.
- WAL offset cache also checks file size (`Storage/WAL/WALManager.swift:841-849`).
  Removing explicit invalidation alone would NOT fix rescans after appends.

### Corrections to reviewer overstatements

- Capture metadata does NOT always read AXTitle: `Capture/Metadata/AppInfoProvider.swift:39`
  uses `visibleWindow.windowName ?? getWindowTitle(...)`, so a supplied title bypasses AX.
  The redundant window-list lookup is still a valid lead.
- There ARE DataAdapter routing/filter tests in `App/Tests/InPageURLCaptureRoutingTests.swift`,
  including distinct-date, source-cutoff and filter cases. They do not establish a
  complete future CLI-export equivalence contract, but "no tests" is incorrect.
- Not all OCR text is encrypted by the scrambler. Protected/redacted text and the
  database's optional SQLCipher encryption are separate concerns. Do not automatically
  decrypt protected content for the future LLM exporter.
- Node orphan cleanup is normally redundant when FK integrity holds; it is NOT
  guaranteed a no-op for every migrated/damaged historical DB. Verify that invariant
  before deleting repair behavior.
- The raw-byte math, watchdog schedule counts and diagnostic thresholds are not
  observed latency, physical wakeups, energy or memory savings. Startup serialization
  has dependencies; recovery gating and actor contention need workload measurements.
- Skipping BGRA zero-initialization is NOT accepted as automatically behavior-neutral.
  Full pixel/padding initialization, alpha/compositing and immutable ownership must be
  proved first, especially for privacy-masked frames.
- Short independent read transactions do NOT guarantee a single cross-batch snapshot.
  The CLI needs an explicit consistent-read contract and bounded writer interference.

### Plan gates before implementation continues

Stage 0 instrumentation can proceed, but cloud upload/restore implementation must
resolve these gaps. Earlier "locked" tombstone/encryption statements are provisional
where they conflict with the following requirements; no unsafe default is approved.

1. **CLI data exposure belongs in Phase 1.** Define versioned, paginated evidence
   access for the LLM extension, including visibility, source, redaction and date
   semantics. `Sources/TestMostRecentFrame` is a target-layout example ONLY, never a
   bootstrap example. Do not initialize AppCoordinator or call read helpers that do DDL.
2. **Consistent backup recovery point.** Each database snapshot must reference exact
   media revisions, with a policy for in-flight video/WAL and pending redaction. A
   SQLite integrity check alone does not verify media completeness. Resolve day ranges
   through frame timestamps, not segment-directory day names.
3. **Privacy deletion differs from backup retention.** Tombstoning old revisions
   retains their pixels/OCR. Define deletion/redaction propagation across all affected
   media versions, snapshots, provider versions and downstream caches before upload.
4. **Key recovery and complete restore.** Define cloud encryption/key ownership without
   conflating SQLCipher and the OCR master key. Back up the remote manifest/index and
   referenced attachments, or explicitly exclude them from the recovery contract.
   Acceptance must restore on an empty root without the old local manifest/keychain.
5. **A meaningful capture baseline.** Stored history contains kept frames only. Pixel
   or dedup changes need a bounded, local, privacy-preserving pre-dedup corpus with
   exact decisions/thresholds/mouse and trigger context, including dropped attempts.
   Rounded diagnostic similarity strings alone cannot verify threshold-edge equality.
6. **Repeatable performance and privacy gates.** Specify fixed scenarios, sample counts,
   warm/cold conditions and statistical tolerances during instrumentation design.
   Add uncensored capture stage timing and exact operation counters; compare URL and
   exclusion behavior on controlled real-browser runs. Do not treat two arbitrary
   sessions as comparable or claim blur non-recoverability from visual inspection alone.

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
