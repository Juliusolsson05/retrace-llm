# Cloud Storage Sync — Staged Decomposition

- **Status:** DRAFT — awaiting explicit user approval (no implementation until approved)
- **Date:** 2026-09-07
- **Branch:** `feat/project-time-attribution`
- **Build order:** **Phase 1 (this doc — build first)** → CLI foundation. LLM attribution harness is Phase 2 (`project-time-attribution.md`), built after this ships.
- **Methodology:** staged-decomposition (each stage produces a named, independently verifiable artifact; real fixtures, never imagination)

---

## Product summary

Back up Retrace's recorded evidence (video chunks + database) to **Backblaze B2** (S3-compatible, ~$6.95/TB/mo at research time — recheck before implementation) so local storage stops being the single copy and the local disk burden can eventually be reduced. Shipped as a CLI (`retrace-sync`) that runs alongside the app without app initialization side effects.

### Locked decisions

| Decision | Value |
|---|---|
| Provider | Backblaze B2 (approved direction 2026-09-07) |
| Vehicle | CLI first (`retrace-sync`); in-app UI later |
| Local footprint | Read-only against local data; never initializes `AppCoordinator`/`ServiceContainer` |
| Mutations | Finalized chunks CAN be rewritten (redaction/deletion) — sync is **revision-aware**, not write-once |
| Deletions | Propagate as tombstones; hard-delete only via explicit command (default policy) |
| Credentials | Env/keychain; never in repo |

## A — What exists and is trusted

| Artifact | Trusted for | Known limitations |
|---|---|---|
| `Storage/FileManager/DirectoryManager.swift` | Chunk layout under `chunks/YYYYMM/DD/<videoID>` | — |
| `Storage/StorageManager.swift` (`SegmentRewriteArtifacts`, line 16) | Proof chunks get mutated: backup URL → replace, recovery modes | Sync must detect changed content, not assume immutability |
| `Database/ReadConnectionSupport.swift` | Read-only DB open incl. key retrieval | Live WAL writes make naive file copies unsafe — must use SQLite backup API for snapshots |
| `video` / `segment` / `frame` tables | Authoritative file metadata to drive manifests | — |
| `App/RetentionManager.swift` | Local deletions happen | Cloud deletion policy needed (tombstones) |
| `Shared/AppPaths.swift` | Configurable storage roots | — |
| `Shared/MasterKeyManager.swift` | Optional at-rest encryption exists | Whether cloud copy is encrypted depends on local config — policy decision below |

## D — Observable end state

1. `retrace-sync sync` incrementally uploads new finalized chunks + a consistent DB snapshot to B2; idempotent, resumable after crash mid-upload, bandwidth-reported.
2. Changed chunks (redaction rewrites) upload as new revisions; old revisions tombstoned per policy — never silently diverging.
3. `retrace-sync status` shows local/cloud delta, sizes, revision count, last sync. `retrace-sync verify` checks content hashes remotely. `retrace-sync restore --day YYYY-MM-DD` brings a day back to a target directory.
4. Safe to run while Retrace is recording (proven by concurrent-run test).
5. Zero app side effects; credentials from env/keychain; `daily_metrics` instrumentation for sync runs.

---

## Isolation — the hard component

The hard part is the **manifest: one authoritative record of what is uploaded, at which revision, with which content hash**. If sync state is inferred ad hoc from listing calls, rewrites and crashes will silently diverge local and cloud truth.

- **Location:** `Storage/CloudSync/` (new, own section in `Storage/AGENTS.md`). CLI target `Sources/RetraceSync/` (pattern: `Sources/TestMostRecentFrame`).
- **Single consumer:** the CLI. Nothing else imports `Storage/CloudSync/` until in-app UI exists (later workstream).
- **Forbidden:** `UI/` importing sync internals; sync code writing anywhere in local storage except its own manifest DB.

---

## Stages

### Stage 0 — Sync inventory & mutation measurement

- **Produces:** committed, re-runnable inventory script over the real storage root: object count, total/median chunk size, monthly growth rate; measured frequency of rewrite/backup artifacts; a live-DB snapshot consistency check (SQLite backup API vs naive copy while recording).
- **Verified by:** inventory counts reconcile against `video` table; script output committed as the fixture baseline.
- **Why separate:** revision policy and cost projections must come from measured mutation frequency and real object sizes, not assumptions.
- **Reality check:** the author's actual chunks directory and live DB.

### Stage 1 — Manifest + B2 client foundation

- **Produces:** `Storage/CloudSync/`: content-addressed manifest (local SQLite: object key, SHA-256, size, revision, upload state), S3-client wrapper against B2 (library decision here: Soto vs aws-sdk-swift vs minimal REST), `retrace-sync` executable skeleton with `status` reading the manifest.
- **Verified by:** manifest crash-safety tests (kill mid-record → reopen consistent); one opt-in live B2 smoke (put/get/delete one object with real credentials); library choice documented in the commit.
- **Why separate:** upload correctness and crash resumability are testable with zero policy in place; wrong manifest substrate poisons everything above.
- **Reality check:** real chunk files from the Stage 0 inventory.

### Stage 2 — Incremental upload + revision policy

- **Produces:** `sync` engine: new chunks upload; hash-change → new revision + tombstone of prior; retention deletions → tombstones; only deltas transfer.
- **Verified by:** end-to-end on the real corpus: initial sync → simulated rewrite (using existing test rewrite machinery) → re-sync touches only the mutated object; crash-injection mid-upload resumes without duplicates; bandwidth report matches bytes transferred.
- **Why separate:** this is the data-trust layer; policy bugs (silent overwrite, missed rewrite) must be independently provable before DB snapshots ride on top.
- **Reality check:** real mutation patterns measured in Stage 0.

### Stage 3 — DB snapshot sync

- **Produces:** consistent DB snapshots via SQLite backup API → compressed (and encrypted if a master key is configured) upload on cadence; manifest records snapshot lineage.
- **Verified by:** restore a snapshot to a temp dir and open it read-only successfully; snapshot taken while the app is actively recording passes integrity check; size reported (FTS index included vs rebuilt — measured decision recorded).
- **Why separate:** live-WAL consistency is its own failure domain; it must not share code paths with chunk upload policy.
- **Reality check:** live database during an actual recording session.

### Stage 4 — Verify, restore, metrics

- **Produces:** `verify` (remote hash spot-check), `restore --day`, `status` polish, cost/bandwidth reporting, `daily_metrics` emission, final `Storage/AGENTS.md` update.
- **Verified by:** full backup → verify → restore cycle on real data; restored day opens via read-only connection; metrics recorded; docs current.
- **Why separate:** restore is the feature that makes backup real; it is the acceptance test for the whole phase.
- **Reality check:** a real restore of a real recorded day.

---

## Unknowns (explicit)

1. **B2 current pricing + rate limits** — recheck at Stage 1; cost model updated from Stage 0 inventory (object count matters: B2 bills per request class too).
2. **S3 client library** — Soto (pure Swift) vs aws-sdk-swift vs minimal REST; decided in Stage 1 with a documented rationale.
3. **Cloud-copy encryption policy** — pass-through of app encryption vs re-encrypt vs plaintext-if-local-plaintext; needs explicit decision before Stage 3 (default lean: never upload plaintext).
4. **DB snapshot size** — FTS index inclusion vs rebuild-on-restore; measured in Stage 3.
5. **Bandwidth throttling** — sync running during user activity; policy set after Stage 2 measurements.
6. **Local-disk eviction (cloud-only mode)** — explicitly out of scope here; separate future workstream once backup is proven.
7. **Restore granularity v1** — day-level proposed; full-restore command later.

## Fixture plan

- Stage 0 inventory = real storage root, script-generated, committed output.
- Stage 2 mutation fixtures = the existing segment-rewrite test machinery exercising real files.
- Crash injection = deterministic kill points in the manifest/upload loops.
- Live B2 smoke tests = opt-in (credentials via env), never in CI.
- Nothing hand-typed from imagination.

## Conventions compliance

- Same branch/worktree; conventional commits per stage; GitHub issue `feat(sync): B2 cloud backup CLI` created before implementation; PR fully built, linked, never auto-merged.
