# Next Build Roadmap

**Date:** 2026-03-25  
**Status:** Historical roadmap. Its TDM spike and local panic-wipe work have
since moved into the live code/readiness program; use `PLANS.md` and
`docs/status/READINESS_AUDIT.md` for current sequencing.

## Goal

Pick the next work that gives the highest chance of real progress without getting lost in side quests.

This roadmap assumes:

- you are a solo developer
- you do not have production users to preserve
- the main current risk is BLE mesh instability
- full in-band/out-of-band duress is explicitly **not** ready yet

## Priority Order

1. **Get a second architecture opinion while context is fresh**
2. **Build a local-only panic wipe MVP in parallel**
3. **Implement a real Android-only TDM spike**
4. **Make a hard architecture decision from evidence**
5. **If needed, begin native BLE engine extraction**

## Why This Order

The BLE foundation is still the biggest uncertainty. That means anything that depends on reliable messaging behavior, stealth semantics, or remote safety signaling should wait.

A local panic wipe is different:

- it is mostly device-local
- it does not require stable mesh transport
- it builds on security primitives you already have
- it gives you a meaningful security feature without dragging you into the full duress problem

## Track A: External Architecture Review

### Objective

Use the external model as a second opinion, not as a replacement for local verification.

### Input Package

Send:

- the project zip
- [ble_mesh_engine_decision.md](ble_mesh_engine_decision.md)
- the architecture-review prompt

### Expected Output

The external review should answer:

- Is strict TDM a serious stabilizing path or only a temporary bandage?
- Is native Android BLE orchestration the likely long-term answer?
- What exactly should remain in Flutter if native BLE extraction happens?

### Decision Rule

Do not change direction based on vague wording.

Only treat the review as useful if it:

- cites code
- distinguishes verified facts from inference
- gives a concrete recommendation

## Track B: Panic Wipe MVP

### Objective

Build a **local-only panic wipe** feature that destroys sensitive local state. Do not treat this as "the duress protocol." It is only the safest first slice.

### Scope Included

- manual user-triggered panic action
- destroy active Noise sessions
- clear persistent identity keys from secure storage
- clear encrypted database contents
- clear sensitive app preferences and cached state
- restart app into clean onboarding state

### Scope Explicitly Excluded

- covert in-band keyword trigger
- decoy PIN routing
- fake-normal UI during duress
- selective contact-only remote severing
- compromise beacon / taint advertisement
- any automatic trigger based on network events

### Why This Slice Is Worth Doing

It gives you a real security feature without depending on mesh stability.

### Candidate Files

- `lib/core/security/noise/noise_encryption_service.dart`
- `lib/core/security/noise/noise_session.dart`
- `lib/core/app_core.dart`
- `lib/data/database/database_helper.dart`
- `lib/presentation/controllers/settings_controller.dart`
- `lib/presentation/screens/settings_screen.dart`

### Acceptance Criteria

- Panic action can be triggered intentionally by the user
- Sessions are destroyed
- Static identity keys are removed
- Database is cleared
- App relaunches or resets into a fresh-state flow
- Tests prove data is gone after the wipe path

### Risk Rules

- Put the action behind a deliberate confirmation flow
- Do not hide it behind "clever" gestures
- Do not make it easy to trigger accidentally
- Do not add remote signaling in the same pass

## Track C: Android TDM Spike

### Objective

Prove whether role concurrency is the main cause of BLE instability.

### Real TDM Means

One scheduler owns:

- scan window
- advertise window
- connection lock
- handshake lock
- resume logic

This is not just "burst scanning with different timers."

### Scope

- Android only
- development flag or experimental mode
- keep current plugin for the spike
- suspend the assumption that scanning and advertising should coexist

### Metrics To Capture

- discovery success rate
- connection success rate
- Noise handshake success rate
- disconnect/drop rate
- time to first peer
- time to second peer

### Acceptance Criteria

- meaningful improvement in connection stability
- reproducible improvement across at least two-device testing
- enough telemetry to compare against the current concurrent model

## Decision Gate

After the panic wipe MVP and TDM spike, make one explicit decision:

### If TDM is good enough

Keep TDM as the working BLE architecture for now and stop trying to revive concurrent dual-role behavior.

### If TDM stabilizes but is too slow or too constrained

Begin native Android BLE engine extraction.

### If TDM barely helps

Stop spending effort on plugin-level orchestration and move directly to native BLE coordination.

## Track D: Native BLE Engine Boundary Plan

### Objective

Replace the weakest architectural layer without rewriting the app.

### What Should Move Native

- scan / advertise orchestration
- connection tie-breaks
- GATT server/client lifecycle
- MTU handling
- notification/write plumbing
- connection-state event emission

### What Should Stay In Flutter

- UI
- persistence
- higher-level routing logic
- crypto policy decisions
- queueing and relay policy
- app settings and diagnostics

### Acceptance Criteria

- Flutter no longer owns radio timing decisions
- Flutter consumes events from a cleaner native BLE boundary
- dual-role behavior is managed in one place

## What Should Explicitly Wait

Do not start these yet:

- full in-band duress
- covert keyword triggers
- compromise beacon / taint advertisements
- fake-normal duress UI
- selective remote wipe flows
- broad spam-throttling redesign

These should wait until the BLE foundation is stable enough that the security behavior is predictable.

## Recommended Immediate Execution Sequence

### Step 1

Send the architecture-review prompt plus project zip to the external model.

### Step 2

While it runs, start the **panic wipe MVP design**.

Do not implement the whole thing blindly first. Define:

- exactly what gets wiped
- what survives
- what the reset UX looks like
- how to test it

### Step 3

After the external review comes back, compare it with
[ble_mesh_engine_decision.md](ble_mesh_engine_decision.md).

If the external review does not materially change the recommendation, start the **Android TDM spike** next.

## Blunt Recommendation

If you only ask "what should I do next?" the answer is:

1. **Plan and implement local panic wipe MVP**
2. **Then do the Android TDM spike**
3. **Then decide whether native BLE extraction is required**

That gives you:

- one meaningful security feature
- one architecture proof step
- one clean decision point

without getting trapped in premature full-duress complexity.
