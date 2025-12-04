# BLE Communication Architecture

## Dual-Role BLE Stack

PakConnect operates as **both central and peripheral** simultaneously:

- **Central Mode**: Scans and connects to other devices
- **Peripheral Mode**: Advertises and accepts connections

**Key Services**:
- `BLEService`: Main orchestrator (`lib/data/services/ble_service.dart`)
- `BLEConnectionManager`: Connection lifecycle management
- `BLEStateManager`: BLE adapter state tracking
- `PeripheralInitializer`: Advertising setup
- `BurstScanningController`: Adaptive scanning strategy

## Handshake Protocol (4 Phases)

The handshake is **sequential** - each response acts as an acknowledgment:

```
Phase 0: CONNECTION_READY
  → Device connects and establishes MTU

Phase 1: IDENTITY_EXCHANGE
  → Sender: ephemeralId, displayName, noisePublicKey
  → Receiver validates and responds with own identity

Phase 1.5: NOISE_HANDSHAKE (XX or KK pattern)
  → 2-3 messages to establish encrypted session
  → Uses X25519 DH + ChaCha20-Poly1305 AEAD

Phase 2: CONTACT_STATUS_SYNC
  → Exchange security levels, trust status
  → Complete handshake
```

**Critical Implementation Detail**: Handshake MUST complete Phase 1.5 (Noise) before any message encryption can occur.

**Files**:
- `lib/core/bluetooth/handshake_coordinator.dart`: Orchestrates handshake flow
- `lib/core/bluetooth/peripheral_initializer.dart`: Manages peripheral role
- `lib/data/services/ble_connection_manager.dart`: Connection state machine

## Message Fragmentation

**Why**: BLE MTU limits (typically 160-220 bytes), messages can be several KB.

**Strategy**: Split into chunks with sequence numbers, reassemble on receiver.

**Format**:
```
[1-byte: fragment index] [1-byte: total fragments] [N bytes: payload]
```

**Critical File**: `lib/core/utils/message_fragmenter.dart`

**Edge Cases Handled**:
- Out-of-order chunks
- Missing chunks (timeout after 30 seconds)
- Duplicate chunks
- Interleaved messages from different senders

## BLE Performance

- **MTU Negotiation**: Always request max MTU (512 bytes) for fewer fragments
- **Characteristic Caching**: Cache characteristic references to avoid repeated discovery
- **Connection Pooling**: Limit concurrent connections (max 7 on Android)

## Power Management

### Adaptive Strategies

**Location**: `lib/core/power/adaptive_power_manager.dart`

Three power modes:
- **HIGH_POWER**: Continuous scanning, always advertising
- **BALANCED**: Burst scanning (10s on, 20s off), periodic advertising
- **LOW_POWER**: Minimal scanning (5s on, 60s off), advertising on demand

**Triggers**: Battery level, screen state, message send events.

**Integration**: `BurstScanningController` bridges power manager to `BLEService`.

## Known BLE Limitations

- **BLE Range**: ~10-30m line-of-sight (hardware dependent)
- **Concurrent Connections**: Android limits to ~7 simultaneous connections
- **Battery Life**: Continuous BLE scanning drains battery (use BALANCED mode)
- **iOS Background**: iOS heavily restricts background BLE (foreground recommended)
