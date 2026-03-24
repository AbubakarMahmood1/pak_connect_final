# Compatibility Cleanup Roadmap

## Summary
Execute the remaining compatibility removals as five small checkpoints, in this order:

1. Remove import/export `v1` support
2. Remove archive legacy decrypt
3. Remove legacy `v2` transport support
4. Create and approve a test rename manifest
5. Apply the mass test rename

This order is fixed. Each checkpoint ships independently, leaves the repo green, and should not be bundled with the next checkpoint.

## Checkpoints

### Checkpoint 1: Remove import/export `v1` support
Primary subsystem: `ImportService`

Implementation:
- Accept only self-contained `v2` bundles during import.
- Remove legacy external-database-path import behavior.
- Reject `v1` bundles explicitly with a stable error message instead of attempting fallback handling.
- Remove `v1`-specific docs, comments, and tests that imply support still exists.
- Keep current `v2` export format unchanged.

Acceptance:
- Valid `v2` self-contained bundles still import successfully.
- `v1` bundle fixtures fail deterministically and are asserted as rejection cases.
- No code path reads or depends on legacy external bundle DB paths.

Status: Completed on 2026-03-24.  
Commit: `6e7c661` `refactor: remove import bundle v1 support`

### Checkpoint 2: Remove archive legacy decrypt
Primary subsystem: `ArchiveCrypto`

Implementation:
- Delete legacy archive-field prefix handling and its legacy passphrase dependency.
- Make archive decrypt behavior support only the current active archive format.
- Remove legacy archive compatibility comments and test fixtures.
- Fail closed for legacy-prefixed archive payloads instead of silently decoding them.

Acceptance:
- Current archive read/write behavior still passes.
- Legacy archive fixtures are converted into explicit failure/rejection tests.
- No runtime code depends on legacy archive decrypt helpers or old passphrase defines.

Status: Completed on 2026-03-24.  
Commit: `12c34e0` `refactor: remove archive legacy decrypt`

### Checkpoint 3: Remove legacy `v2` transport support
Primary subsystems: outbound send, inbound processing, protocol handling, crypto header model

Implementation:
- Delete legacy `v2` send/decrypt policy flags and all behavior guarded by them.
- Remove legacy transport modes for pairing/ECDH/global from the crypto header model and wire parsing.
- Keep only active transport modes that are still part of the current protocol.
- Update outbound and inbound handlers to reject legacy `v2` transport payloads deterministically.
- Keep unrelated `v1` protocol fallback untouched.

Acceptance:
- Active transport flows still pass end-to-end.
- Legacy `v2` transport fixtures are rejected with stable, asserted behavior.
- No send/decrypt code path depends on legacy `v2` compatibility flags.

Status: Completed on 2026-03-24.  
Commit: `bb03915` `refactor: remove legacy v2 transport support`

### Checkpoint 4: Create and approve the test rename manifest
Scope: file names and human-readable `group` / `test` titles only.

Implementation:
- Inventory every `test/**` file whose filename contains `phaseNN`.
- Produce a manifest mapping each old filename to a behavior-based filename.
- Use a simple naming rule:
  - drop `phaseNN`
  - prefer a behavior slug taken from the first real `group()` / `test()` label in the file
  - keep directory placement unchanged
  - add a numeric suffix only when two behavior-based candidates would collide
- Review the manifest before any rename happens.

Acceptance:
- Manifest covers all current `phaseNN` test files.
- Proposed names are unique, behavior-based, and import-safe.
- No runtime code changes happen in this checkpoint.

Status: Completed on 2026-03-24.  
Output: `docs/refactoring/test_rename_manifest.md`

### Checkpoint 5: Apply the mass test rename
Implementation:
- Rename files according to the approved manifest.
- Update imports, generated references, test runner paths, docs, and any scripts that reference the old names.
- Rename human-readable `group()` and `test()` titles to match the manifest wording.
- Keep the rename pass mechanical; do not mix behavioral rewrites into this checkpoint unless required to keep the suite compiling.

Acceptance:
- Zero target test filenames still contain `phaseNN`.
- Human-readable test names no longer mention phases.
- Full suite still passes after the rename.

Status: Completed on 2026-03-24.

## Test Plan
Run focused verification at the end of each checkpoint, then a full suite at the end of checkpoints 3 and 5.

Required checkpoint validation:
- Checkpoint 1: import/export-focused tests plus import/export analyze pass.
- Checkpoint 2: archive crypto/archive service tests plus analyze on touched archive code.
- Checkpoint 3: outbound/inbound/protocol/security tests plus full `flutter test --no-pub`.
- Checkpoint 4: manifest review only.
- Checkpoint 5: full `flutter analyze --no-pub` and full `flutter test --no-pub`, with the full-suite run captured to `flutter_test_latest.log`.

Required scenario coverage:
- `v2` bundle imports succeed.
- `v1` bundle imports fail clearly.
- Legacy archive payloads fail clearly.
- Legacy `v2` transport payloads fail clearly.
- Active transport and active archive behavior remain unchanged.
- Renamed tests remain discoverable and executable by current CI/workflow patterns.

## Assumptions and Defaults
- Solo-dev context: no real users and no old data to preserve.
- Default policy is hard delete / fail closed, not another compatibility switch.
- No new runtime compatibility switches should be added for these removals.
- Test rename happens after all compatibility removals are complete.
- Rename scope is limited to file names and human-readable test titles.
