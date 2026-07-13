# BLE Mesh Engine Decision Note

**Date:** 2026-03-24  
**Status:** Historical architecture assessment based on PakConnect plus local
reference checkouts. Since this note, the strict-TDM scheduler was implemented
and hardened with attempt generations, exact milestone ownership and focused
tests. It remains behind `PAKCONNECT_STRICT_TDM` and still needs the comparative
Android device runbook; current truth is in `PLANS.md`,
`docs/architecture/RUNTIME_FLOWS.md` and the device ledger.

## Why This Exists

PakConnect keeps hitting BLE flakiness that feels bigger than "just tune the timing."

This note answers a narrower question:

1. What is actually true in the current codebase?
2. Which parts of the recent Gemini guidance are right, wrong, or overstated?
3. What should happen next if the goal is a stable BLE mesh architecture?

## Short Answer

You are not imagining the problem.

PakConnect currently runs on top of a BLE plugin model that exposes **separate central and peripheral managers**, while PakConnect itself assumes they can operate in a stable **concurrent dual-role** arrangement. The app already contains a lot of compensating logic for scan bursts, collision handling, duplicate links, and connection tie-breaks. That is strong evidence that the architecture is fighting the radio boundary instead of owning it.

The Gemini advice is **directionally correct**, but too absolute in a few places.

My recommendation:

1. **Short-term proof step:** implement a real Time Division Multiplexing (TDM) scheduler on top of the current plugin, but do it as a true radio-role scheduler, not just burst scanning.
2. **Long-term production path:** move BLE connection orchestration into native Kotlin/Swift and keep Flutter for UI, storage, crypto policy, and higher-level routing.

## What I Verified In PakConnect

### 1. PakConnect currently assumes concurrent dual-role BLE

The code explicitly treats scan and advertise as something that should coexist:

- [ble_advertising_service.dart](../../lib/data/services/ble_advertising_service.dart) logs `"Starting peripheral advertising (dual-role mode)"`
- [ble_advertising_service.dart](../../lib/data/services/ble_advertising_service.dart) says `"NO mode switching"`
- [ble_advertising_service.dart](../../lib/data/services/ble_advertising_service.dart) says central and peripheral `"coexist"`
- [burst_scanning_controller.dart](../../lib/domain/services/burst_scanning_controller.dart) says the peripheral mode check was removed because scanning and advertising coexist

That means the current design is **not** using time-sliced role separation. It is trying to sustain simultaneous scan + advertise behavior.

### 2. PakConnect instantiates separate central and peripheral plugin managers

The production host directly exposes both plugin roles:

- [ble_platform_host.dart](../../lib/domain/services/ble_platform_host.dart) lazily creates `CentralManager()`
- [ble_platform_host.dart](../../lib/domain/services/ble_platform_host.dart) lazily creates `PeripheralManager()`

The connection manager also owns both roles independently:

- [ble_connection_manager.dart](../../lib/data/services/ble_connection_manager.dart) `final CentralManager centralManager;`
- [ble_connection_manager.dart](../../lib/data/services/ble_connection_manager.dart) `final PeripheralManager peripheralManager;`

This matters because the app is currently coordinating two role-specific control surfaces, not one unified mesh engine.

### 3. PakConnect already contains architecture-level "damage control"

The repo is full of logic that exists specifically to manage scan/connect/race instability after the fact:

- [ble_connection_manager_runtime_collision_policy.dart](../../lib/data/services/ble_connection_manager_runtime_collision_policy.dart) waits on inbound viability before deciding whether to yield
- [ble_connection_manager_runtime_collision_policy.dart](../../lib/data/services/ble_connection_manager_runtime_collision_policy.dart) logs a collision tie-breaker that yields to inbound
- [ble_connection_manager_runtime_collision_policy.dart](../../lib/data/services/ble_connection_manager_runtime_collision_policy.dart) compares local and remote collision tokens
- [ble_connection_manager.dart](../../lib/data/services/ble_connection_manager.dart) tracks collision resolutions in flight

This is not bad engineering. It is useful evidence. It shows the codebase has already been forced to build its own tie-break layer because the BLE role boundary is not naturally stable.

### 4. Burst scanning is not the same thing as radio scheduling

PakConnect already has [BurstScanningController](../../lib/domain/services/burst_scanning_controller.dart), but it only governs **scan bursts**. It does not act as a single owner of:

- scan windows
- advertise windows
- connection-lock windows
- handshake lock / pause / resume behavior
- fairness between outbound and inbound role opportunities

So if you decide to try TDM, understand this clearly:

**you do not already have TDM**  
you have burst scanning inside a concurrent dual-role design.

## What I Verified In `bluetooth_low_energy`

### 1. The plugin is structurally split into separate central and peripheral paths

On Android, the plugin initializes separate native managers:

- Historical external checkout `BluetoothLowEnergyAndroidPlugin.kt` creates
  `CentralManagerImpl` and `PeripheralManagerImpl`, then wires both generated
  host APIs.

On the Dart side, the plugin mirrors that split:

- Historical external `central_manager_impl.dart` and
  `peripheral_manager_impl.dart` define the two Dart-side roles.

That validates the core concern: this plugin gives you **two role controllers**, not a unified mesh coordinator.

### 2. "MethodChannel" is not the exact point, but the bridge issue is still real

Gemini described this as a `MethodChannel` latency problem. That wording is not exact for this plugin. The plugin uses generated host APIs and Flutter/native bridging rather than one handwritten `MethodChannel`.

But the deeper point still stands:

- the app talks across a Flutter/native boundary
- central and peripheral are exposed separately
- the plugin does not appear to provide a single higher-level scheduler that arbitrates the whole radio lifecycle for a mesh

So the exact sentence "MethodChannel causes everything" is too blunt, but the conclusion "you are paying for split Flutter/native BLE orchestration in a timing-sensitive problem" is fair.

## What I Verified In `bitchat-android`

The local Bitchat source strongly supports the idea that its BLE stack is built around a native mesh coordinator.

- In the historical external Bitchat checkout, `BluetoothMeshService.kt`
  describes a coordinator over dedicated components and names
  `BluetoothConnectionManager`; that manager creates both GATT server and GATT
  client managers.

That is a very different architecture from "Flutter app owns two plugin managers and keeps them coordinated from Dart."

Important nuance:

I did **not** verify from the inspected source that Bitchat specifically solves this through strict TDM. What I did verify is that it has a **native unified coordination layer** for BLE client/server behavior.

## What I Verified In `bridgefy_flutter`

The local Bridgefy Flutter repo finished downloading, and it supports a more precise conclusion:

- In the historical external Bridgefy checkout,
  `bridgefy_method_channel.dart` creates `MethodChannel('bridgefy')`, the
  Android plugin implements `FlutterPlugin, MethodCallHandler`, and its Android
  and iOS manifests depend on the native Bridgefy SDKs.

That means the Flutter package is a **thin wrapper** over Bridgefy's native SDKs. It is useful as evidence for architecture shape, but it does **not** give you a transparent open-source mesh engine to study end to end from Flutter code alone. The real radio/mesh behavior lives underneath the wrapper.

This actually strengthens the decision note:

- Bridgefy is not proof that "Flutter-side BLE orchestration is enough"
- Bridgefy is closer to proof that serious mesh vendors hide the timing-sensitive BLE engine in native SDK layers

## What I Could Not Fully Verify

### Briar

Briar was mentioned in the Gemini summary, but there is no Briar source in the local reference set. I am not treating Briar as a verified local comparison.

## Verdict On Gemini's Claims

### Correct or mostly correct

1. **The plugin exposes separate central and peripheral roles**
   - Verified.

2. **PakConnect currently coordinates them largely at the app level**
   - Verified.

3. **A stable mesh wants a single "traffic cop" over radio behavior**
   - Strongly supported by current PakConnect pain and by the Bitchat comparison.

4. **A native mesh coordinator is the stronger long-term architecture**
   - I agree.

### Overstated or too absolute

1. **"Flutter can never do this well"**
   - Too strong.
   - Flutter can still be the app layer just fine.
   - The problem is where the BLE state machine lives, not Flutter UI itself.

2. **"The only real path is native platform channels"**
   - Too strong.
   - A real TDM scheduler on top of the current plugin is a valid intermediate architecture and a useful proof step.

3. **"This is purely a MethodChannel problem"**
   - Too simplistic.
   - The real issue is a combination of:
     - split role control surfaces
     - asynchronous Flutter/native boundaries
     - timing-sensitive BLE state transitions
     - PakConnect still assuming dual-role coexistence as the default happy path

## My Read Of What Is Actually Happening

PakConnect is currently in an awkward middle state:

- sophisticated enough to support multi-hop, handshake coordination, fragmentation, and security
- but still resting on a BLE role-control layer that is too fragmented for reliable mesh behavior

That is why the app keeps accumulating:

- burst scanning
- collision resolution
- connection tracking
- deferred teardown
- inbound/outbound tie-breakers

Those are all real improvements, but they are being layered **after** the fundamental central/peripheral split instead of replacing it with a single radio policy owner.

## What TDM Would Need To Mean Here

If you choose TDM, do not interpret that as "tune BurstScanningController a bit."

Real TDM for PakConnect would require one scheduler to own:

1. **Scan window**
   - enable central discovery only
2. **Advertise window**
   - enable peripheral advertising only
3. **Connection lock**
   - freeze role switching while connect + MTU + Noise handshake are in flight
4. **Connected background state**
   - keep established links alive while the scheduler decides when to reopen discovery or advertising
5. **Yield rules**
   - decide what happens if inbound and outbound opportunities appear near the same time

If you do not centralize all of that into one scheduler, you do not really have TDM. You just have more timing heuristics.

## Decision Matrix

### Option A: Keep plugin, add real TDM

**Best for:** fastest experiment with smallest code surface change

Pros:

- keeps Flutter app intact
- keeps current plugin for now
- gives a fast answer to "is concurrency the main cause of flakiness?"
- lower implementation cost than a native rewrite

Cons:

- slower peer discovery
- slower mesh formation
- still depends on plugin semantics
- still leaves timing-sensitive control above the platform layer
- may improve stability without reaching "production-grade" reliability

My take:

This is the best **diagnostic and stabilization spike**.

### Option B: Native Android mesh engine first, Flutter stays above it

**Best for:** serious reliability work without rewriting the whole app

Pros:

- native code owns radio state, connection races, and role arbitration
- Flutter stays for UI, persistence, crypto policy, routing, and app logic
- lets you keep most of the project while replacing the weakest foundation
- matches the architecture pattern seen in Bitchat more closely

Cons:

- higher implementation complexity
- you will need a real native contract for events, bytes, state, and metrics
- iOS will still lag behind unless you repeat the work in Swift

My take:

This is the most credible long-term direction if your goal is a robust mesh core.

### Option C: Full Android + iOS native mesh core

**Best for:** eventual mature product architecture

Pros:

- strongest control over BLE lifecycle on both platforms
- least architectural mismatch

Cons:

- largest effort
- highest integration burden
- easiest way to get lost if done too early

My take:

Do not start here first.

## Recommended Path

If this were my repo, I would do the following:

### Phase 1: Prove the architecture hypothesis quickly

Implement a **strict TDM spike on Android only**:

- one scheduler
- explicit scan window
- explicit advertise window
- explicit connection/handshake lock
- no assumption that advertising and scanning should coexist

Success metrics:

- connection success rate
- handshake success rate
- connection drop rate during discovery
- time-to-first-peer
- time-to-second-peer

If stability improves sharply, you have proven that role concurrency is a major root cause.

### Phase 2: Decide whether TDM is "good enough"

If TDM gives you acceptable demo reliability and acceptable discovery latency, you may keep it for now.

If TDM stabilizes things but feels too slow or too brittle, that is your signal to stop polishing the plugin path and move to a native engine.

### Phase 3: Move BLE orchestration native

Build a native BLE engine that owns:

- scan / advertise lifecycle
- connection tie-breaks
- handshake lock windows
- per-peer link state
- MTU and notification plumbing
- event emission upward to Flutter

Then Flutter consumes:

- peer discovered
- link established
- link lost
- mtu updated
- bytes received
- bytes send result

That keeps your existing Flutter investment while removing the weakest boundary.

## What I Do Not Recommend

1. **Do not keep piling more collision heuristics onto the current concurrent dual-role assumption**
   - the repo already has a lot of that
   - it is unlikely to convert the architecture into something fundamentally stable

2. **Do not delete Flutter and rewrite the whole app natively**
   - your UI, storage, crypto policy, and routing logic are still valuable

3. **Do not treat the plugin as if it is already a mesh engine**
   - it gives you BLE role APIs
   - that is not the same thing as a radio scheduler

## Small Correction On The Anti-Spam / Token-Bucket Story

Your anti-spam layer is real, but the "algorithmic token bucket with gas pricing" description is more aspirational than literal based on current code.

What I verified in [spam_prevention_manager.dart](../../lib/domain/services/spam_prevention_manager.dart):

- rate limiting
- trust scoring
- message size and hop validation
- duplicate detection
- proof-of-work / cost-policy hooks

So the brag is not fake. It is just not literally a simple token bucket implementation today.

## Final Recommendation

If your goal is "stop smashing into walls and get a result," the clean answer is:

1. **Stop treating concurrent dual-role via the current plugin as the long-term architecture**
2. **Run a real TDM spike first**
3. **Use that result to decide how fast to move to a native BLE engine**

In plain English:

- You are probably fighting a real architecture boundary, not just bad luck.
- Gemini is broadly right about the direction.
- The immediate next move is not "rewrite everything."
- The immediate next move is "prove the radio scheduler hypothesis cleanly."

## Suggested Follow-Up Checkpoints

1. Write an explicit `BleRoleScheduler` design note
2. Implement Android-only strict TDM behind a development flag
3. Add metrics for scan success, connect success, handshake success, and median discovery latency
4. Run two-device and three-device measurements
5. If TDM still feels too constrained, begin a native Android BLE engine extraction plan
