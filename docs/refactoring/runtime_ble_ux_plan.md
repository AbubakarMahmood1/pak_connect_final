# Runtime BLE UX Rework Plan

**Status (2026-07-11): Implemented/superseded historical plan.** `main.dart`
no longer uses `appBleReadyForHomeProvider` as a root navigation gate;
`PermissionScreen` is reachable from settings/import flows, and AppCore treats
BLE warm-up as a degradable background stage. Use
`docs/architecture/RUNTIME_FLOWS.md` and
`docs/status/ENGINEERING_STATUS.md` for current behavior. The analysis below
is retained to explain the change.

## Goal

Make PakConnect behave like a professional app when Bluetooth is off, permissions are missing, or BLE takes a long time to initialize.

The app should remain usable for local data and navigation. BLE should become a subsystem state inside the app, not a root navigation gate.

## What The Current Code Proves

### 1. BLE is still treated as a root-app requirement

- [main.dart](../../lib/main.dart) routes to `HomeScreen` or `PermissionScreen` based on `appBleReadyForHomeProvider`.
- [app_permission_providers.dart](../../lib/presentation/providers/app_permission_providers.dart) defines “ready for home” as:
  - Bluetooth `poweredOn`
  - and BLE permissions granted

This means runtime Bluetooth problems are currently converted into top-level navigation changes.

### 2. App bootstrap is blocked by BLE integration

- [app_core.dart](../../lib/core/app_core.dart) does not emit `AppStatus.ready` until after `_initializeBLEIntegration()`.
- The historical recovery-checkpoint log
  `logs/ble-experiments/device_a_fix_redeploy_v2_flutter_run.log` showed:
  - BLE integration took about `33703ms`
  - full app initialization took about `35996ms`

That is why the user sees a long “initializing...” screen before anything useful appears.

### 3. `PermissionScreen` is doing two incompatible jobs

- [permission_screen.dart](../../lib/presentation/screens/permission_screen.dart) acts like:
  - first-run setup
  - permission recovery
  - Bluetooth unavailable fallback
  - import/start-new entry point

That is too much responsibility for one screen, and it creates awkward runtime behavior.

### 4. Home already has the beginnings of the correct UX shape

- [home_screen.dart](../../lib/presentation/screens/home_screen.dart) already includes:
  - a BLE status banner
  - BLE state watching
  - connection info watching
  - discovery device watching

So the codebase already has enough state to support a proper in-app BLE status experience.

### 5. Backup import cannot be lost in the redesign

- [permission_screen.dart](../../lib/presentation/screens/permission_screen.dart) exposes `Import Existing Data`
- [data_storage_section.dart](../../lib/presentation/widgets/settings/data_storage_section.dart) also exposes `Import Backup`

If `PermissionScreen` stops being the root gate, we still need a first-run-visible import path.

## Product Decision

### Default direction

After app bootstrap completes, PakConnect should land on `HomeScreen`, not `PermissionScreen`.

### BLE should become:

- a header/banner/status-chip concern
- a discovery/connect action concern
- a retry/recover concern

### BLE should not become:

- a root-screen redirect after first entry
- a reason to bounce the user out of the current screen
- a blocker for reading local chats, settings, archives, or profile

## UX Rules

### Rule 1: Home stays Home

Once the app has finished core bootstrap, runtime BLE loss must not navigate the user to `PermissionScreen`.

If Bluetooth turns off while the user is in:
- Home
- Chat
- Settings
- Contacts
- Archives

they stay there.

### Rule 2: BLE problems surface inline

Use a persistent but non-blocking status surface:
- small header chip when healthy or initializing
- warning banner/card when degraded
- inline CTA buttons for:
  - Turn on Bluetooth
  - Grant Nearby Devices
  - Retry mesh startup
  - Open Settings

### Rule 3: First-run setup is separate from runtime recovery

If a full-screen setup flow remains, it must be treated as:
- first-run onboarding only
- post-panic-wipe reset only
- explicit user-invoked setup only

It must not be the generic “Bluetooth changed state, leave the app” screen.

### Rule 4: Notifications remain contextual

Notification permission should not block app entry.

It should only be requested:
- when user enables notifications in settings
- or when a future notification-specific onboarding card explicitly asks for it

### Rule 5: Import/restore must remain easy to find

If we stop using `PermissionScreen` as the root, add a visible first-run import path:
- Home empty-state CTA
- or Home app bar / overflow action
- while still keeping Settings import

## Recommended Architecture

### Phase 1: Decouple app-ready from BLE-ready

#### Objective

The app becomes usable after local/core initialization, even if BLE is still starting or unavailable.

#### Changes

- Change [app_core.dart](../../lib/core/app_core.dart) so `AppStatus.ready` is emitted after:
  - DI setup
  - database/repositories
  - message queue
  - monitoring
  - security/core local services

- Move BLE bring-up out of the critical path of app readiness.

#### Preferred implementation shape

Option A, recommended:
- `AppCore.initialize()` gets the app to local-ready
- BLE integration starts immediately after, but asynchronously
- BLE publishes its own readiness/failure state through providers already used by UI

Do not keep the whole app in `AppStatus.initializing` while BLE is negotiating.

#### Acceptance

- App can reach Home without waiting 30+ seconds for BLE
- BLE startup can still continue in the background
- A failed BLE startup no longer implies app bootstrap failure

### Phase 2: Remove BLE as a root routing condition

#### Objective

Stop using live BLE state to choose between `HomeScreen` and `PermissionScreen`.

#### Changes

- Remove the current root gate in [main.dart](../../lib/main.dart) that depends on `appBleReadyForHomeProvider`
- After app core is ready, default route becomes `HomeScreen`
- `PermissionScreen` is no longer the runtime fallback screen

#### Acceptance

- Turning Bluetooth off while in Home no longer navigates away from Home
- Turning Bluetooth back on does not cause route flicker
- Granting permission no longer causes a surprise root-screen jump

### Phase 3: Rebuild BLE runtime status as in-app UI

#### Objective

Make BLE loss/recovery visible, actionable, and non-blocking.

#### Changes

- Replace the current crude `_buildBLEStatusBanner()` in [home_screen.dart](../../lib/presentation/screens/home_screen.dart) with a richer runtime status component
- Reuse or adapt:
  - historical `bluetooth_status_widget.dart` (later removed as unreachable)
  - [bluetooth_state_models.dart](../../lib/domain/models/bluetooth_state_models.dart)

- Show specific states:
  - Bluetooth off
  - Nearby Devices permission missing
  - Mesh initializing
  - Mesh unavailable / failed
  - Mesh ready

- Add compact app-bar status icon/chip for non-error states if helpful

#### CTA behavior

- Bluetooth off:
  - Open Settings
  - Retry
- Permission missing:
  - Grant permission
  - Open Settings
- Mesh initializing:
  - no blocking overlay
  - optional spinner and message
- Mesh failed:
  - Retry mesh startup

#### Acceptance

- Home remains visible while BLE is off
- User understands what is wrong and what action is needed
- Status copy is specific, not generic “Allow Permission!”

### Phase 4: Re-scope `PermissionScreen`

#### Objective

Give `PermissionScreen` one clear job instead of four.

#### Recommended role

Keep it only for:
- first-run setup, if desired
- post-panic-wipe reset
- explicit user-invoked setup flow

#### Remove from runtime use

It should no longer be shown automatically because:
- Bluetooth turned off
- permissions changed
- BLE is still initializing

#### Import/start-new implications

If `PermissionScreen` stops being the main entry:
- add visible first-run import CTA on Home empty state
- keep existing Settings import path
- optionally keep a “Set up mesh” action in Home or overflow menu

#### Acceptance

- `PermissionScreen` is no longer the catch-all fallback for runtime BLE issues
- backup import is still easy to discover before first chat

### Phase 5: Degrade actions, not the whole app

#### Objective

Only BLE-dependent actions should sleep when BLE is unavailable.

#### Changes

- Discovery FAB behavior:
  - if BLE ready: open discovery overlay
  - if BLE unavailable: show status sheet/banner explanation instead of broken scanning flow

- Discovery overlay should not appear if prerequisites are missing

- BLE-related actions should be disabled or rerouted gracefully:
  - scan
  - connect
  - broadcast/advertise start

- Non-BLE features remain usable:
  - browsing chats
  - settings
  - archives
  - profile
  - reading local history

#### Acceptance

- User never lands in a dead-end flow for a BLE-only action
- Non-BLE app areas remain usable during BLE degradation

## Edge Cases That Must Be Covered

### App startup

- Bluetooth off at launch
- Bluetooth on, permissions missing
- Bluetooth on, BLE subsystem slow to initialize
- BLE subsystem throws during startup
- transient plugin states like `poweredOff + unsupported`

### Runtime transitions

- Bluetooth toggled off while on Home
- Bluetooth toggled off while in Chat
- Bluetooth toggled off while in Settings
- Bluetooth toggled back on while staying on current screen
- permissions revoked while app is backgrounded
- permissions granted from system settings and app resumed

### Partial permission states

- Scan granted, advertise denied
- connect denied, scan granted
- Android 12+ Nearby Devices variants granted unevenly

The UI should identify the missing capability precisely, not just say “Bluetooth missing.”

### First-run and restore

- fresh install with no Bluetooth
- fresh install with backup to import
- post-panic-wipe entry
- import completed successfully but mesh still unavailable

### Unsupported or permanently unavailable BLE

- device truly unsupported
- plugin continues to report unusable responder-side state

App should present a stable unsupported state, not oscillate between unsupported/initializing/off.

### Navigation stability

- no route-loop between Home and PermissionScreen
- no “Grant permission” screen immediately replaced by Home without user context
- no full-screen loading state after app is already in use

## Proposed Phasing

### Checkpoint 1

Decouple `AppStatus.ready` from BLE integration.

Expected user-visible result:
- the long startup “initializing...” block disappears or shrinks substantially

### Checkpoint 2

Remove root BLE gating in [main.dart](../../lib/main.dart) and make Home the runtime default after bootstrap.

Expected user-visible result:
- no more bounce back into onboarding when Bluetooth changes

### Checkpoint 3

Replace the current crude Home BLE banner with proper runtime BLE status UI and actions.

Expected user-visible result:
- users can understand and recover from BLE problems without leaving Home

### Checkpoint 4

Re-scope or retire `PermissionScreen` for runtime BLE issues, and add first-run import/setup affordance where needed.

Expected user-visible result:
- setup is still discoverable
- runtime BLE loss no longer feels like the app “restarted into onboarding”

### Checkpoint 5

Polish action-level degradation:
- discovery FAB
- retry mesh startup
- contextual CTAs
- copy/wording cleanup

Expected user-visible result:
- Bluetooth feels like a subsystem that can sleep/wake, not like the app is broken

## Testing Plan

### Widget/provider tests

- root app shows Home after core-ready even if BLE is off
- `PermissionScreen` is not used as runtime fallback
- Home banner renders correct state for:
  - off
  - unauthorized
  - initializing
  - unsupported
  - ready
- BLE action buttons call the correct recovery paths

### Integration/regression tests

- toggling Bluetooth off does not navigate away from Home
- turning Bluetooth back on updates the in-app status surface
- granting permission from settings updates the UI without route flicker
- notification permission flow remains settings-scoped

### Device validation

- launch with Bluetooth off
- turn Bluetooth on during runtime
- revoke/restore Nearby Devices permission
- verify no onboarding bounce
- verify no false unsupported classification

## Recommended Final UX State

### Startup

1. App splash/loading
2. Core/bootstrap finishes quickly
3. App opens to Home
4. BLE initializes in background
5. If BLE unavailable, Home shows a visible but non-blocking status

### Runtime

- Bluetooth off:
  - Home stays visible
  - warning banner/chip appears
  - discovery/connect actions degrade gracefully

- Bluetooth on again:
  - status updates in place
  - no root navigation jump

- permissions missing:
  - inline CTA to grant/open settings
  - no forced onboarding bounce

## Recommendation

Implement this as a UX architecture pass, not as isolated bug fixes.

The correct long-term move is:

1. treat BLE readiness as runtime state
2. keep Home available after bootstrap
3. reserve full-screen setup flows for explicit setup/reset moments only

That approach matches professional app behavior and aligns with how PakConnect is actually used: local app shell first, mesh subsystem second.
