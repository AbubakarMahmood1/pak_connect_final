# Pak Connect BLE/GATT + TDM + Gossip Debug Review Log

Generated from static review of `pak_connect_final.zip`.

## Scope and constraints

I focused on the failure modes you described:

- two-device bidirectional chat failing in dual/auto mode while manual central/peripheral worked;
- notification subscription not reliably happening;
- both devices believing they are connected through central/peripheral paths but neither path working;
- BLE overlay/device list piling up or not reflecting live state;
- packet loss/corruption-like behavior after encryption/decryption had worked;
- gossip/queue-sync requests failing to be processed;
- whether strict BLE time multiplexing can work without going native.

I could not run Flutter/Dart analyzer or tests in this container because there is no `pubspec.yaml` in the uploaded archive root and `dart`/`flutter` are not installed here. The findings below are static code review findings with file/line evidence.

---

## Executive triage

You are not crazy. There are several real code-level reasons the system would feel random even if the radio itself is okay.

The highest-confidence blockers are:

1. **Global connection state rejects extra peers** after one link reaches `ready`, so 3-device mesh/gossip is structurally blocked in several paths.
2. **Notification subscription is treated as successful without proof**, and the TDM scheduler ignores MTU/notify readiness entirely.
3. **Inbound/server-only links are counted as connected**, but ordinary text send still requires the first client-side message characteristic.
4. **The overlay marks inbound-won collision links as failed**, which explains UI mismatch and “device list keeps piling.”
5. **Binary-fragmented queue-sync can be reassembled and then dropped**, because the split facade routes queue-sync through `ProtocolMessageHandler`, but the callback is registered only on `RelayCoordinator`.
6. **Queue sync sends are not peer-targeted**, so in 3-device mode sync can go over the current/global link instead of the peer that requested it.
7. **Change-log sync send is a logged no-op**, and the BLE facade’s `startGossipSync()` is also only a placeholder hook.
8. **Legacy fragment IDs are truncated to 6 chars**, which can create reassembly collisions that look like packet corruption.

---

## Priority issue log

### PC-BLE-001 — Global `ready` state blocks additional peers

**Severity:** Critical for 3-device mesh/gossip; high for dual-role auto glare.

**Evidence**

- `lib/data/services/ble_connection_manager_runtime_server_links.dart:205-240`
  - `_runtimeHandleCentralConnected()` rejects inbound if `connectionState == ChatConnectionState.ready`, regardless of whether the inbound central is a new peer.
- `lib/data/services/ble_connection_manager_runtime_server_links.dart:327-373`
  - `_runtimeHandleCharacteristicSubscribed()` drops inbound notify when global state is ready.
- `lib/data/services/ble_facade_lifecycle_coordinator.dart:266-276`
  - responder fallback handshake is skipped when global connection state is ready.
- `lib/data/services/ble_connection_service.dart:477-485`
  - auto-connect is suppressed whenever the connection manager is not globally disconnected.

**Why it matches your symptoms**

One device/usecase can go green. Two devices may go green if they settle into one role. Three-device mesh cannot reliably form because the second additional peer gets rejected or auto-connect is suppressed simply because some other link is ready.

**Fix direction**

Replace global `connectionState == ready` as a peer admission guard with per-peer state. The check should be closer to:

```dart
final peerKey = resolvePeerKey(address, peerHint);
final state = peerStates[peerKey];
if (state?.isReadyOrConnecting == true) rejectDuplicateForThatPeerOnly();
else acceptNewPeer();
```

Keep global state only for UI summary or legacy one-chat mode. Do not use it to reject all inbound/outbound links.

**Immediate test**

Run A-B until ready, then start C. On A, log every inbound reject with `address`, `peerHint`, `current ready peers`, and `global connectionState`. If A rejects C with reason `Already READY`, this issue is confirmed.

---

### PC-GATT-001 — Notification subscription is assumed, not proven

**Severity:** Critical for bidirectional chat and responder handshake.

**Evidence**

- `lib/data/services/ble_connection_gatt_controller.dart:136-157`
  - `enableNotifications()` returns silently when the characteristic lacks `notify`.
  - It calls `setCharacteristicNotifyState(..., state: true)` and immediately logs success after a delay. There is no proof that the peripheral/server side observed subscription.
- `lib/data/services/ble_connection_manager_runtime_client_links.dart:216-245`
  - notification setup only runs if the characteristic advertises notify; otherwise connection continues.
- `lib/data/services/ble_messaging_transport_helper.dart:289-318` does wait for server-side notify readiness before responder send, but only on the peripheral-side helper path. Central subscribe still lacks a real barrier.

**Why it matches your symptoms**

The code can mark a connection as usable while CCCD/notify state is not actually ready. The responder handshake notification or queue-sync notification can vanish, making both sides believe they connected but no data moves.

**Fix direction**

Make notification readiness a hard state transition:

```dart
if (!messageChar.properties.contains(GATTCharacteristicProperty.notify)) {
  throw StateError('Message characteristic is not notifiable');
}

await centralManager.setCharacteristicNotifyState(device, messageChar, state: true);
await notifySubscribeBarrier.waitFor(device.uuid, messageChar.uuid, timeout: 1500.ms);
```

If the library cannot expose a direct subscribe ack on the central side, implement an app-level notify probe: after subscribe, peripheral sends `NOTIFY_READY_PROBE`, central ACKs with write. Do not start responder handshake or queue sync until this succeeds.

**Immediate test**

Add one log event on both sides:

```text
GATT_NOTIFY_SUBSCRIBE_REQUEST peer=... char=...
GATT_NOTIFY_SUBSCRIBE_CONFIRMED peer=... char=...
GATT_NOTIFY_FIRST_PAYLOAD_RX peer=... len=...
```

A connection should not enter ready before confirmed + first valid app payload or handshake payload.

---

### PC-TDM-001 — Strict time multiplexing ignores MTU/notify milestones

**Severity:** Critical if `PAKCONNECT_STRICT_TDM=true`; high if you are using this to avoid native BLE.

**Evidence**

- `lib/data/services/ble_role_scheduler.dart:104-108`
  - `reportMtuReady()` and `reportNotifySubscribed()` are empty.
- `lib/data/services/ble_role_scheduler.dart:191-207`
  - connect lock stops scan/advertise, then uses only a timeout/cooldown path.
- `lib/data/services/ble_role_scheduler.dart:116-125`
  - connected maintain only transitions on handshake ready, not notify/MTU readiness.

**Why it matches your symptoms**

The scheduler currently multiplexes scan/advertise/connect windows, but it does not protect the fragile part you actually care about: connect -> discover services -> MTU -> enable notify -> responder handshake -> queue sync. It can release or churn while subscription/handshake is not actually usable.

**Fix direction**

Add per-peer milestones:

```dart
class LinkBringupState {
  bool connected;
  bool mtuReady;
  bool notifySubscribed;
  bool handshakeStarted;
  bool handshakeReady;
}
```

Hold connect lock until either:

- `notifySubscribed && mtuReady && handshakeReady`, or
- explicit failure/timeout.

The no-op methods should update the active peer state and extend/complete the connect lock.

**Immediate test**

With strict TDM on, log scheduler state transitions with `peer`, `reason`, `mtuReady`, `notifyReady`, `handshakeState`. If the scheduler exits connect lock before notify+handshake, this issue is confirmed.

---

### PC-BLE-002 — Server-only/inbound-won links count as connected, but normal send requires client characteristic

**Severity:** High for dual auto mode and glare/collision resolution.

**Evidence**

- `lib/data/services/ble_connection_manager.dart:79-81`
  - legacy `messageCharacteristic` returns the first client connection only.
- `lib/data/services/ble_connection_manager.dart:188-191`
  - `hasBleConnection` is true if either client or server connections exist.
- `lib/data/services/ble_messaging_service.dart:187-195`
  - normal `sendMessage()` throws unless `hasBleConnection` and `messageCharacteristic != null`.
- `lib/data/services/ble_messaging_service.dart:301-326`
  - queue sync has a central or peripheral path, but still depends on global mode/state rather than a target peer.

**Why it matches your symptoms**

An inbound/server link can make the system say “connected,” but ordinary text send still sees no client message characteristic. That is exactly the kind of state where UI says connected and no data moves.

**Fix direction**

Stop using `hasBleConnection` as a send readiness check. Expose role-specific readiness:

```dart
bool canWriteToPeer(peerId);        // central/client write path
bool canNotifyPeer(peerId);         // peripheral/server notify path
bool canSendToPeer(peerId) => canWriteToPeer(peerId) || canNotifyPeer(peerId);
```

All send paths should pick a peer-specific transport path, not a global first connection.

---

### PC-UI-001 — Overlay marks inbound-won links as failed

**Severity:** High for debugging sanity; medium for transport.

**Evidence**

- `lib/presentation/widgets/discovery_overlay.dart:139-161`
  - after connect it waits two seconds, then declares success only if `connectionService.connectedDevice?.uuid == device.uuid`.
  - if collision resolution chooses inbound/server link, `connectedDevice` can be null/different, so UI marks failed and retires the device.
- `lib/presentation/widgets/discovery_overlay.dart:300-322`
  - it computes inbound/outbound connected IDs, then intentionally sets `activeConnectedIds = <String>{};`, so connected peers are not hidden or filtered.

**Why it matches your symptoms**

Manual role mode can look correct. In dual auto mode, if inbound wins, UI reports failure even though a server link exists. Also the device list can continue showing connected devices, which looks like piling or stale discovery.

**Fix direction**

Success criteria should include inbound/server link and hint-equivalent identity:

```dart
final ok = connectionService.connectedDevice?.uuid == device.uuid ||
           connectionManager.hasServerLinkForPeer(device.uuid.toString()) ||
           connectionManager.hasAnyLinkForPeerHint(device.ephemeralHint);
```

Also either hide connected peers using `allConnectedIds`, or label them as connected instead of leaving them in the discovery pool as if they are candidates.

---

### PC-DISC-001 — No-hint devices do not merge, self-filter may miss, and stale cleanup is fixed at 2 minutes

**Severity:** Medium/high for overlay piling and Android rotating addresses.

**Evidence**

- `lib/domain/services/device_deduplication_manager.dart:80-96`
  - self-filter only works if a parsed hint exists.
- `lib/domain/services/device_deduplication_manager.dart:586-591`
  - `_findMergeTarget()` returns null for `NO_HINT`, so no-hint address rotations do not merge.
- `lib/domain/services/device_deduplication_manager.dart:635-641`
  - stale cleanup uses a hard-coded 2-minute cutoff.
- `lib/data/services/ble_discovery_service.dart:285-289`
  - `scanForSpecificDevice()` is still TODO and always returns null.
- `lib/data/services/ble_discovery_service.dart:383-387`
  - `buildLocalCollisionHint()` is still TODO and returns null.

**Why it matches your symptoms**

Any scan result without a stable hint can create a new visible row. With rotating BLE addresses, this becomes list pile-up. If a current connection lacks a hint, it can also appear as a new connectable device.

**Fix direction**

Do not add no-hint/anonymous devices to the user-visible dedup list unless they survive a short confirmation window. Merge using safe secondary keys where possible: advertised local name prefix, manufacturer payload, service UUID, and recent proximity/time bucket.

---

### PC-QSYNC-001 — Binary-fragmented queue-sync can be reassembled and then dropped

**Severity:** Critical for your “gossip sync request failed to process” symptom.

**Evidence**

- `lib/data/services/ble_messaging_transport_helper.dart:476-490`
  - larger protocol messages use `BinaryFragmenter.fragment(... originalType: BinaryPayloadType.protocolMessage)`.
- `lib/data/services/message_fragmentation_handler.dart:125-147`
  - binary fragment envelopes are reassembled by the split facade.
- `lib/data/services/message_fragmentation_handler.dart:670-688`
  - completed binary protocol payload returns marker `REASSEMBLY_COMPLETE_BIN:<id>:<type>`.
- `lib/data/services/ble_message_handler_facade.dart:487-510`
  - split facade parses binary protocol payload and calls `_protocolHandler.processProtocolMessage()`.
- `lib/data/services/protocol_message_handler.dart:76-78`
  - queue-sync callback exists internally as `_onQueueSyncReceived`.
- `lib/data/services/protocol_message_handler.dart:198-199` and `352-365`
  - queue-sync dispatch calls `_onQueueSyncReceived?.call(...)` and ACKs.
- `lib/data/services/ble_message_handler_facade.dart:778-785`
  - the facade setter registers queue-sync callback only on `_relayCoordinator`, not `_protocolHandler`.
- `lib/data/services/ble_message_handler_facade_impl.dart:273-319`
  - wrapper first lets split facade process data; if split facade returns null, it falls back to legacy handler using the raw data, which for a completed binary fragment is only the last raw fragment, not the reassembled protocol message.
- `lib/data/services/ble_message_handler_facade_impl.dart:440-445`
  - wrapper sets both legacy handler and split facade callbacks, but split facade callback still misses `ProtocolMessageHandler`.

**Why it matches your symptoms**

Small queue-sync packets may work through the legacy/direct protocol path. Large or binary-fragmented queue-sync can be successfully reassembled, parsed, ACKed, and then do nothing because the actual queue-sync callback was never wired into the `ProtocolMessageHandler` path.

This is the single most suspicious bug for “sync requests gets failed to be processed,” especially if failures start when payloads are larger or fragmented.

**Fix direction**

Add a callback setter on `ProtocolMessageHandler` and wire it from `BLEMessageHandlerFacade`:

```dart
// protocol_message_handler.dart
void setQueueSyncReceivedHandler(
  Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
) {
  _onQueueSyncReceived = callback;
}
```

```dart
// ble_message_handler_facade.dart
set onQueueSyncReceived(
  Function(QueueSyncMessage syncMessage, String fromNodeId)? callback,
) {
  _ensureInitialized();
  _protocolHandler.setQueueSyncReceivedHandler(callback);
  if (callback != null) {
    _relayCoordinator.onQueueSyncReceived(callback);
  }
}
```

Also return a non-null handled marker from split facade after queue-sync handling, for example `QUEUE_SYNC_HANDLED`, so fallback behavior is not ambiguous.

**Immediate test**

Force a queue-sync payload large enough to go through binary fragmentation. Confirm logs show this sequence:

```text
BINARY_REASSEMBLY_COMPLETE originalType=protocolMessage
PROTOCOL_PARSED type=queueSync
QUEUE_SYNC_CALLBACK_INVOKED fromNodeId=...
MESH_QUEUE_SYNC_HANDLER_START syncType=...
```

If the first two happen but `QUEUE_SYNC_CALLBACK_INVOKED` does not, this issue is confirmed.

---

### PC-QSYNC-002 — Queue-sync send ignores target peer and uses global/current link

**Severity:** Critical for 3-device mesh; high for dual-role collision.

**Evidence**

- `lib/domain/services/mesh_networking_runtime_helper.dart:89-94`
  - `onSendSyncToPeer(peerId, syncMessage)` logs the peer but calls `_bleService.sendQueueSyncMessage(syncMessage)` without passing `peerId`.
- `lib/domain/services/mesh_networking_runtime_helper.dart:101-115`
  - broadcast loops peers but calls the same no-target send each time.
- `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart:542-547`
  - response to a request sends `response.responseMessage` without target.
- `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart:688-697`
  - `_handleSyncRequest()` receives `fromNodeId` but sends no-target queue-sync.
- `lib/data/services/ble_messaging_service.dart:301-326`
  - `sendQueueSyncMessage()` has no target parameter and picks central/peripheral based on global state.
- `lib/domain/interfaces/i_mesh_ble_service.dart:70`
  - interface exposes `sendQueueSyncMessage(QueueSyncMessage message)` only.

**Why it matches your symptoms**

In two-device testing, “current link” happens to be the right link. In 3-device mesh, the response/request can go to whichever connection the global BLE service currently considers active. That looks like packet loss or wrong-peer gossip behavior.

**Fix direction**

Change the API to include target peer:

```dart
Future<void> sendQueueSyncMessage(
  QueueSyncMessage message, {
  required String peerId,
});
```

Then route by peer-specific client/server link maps. Log the chosen path:

```text
QUEUE_SYNC_SEND peer=... path=central-write|peripheral-notify address=... hash=...
```

---

### PC-QSYNC-003 — Queue-sync debounce can drop legitimate response/request pairs

**Severity:** Medium/high.

**Evidence**

- `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart:531-540`
  - debounce is applied per `fromNodeId` before distinguishing request vs response.
- `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart:542-557`
  - request and response handling happen after that debounce.

**Why it matches your symptoms**

A sync request, response, retry, or follow-up message from the same peer inside the debounce window can be skipped. That can cause the initiator to wait until timeout even though data arrived.

**Fix direction**

Debounce duplicate requests only, keyed by something like `(fromNodeId, syncType, queueHash, messageId count)`. Never debounce responses that complete a pending sync.

---

### PC-QSYNC-004 — Transport send result is not propagated to queue-sync manager

**Severity:** Medium/high.

**Evidence**

- `lib/domain/messaging/queue_sync_manager.dart:343-386`
  - `_performSync()` registers a pending completer, calls `onSyncRequest!.call(syncMessage, targetNodeId)`, then waits for a response/timeout.
- `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart:688-697`
  - transport send uses `unawaited(_bleService.sendQueueSyncMessage(message))`.
- `lib/data/services/ble_messaging_service.dart:317-319`
  - if no active BLE link exists, send only logs and returns.

**Why it matches your symptoms**

The sync manager can wait full timeout even when BLE skipped the send because no link was actually ready. This increases debug pain because the failure is delayed and disconnected from the real cause.

**Fix direction**

Make the transport callback return `Future<bool>` or `Future<QueueSyncSendResult>`. Fail fast if BLE cannot route the message.

---

### PC-GOSSIP-001 — BLE facade `startGossipSync()` is placeholder only

**Severity:** Medium/high depending on which sync trigger you rely on.

**Evidence**

- `lib/data/services/ble_service_facade_runtime_helper.dart:365-368`
  - `startGossipSync()` only logs `Gossip sync start hook invoked`.
- `lib/data/services/ble_service_facade_runtime_helper.dart:370+`
  - handshake-complete flow calls this placeholder hook.
- `lib/domain/services/mesh/mesh_queue_sync_coordinator.dart:568-581`
  - actual sync kickoff is tied to connection-info changes and `currentSessionId`.

**Why it matches your symptoms**

If the connection-info event is wrong, late, global, or attached to the wrong peer, handshake completion itself does not force a per-peer sync. The hook name suggests it should, but it does not.

**Fix direction**

On handshake complete, emit a per-peer ready event with resolved peer ID and call/schedule queue sync for that peer explicitly.

---

### PC-CHLOG-001 — Change-log sync send callback is a no-op

**Severity:** High if you expect full gossip/contact/chat metadata sync, lower if queue-sync-only MVP.

**Evidence**

- `lib/core/app_core.dart:871-882`
  - `onSendChangeLogToPeer` logs “Sending X change_log entries…” but never serializes or transmits entries.

**Why it matches your symptoms**

Logs can imply gossip/change-log sync is happening while no BLE payload is sent. This makes it look like the receiver failed to process data, when the sender never sent it.

**Fix direction**

Either implement a protocol message/binary payload for change-log batches, or rename/remove this log until real transmission exists.

---

### PC-FRAG-001 — Legacy fragment IDs are truncated to 6 chars

**Severity:** Medium/high for corruption-looking bugs.

**Evidence**

- `lib/domain/utils/message_fragmenter.dart:42-50`
  - `MessageChunk.toBytes()` stores only the last six chars of `messageId`.
- `lib/domain/utils/message_fragmenter.dart:174-183`
  - `fragmentBytes()` also truncates message IDs to last six chars.

**Why it matches your symptoms**

Two fragmented messages with the same 6-character suffix can mix chunks in the reassembler. That looks exactly like random packet corruption or decryption/parse failures. Binary fragmentation uses stronger IDs, but the legacy path still exists.

**Fix direction**

Use at least a 64-bit random fragment ID or the full protocol message ID. Do not key reassembly by a 6-character suffix.

---

### PC-GATT-002 — Inbound write ACKs success even when message processing fails

**Severity:** Medium/high for false delivery success.

**Evidence**

- `lib/data/services/ble_facade_lifecycle_coordinator.dart:214-245`
  - write request listener responds success after `processIncomingPeripheralData()`.
- `lib/data/services/ble_messaging_service.dart:603-622`
  - `processIncomingPeripheralData()` catches all exceptions and only logs warning.
- `lib/data/services/ble_message_handler_facade_impl.dart:316-319`
  - wrapper catches processing errors and returns null.

**Why it matches your symptoms**

A corrupt queue-sync packet can be ACKed at the GATT write layer even if the app failed to parse/process it. Sender sees write success; receiver silently dropped the payload.

**Fix direction**

Make processing return a structured status:

```dart
enum InboundProcessStatus { handled, waitingForFragments, ignored, failed }
```

Only send GATT success for `handled` or `waitingForFragments`. Send app-level NACK or GATT error for parse/decrypt failure.

---

### PC-GATT-003 — Central notification handler accepts all notification characteristics

**Severity:** Medium.

**Evidence**

- `lib/data/services/ble_facade_lifecycle_coordinator.dart:419-455`
  - central notification handler special-cases Service Changed UUID `0x2A05`, then passes every other notification to handshake/message processing.
  - It does not filter for `BLEConstants.messageCharacteristicUUID`.

**Why it matches your symptoms**

Any non-message notification can be interpreted as handshake, fragment, or protocol bytes. Usually this creates warning noise; in bad cases it can poison partial reassembly.

**Fix direction**

Drop notifications not from the message characteristic/service.

---

### PC-BLE-003 — Duplicate pending connect marks attempt before duplicate check

**Severity:** Medium.

**Evidence**

- `lib/data/services/ble_connection_manager_runtime_client_links.dart:50-56`
  - `_connectionTracker.markAttempt(address)` runs before `_pendingClientConnections.contains(address)` check.

**Why it matches your symptoms**

Duplicate auto-connect attempts can create artificial backoff/tracker state even though no real attempt happened. This can make scan/auto-connect behavior feel inconsistent.

**Fix direction**

Move duplicate-pending check before `markAttempt`, or clear the attempt on early return.

---

### PC-BLE-004 — Direct address checks miss hint-equivalent peers

**Severity:** High for Android rotating addresses and dual-role collision.

**Evidence**

- Some paths use `hasClientLinkForPeer()`, `hasServerLinkForPeer()`, and hint-aware helpers.
- Other paths still compare raw UUID/address only, for example:
  - `lib/data/services/ble_connection_service.dart:185-257` connection adoption is direct-address oriented.
  - `lib/data/services/ble_connection_manager_runtime_client_links.dart:224-226` checks direct `_serverConnections.containsKey(address)` for inbound fallback after notify failure.

**Why it matches your symptoms**

The same physical peer can appear through different addresses/hints. If one path sees “same peer” and another path sees “different device,” you can end up with both central/peripheral channels active or neither chosen correctly.

**Fix direction**

Centralize peer resolution behind one function:

```dart
PeerKey resolvePeerKey({address, ephemeralHint, noiseIdentity});
```

All duplicate, collision, route, UI, and send checks should use that key.

---

## Recommended patch order

### Patch set 1 — Make two-device auto mode truthful

1. Add a real notify subscription barrier.
2. Do not mark connection ready before notify + MTU + handshake are complete.
3. Fix overlay success criteria so inbound/server-won links count as success.
4. Filter central notifications to the message characteristic.
5. Make inbound processing return status rather than swallowing errors and ACKing success.

### Patch set 2 — Fix current queue/gossip failure path

1. Wire queue-sync callback into `ProtocolMessageHandler` inside the split facade path.
2. Add log events around binary reassembly -> protocol parse -> queue-sync callback -> mesh handler.
3. Remove/relax the per-peer debounce for queue-sync responses.
4. Make sync transport send return a result so queue sync fails fast when BLE cannot send.

### Patch set 3 — Make three-device mesh possible

1. Remove global `connectionState == ready` as a new-peer rejection rule.
2. Add per-peer connection state and per-peer routing.
3. Add `peerId` to `sendQueueSyncMessage()` and route to that exact peer.
4. Change broadcast queue sync to send once per actual peer path, not repeatedly over the current/global link.
5. Implement or remove misleading no-op gossip/change-log hooks.

### Patch set 4 — Clean up discovery/debug sanity

1. Hide or clearly label already-connected devices in overlay.
2. Keep no-hint devices out of the main visible list unless confirmed.
3. Finish `scanForSpecificDevice()` or remove callers.
4. Add address/hint/noise-identity correlation IDs to logs.

---

## Minimal instrumentation I would add before another long test session

Use one stable correlation ID per connection attempt:

```text
connAttemptId=<localShort>-<peerShort>-<unixMs>-<seq>
```

Log these fields at every BLE/GATT/gossip boundary:

```text
BLE_LINK_EVENT
  event=scan_seen|connect_start|connected|service_found|mtu_ready|notify_sub_request|notify_sub_confirmed|handshake_start|handshake_ready|ready|disconnect
  connAttemptId=...
  localNode=...
  peerAddress=...
  peerHint=...
  resolvedPeerId=...
  role=central|peripheral
  schedulerState=...
```

```text
BLE_SEND_EVENT
  event=send_start|write_success|notify_success|send_failed
  connAttemptId=...
  resolvedPeerId=...
  path=central_write|peripheral_notify
  protocolType=queueSync|chat|handshake|relay
  payloadBytes=...
  fragmentId=...
  fragmentIndex=...
  fragmentTotal=...
```

```text
BLE_RX_EVENT
  event=rx_raw|fragment_seen|fragment_complete|protocol_parsed|handler_invoked|handler_failed
  resolvedPeerId=...
  protocolType=...
  payloadBytes=...
  fragmentId=...
  syncHash=...
```

```text
QUEUE_SYNC_EVENT
  event=request_send|request_rx|response_send|response_rx|process_start|process_done|timeout|debounced|dropped_no_route
  localNode=...
  peerNode=...
  queueHash=...
  syncType=request|response
  messageIdCount=...
  chosenBlePath=...
```

The crucial thing is that every queue-sync timeout should be traceable to one of these exact states:

- never sent because no route;
- sent over wrong peer route;
- write/notify failed;
- received raw but not reassembled;
- reassembled but not parsed;
- parsed but callback not invoked;
- callback invoked but debounced;
- response sent but not routed back.

---

## Focused manual test matrix

### Test A — Two-device dual-auto, collision/inbound-wins

1. Start both devices in dual auto.
2. Force simultaneous discovery/connection.
3. Verify only one final link path is chosen for that peer.
4. Verify overlay marks success whether final path is central-write or peripheral-notify.
5. Send one chat message each direction.
6. Send one small queue-sync request.
7. Send one large queue-sync request that forces binary fragmentation.

Expected logs:

```text
notify_sub_confirmed before handshake_ready
handshake_ready before queue_sync_request_send
queue_sync_callback_invoked on receiver
```

### Test B — Three-device peer admission

1. Connect A-B to ready.
2. Bring C near A.
3. A must not reject C with `Already READY` unless C is actually same peer as B.
4. A should maintain peer states separately: `B=ready`, `C=connecting/ready`.

### Test C — Wrong-route queue-sync detection

1. A connected to B and C.
2. B sends sync request to A.
3. A response must log `peer=B` and chosen BLE path to B.
4. C should receive nothing.

### Test D — Fragment/reassembly collision

1. Force two large protocol messages close together.
2. Log full fragment IDs.
3. Confirm IDs are not truncated to 6 chars on any legacy path.

---

## Native vs Dart-only assessment

I would not jump native yet based only on this code. The current code has enough Dart-side state/routing/barrier bugs to explain most of what you saw. Native may eventually help with Android BLE reliability or cleaner callback ordering, but the immediate blockers are mostly:

- readiness barriers missing;
- global state used where peer-scoped state is required;
- target peer not passed to send paths;
- queue-sync callback wiring bug;
- UI/debug state not representing inbound-won links.

Fix those first. If notification confirmation is still unreliable after a real barrier/probe, then native BLE becomes a more defensible next step.

---

## Highest-confidence “start here” edits

1. **Wire `ProtocolMessageHandler` queue-sync callback.** This is likely directly related to gossip/queue-sync failures on fragmented payloads.
2. **Make notify subscription a real barrier.** Do not enter ready or start sync until confirmed.
3. **Remove global `ready` from new-peer rejection.** Otherwise 3-device mesh cannot be trusted.
4. **Add `peerId` to queue-sync send.** No more global/current-link sync sends.
5. **Fix overlay inbound success criteria.** This will stop the UI lying while you debug.
6. **Stop ACKing failed inbound processing as success.** Otherwise packet corruption/drop is hidden.
