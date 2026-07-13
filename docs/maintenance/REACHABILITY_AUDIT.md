# Dart library reachability audit

Last reviewed: 2026-07-11

This is a bounded whole-library audit, not a claim that every symbol inside a
reachable library is live. It follows local Dart `import`, `export`, and
`part` directives from `lib/main.dart`, then evaluates test reachability from
all Dart files under `test/` and `integration_test/` separately.

The reviewed allowlist is
`tools/dart_reachability_allowlist.json`. Every entry requires an owner,
reason, classification, and exit condition. A passing review does not promote
a dormant prototype to a product capability.

## Run

From the repository root:

```powershell
pwsh -NoProfile -File tools/dart_reachability_audit.ps1
```

Use the optional enforcement mode only when the remaining candidates have
been reviewed or removed:

```powershell
pwsh -NoProfile -File tools/dart_reachability_audit.ps1 -FailOnUnreviewed
```

The script is deterministic and read-only: it writes no baseline, cache, or
generated report. It fails when local Dart references cannot be resolved,
allowlist fields are incomplete, allowlisted files disappear, or reviewed
files become runtime-reachable without the allowlist being reconciled.

## Current output

After the bounded cleanup, the enforced audit reports:

```text
Libraries under lib/:           437
Runtime reachable:              433
Runtime unreachable:              4 (550 lines)
Test-root-only candidates:         4
Runtime + test unreachable:        0
Reviewed candidates:               4
Unreviewed test-only:               0
Unreviewed runtime + test dead:     0
```

The four remaining entries are named in the allowlist. Enforcement with
`-FailOnUnreviewed` passes; there are no unreviewed whole-library candidates.

## Current bounded cleanup

The cleanup removed 44 libraries that had no justified production root. The
first six encoded conflicting identity, privacy, BLE ownership, or transport
semantics:

- the duplicate eight-character `EphemeralKeyManager`
- the deterministic four-byte `SensitiveContactHint`
- the alternate connection cleanup handler
- the unused discovery batch processor
- the unused background cache timer
- the unused protocol wire envelope

The subsequent bounded batches removed:

- ten obsolete archive/search/security/queue service and interface variants
- twelve Riverpod provider files that were never reached from `main.dart`
- ten unused status/search/device widgets
- six implementation islands reached only by their own dedicated tests

The dedicated tests for those six isolated implementations were removed with
them. Git history remains the recovery path; dead code was not moved into an
archive directory where it could continue to look supported.

The allowlist retains only reviewed test compatibility or dormant prototypes:
the `SimpleCrypto`/`ActiveCryptoFacade` test seam, sealed-sender payload
primitive, and disconnected change-log replay service/model. Their exit
conditions remain machine-readable in the allowlist.

## Interpretation

- **Runtime reachable:** part of the graph rooted at `lib/main.dart`.
- **Test-root-only:** not in the app graph, but imported by a test or by a
  library reached from a test.
- **Runtime + test unreachable:** a strong deletion candidate inside this
  private app repository.
- **Reviewed:** deliberately retained for the reason and only until the exit
  condition in the allowlist.
- **Unreviewed:** investigate, remove in a bounded cluster, or add only after
  an explicit owner and exit condition are established.

Flutter has no general string-based local-library loading in this app. Even
so, the audit checks libraries rather than members and cannot see unknown
external path consumers. PakConnect is marked `publish_to: none`, so no public
package compatibility is assumed.
