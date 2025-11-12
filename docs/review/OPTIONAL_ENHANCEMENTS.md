# Optional Enhancements - Non-Blocking Improvements

**Purpose**: Track nice-to-have improvements that are not critical for production deployment but would enhance robustness, performance, or maintainability.

**Status**: P2 (Medium Priority) - After P0/P1 critical fixes

---

## 📦 MessageFragmenter Enhancements

**Context**: MessageFragmenter is now fully tested (18 tests, all passing) and production-ready. These enhancements would address documented limitations.

**Priority**: P2 (Optional)

### 1. Add CRC32 Checksum Validation

**Effort**: 2-3 hours

**Current Behavior**: No integrity checking on chunks (relies on BLE built-in CRC)

**Proposed Enhancement**:
```dart
// Add to MessageChunk class
class MessageChunk {
  final String messageId;
  final int chunkIndex;
  final int totalChunks;
  final String content;
  final DateTime timestamp;
  final bool isBinary;
  final int? crc32; // ✅ NEW: Optional checksum

  // Compute CRC32 of content
  int _computeCrc32(String content) {
    final bytes = utf8.encode(content);
    return Crc32().convert(bytes).toString();
  }

  // Validate on deserialize
  static MessageChunk fromBytes(Uint8List bytes) {
    // ... existing parsing ...

    // ✅ Validate CRC32 if present
    if (parts.length == 6) {
      final expectedCrc = int.parse(parts[5]);
      final actualCrc = _computeCrc32(parts[4]);
      if (expectedCrc != actualCrc) {
        throw FormatException('CRC32 mismatch: expected $expectedCrc, got $actualCrc');
      }
    }

    return MessageChunk(...);
  }
}
```

**Benefits**:
- Detects corrupted chunks early (before reassembly)
- Provides defense-in-depth (redundant with BLE CRC, but catches edge cases)
- Debugging aid (distinguishes transmission errors from logic bugs)

**Risks**: Low (additive change, backward compatible if CRC32 is optional)

**Dependencies**: Add `crc32` package to `pubspec.yaml`

---

### 2. Add Per-Sender Memory Bounds

**Effort**: 1-2 hours

**Current Behavior**: Unlimited pending messages per sender (memory leak risk under attack)

**Proposed Enhancement**:
```dart
class MessageReassembler {
  final Map<String, Map<int, MessageChunk>> _pendingMessages = {};
  final Map<String, DateTime> _messageTimestamps = {};

  // ✅ NEW: Limit pending messages per sender
  static const int _maxPendingPerSender = 100;

  Uint8List? addChunkBytes(MessageChunk chunk) {
    final messageId = chunk.messageId;

    // ✅ Enforce per-sender limit (LRU eviction)
    if (_pendingMessages.length >= _maxPendingPerSender) {
      final oldestMessageId = _messageTimestamps.entries
          .reduce((a, b) => a.value.isBefore(b.value) ? a : b)
          .key;

      _logger.warning('⚠️ Max pending messages reached, evicting oldest: $oldestMessageId');
      _pendingMessages.remove(oldestMessageId);
      _messageTimestamps.remove(oldestMessageId);
    }

    // ... existing logic ...
  }
}
```

**Benefits**:
- Prevents memory exhaustion under flood attack
- Limits attack surface (max 100 pending messages = ~10MB worst case)
- Graceful degradation (oldest messages dropped first)

**Risks**: Low (defensive programming, doesn't affect normal operation)

**Trade-offs**: Oldest messages dropped if > 100 concurrent, but cleanup mechanism (2min) prevents this in practice

---

### 3. Improve Message ID Uniqueness

**Effort**: 30 minutes

**Current Behavior**: Message ID uses timestamp only (collision risk if 2+ messages sent within 1ms)

**Proposed Enhancement**:
```dart
import 'package:uuid/uuid.dart';

class MessageFragmenter {
  static const _uuid = Uuid();

  static List<MessageChunk> fragmentBytes(
    Uint8List data,
    int maxSize,
    String? messageId, // ✅ Make optional
  ) {
    // ✅ Generate UUID if not provided
    final id = messageId ?? _uuid.v4();

    // Use last 8 chars (shorter than full UUID, but unique enough)
    final shortId = id.length >= 8
        ? id.substring(id.length - 8)
        : id;

    // ... existing logic ...
  }
}
```

**Benefits**:
- Eliminates collision risk (UUID v4 has 122 bits of entropy)
- Maintains backward compatibility (callers can still provide custom IDs)
- Minimal overhead (UUID generation is ~1μs)

**Risks**: None (additive change, fully backward compatible)

**Dependencies**: Add `uuid` package to `pubspec.yaml`

**Note**: Timestamp-based IDs work fine in practice (BLE throughput prevents 1ms collisions), so this is truly optional.

---

## 📊 Database Performance Enhancements

**Context**: N+1 query pattern confirmed in `getAllChats()`, but actual performance impact unknown.

**Priority**: P1 (High) if benchmark confirms >500ms for 100 contacts, P2 (Medium) otherwise

### 4. Optimize getAllChats() Query

**Effort**: 4 hours (rewrite + testing)

**See**: `RECOMMENDED_FIXES.md` FIX-006 for full implementation

**Summary**:
- Current: 1 + N queries (101 queries for 100 contacts)
- Proposed: Single JOIN query
- Expected: 20x performance improvement (1000ms → 50ms)

**Prerequisite**: Run benchmark test first to confirm impact (Gap #2 in CONFIDENCE_GAPS.md)

---

## 🔒 Security Enhancements

**Context**: All P0 critical security fixes should be completed first. These are defense-in-depth improvements.

**Priority**: P2 (Optional, after P0 fixes)

### 5. Add Rate Limiting to Message Fragmentation

**Effort**: 2 hours

**Current Behavior**: No rate limiting on message fragmentation (flood risk)

**Proposed Enhancement**:
```dart
class MessageFragmenter {
  static final Map<String, int> _fragmentCounts = {};
  static final Map<String, DateTime> _lastReset = {};

  static const int _maxFragmentsPerSecond = 100;

  static List<MessageChunk> fragmentBytes(
    Uint8List data,
    int maxSize,
    String messageId,
  ) {
    final now = DateTime.now();

    // ✅ Rate limit check
    _resetCountIfNeeded(now);
    final count = _fragmentCounts[messageId] ?? 0;

    if (count >= _maxFragmentsPerSecond) {
      throw RateLimitException(
        'Fragment rate limit exceeded for $messageId: $count fragments/sec'
      );
    }

    // ... existing logic ...

    // Increment counter
    _fragmentCounts[messageId] = count + 1;
  }

  static void _resetCountIfNeeded(DateTime now) {
    _fragmentCounts.removeWhere((id, _) {
      final lastReset = _lastReset[id] ?? now;
      if (now.difference(lastReset) > Duration(seconds: 1)) {
        _lastReset.remove(id);
        return true;
      }
      return false;
    });
  }
}
```

**Benefits**:
- Prevents fragmentation flood attacks (max 100 messages/sec)
- Protects BLE stack from overload
- Minimal performance impact (simple counter check)

**Risks**: Low (fails gracefully with exception)

---

## 🧪 Testing Enhancements

**Context**: MessageFragmenter now has 18 tests. Other critical components need similar coverage.

**Priority**: P1 (High)

### 6. BLEService Test Suite

**Effort**: 2 days (25 tests)

**See**: `RECOMMENDED_FIXES.md` FIX-010 for test cases

**Coverage Targets**:
- Connection lifecycle (connect, disconnect, reconnect)
- Message sending/receiving
- MTU negotiation
- Characteristic discovery
- Error handling (timeout, BLE off, permission denied)

**Dependencies**: BLE mocking infrastructure (use `mockito` or `flutter_ble_lib` mocks)

---

### 7. Noise Protocol Integration Tests

**Effort**: 1 day (10 tests)

**Coverage Targets**:
- XX pattern handshake (3 messages)
- KK pattern handshake (2 messages)
- Session rekeying after 10k messages
- Nonce replay detection
- Session destroy (key zeroing)

**Dependencies**: HandshakeCoordinator mocking

---

## 📱 UI/UX Enhancements

**Context**: Accessibility and user experience improvements.

**Priority**: P2 (Medium)

### 8. Add Semantic Labels for Screen Readers

**Effort**: 1 day

**See**: `RECOMMENDED_FIXES.md` FIX-012

**WCAG 2.1 Level A Compliance**:
- Add `Semantics` widgets to icon buttons
- Add `label` properties to interactive elements
- Test with TalkBack (Android) and VoiceOver (iOS)

---

## 🏗️ Architecture Refactoring

**Context**: God classes identified (BLEService: 3,426 LOC, MeshNetworkingService: 2,001 LOC)

**Priority**: P2-P3 (After all P0/P1 fixes)

### 9. Break Down BLEService

**Effort**: 4 weeks (1-2 developers)

**See**: `01_ARCHITECTURE_REVIEW.md` for detailed refactoring plan

**Summary**:
- Extract 5 smaller services from BLEService
- Replace AppCore singleton with Riverpod providers
- Fix 7 layer boundary violations
- Eliminate 70+ direct instantiations with DI

**Dependencies**: All P0/P1 fixes must be complete first (avoid merge conflicts)

---

## 📄 Documentation Created

This file captures P2 enhancements mentioned in:
- MessageFragmenter test documentation (CRC32, memory bounds, UUID)
- RECOMMENDED_FIXES.md (all P1/P2 fixes)
- 01_ARCHITECTURE_REVIEW.md (refactoring plan)

**Last Updated**: 2025-11-11
