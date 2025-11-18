# PakConnect - Recommended Fixes Roadmap

**Document Purpose**: Concrete, actionable fixes with code examples for all critical issues

**Organization**: Fixes grouped by priority (P0 → P1 → P2) with effort estimates and expected outcomes

---

## 🔴 P0: CRITICAL FIXES (Week 1-2) - BLOCKS PRODUCTION

### FIX-001: Private Key Memory Leak in NoiseSession

**Status: ✅ COMPLETE (Phase 0 deliverable, Nov 2025)**

- SecureKey RAII wrapper implemented at `lib/core/security/secure_key.dart:31-135`
- `NoiseSession` now wraps `_localStaticPrivateKey` in `SecureKey` and zeroes the caller buffer immediately (`lib/core/security/noise/noise_session.dart:92-132`)
- Downstream primitives (`cipher_state`, `dh_state`, `symmetric_state`) accept the wrapper to guarantee zeroization on destroy
- Tests added in `test/core/security/secure_key_test.dart` cover construction, zeroing, destruction, and hex helpers

**Implemented Code Snippet**:
```dart
_localStaticPrivateKey = SecureKey(localStaticPrivateKey);

void destroy() {
  _localStaticPrivateKey.destroy();
  _logger.info('[$peerID] Noise session destroyed');
}
```

**Outcome**: Forward secrecy preserved; no plain copies of private keys linger in heap dumps.


### FIX-002: Weak Fallback Encryption Key

**Status: ✅ COMPLETE (Phase 0 deliverable, Nov 2025)**

- `_generateFallbackKey()` removed; `getOrCreateEncryptionKey()` now fails closed if secure storage is unavailable (`lib/data/database/database_encryption.dart:60-117`)
- `_generateSecureKey()` derives entropy via `Random.secure()` and writes to SQLCipher after successful persistence
- Splash/onboarding flow displays the user-facing remediation dialog (see Phase 0 docs) when secure storage cannot be accessed

**Implemented Code Snippet**:
```dart
try {
  String? key = await _secureStorage.read(key: _encryptionKeyStorageKey);
  key ??= await _generateSecureKey();
  await _secureStorage.write(key: _encryptionKeyStorageKey, value: key);
  _cachedEncryptionKey = key;
  return key;
} catch (e, stackTrace) {
  _logger.severe('❌ Failed to access secure storage: $e', e, stackTrace);
  throw DatabaseEncryptionException(
    'Cannot initialize database: Secure storage unavailable.\\n\\n'
    'PakConnect requires secure storage for encryption keys.\\n'
    'Please ensure:\\n'
    '  • Android: Device lock screen is set\\n'
    '  • iOS: Passcode is enabled\\n\\n'
    'Error details: $e',
  );
}
```

**Outcome**: Database encryption keys are only generated/stored when hardware-backed storage is available; weak fallback removed.


### FIX-003: Weak PRNG Seed in Ephemeral Keys

**Status: ✅ COMPLETE (Phase 0 deliverable, Nov 2025)**

- `FortunaRandom` now seeds from a 32-byte array populated by `Random.secure()` (`lib/core/security/ephemeral_key_manager.dart:110-146`)
- Session restore cache removed so every app boot rotates keys; `HintCacheManager` notified via `rotateSession()`
- Logging updated to reflect secure seed usage

**Implemented Code Snippet**:
```dart
final secureRandom = FortunaRandom();
final random = Random.secure();
final seed = Uint8List.fromList(
  List<int>.generate(32, (_) => random.nextInt(256)),
);
secureRandom.seed(KeyParameter(seed));
```

**Outcome**: Ephemeral signing keys use cryptographically strong entropy, eliminating predictable-session attacks.


---

### FIX-010 through FIX-015: (Additional High Priority Fixes)

See full details in individual sections above. Summary:

- **FIX-010**: BLEService/BLEServiceFacade unit tests ✅ COMPLETE (`test/services/ble_service_facade_test.dart`, 152 specs)
- **FIX-011**: Fix 11 skipped/flaky tests (deadlock resolution, 2 days)
- **FIX-012**: Phase 2C ChatScreen refactoring (6 method migrations, 5 controllers, 16 tests, 0 breaking changes) ✅ COMPLETE
- **FIX-013**: Add semantic labels for WCAG compliance (1 day)
- **FIX-014**: Move encryption to isolate (UI performance, 1 day)
- **FIX-015**: Add missing database indexes (2 hours)
- **FIX-016**: Enforce session rekeying (4 hours)

---

## 🟢 P2: MEDIUM PRIORITY (Weeks 5-8)

### Architecture Refactoring

**See**: `docs/review/01_ARCHITECTURE_REVIEW.md` for detailed refactoring plan

**Key Tasks**:
1. Break down BLEService (3,426 lines → 5 services)
2. Break down MeshNetworkingService (2,001 lines → 5 coordinators)
3. Eliminate AppCore singleton (replace with Riverpod providers)
4. Fix layer boundary violations (7 imports)
5. Replace 70+ direct instantiations with DI

**Effort**: 4 weeks (1-2 developers)

---

## 📊 Progress Tracking Template

```markdown
## P0 Critical Fixes Progress

- [x] FIX-001: Private key memory leak (1 day)
- [x] FIX-002: Weak fallback encryption (2 hours)
- [x] FIX-003: Weak PRNG seed (2 hours)
- [ ] FIX-004: Nonce race condition (4 hours)
- [ ] FIX-005: Missing seen_messages table (3 hours)
- [ ] FIX-006: N+1 query optimization (4 hours)
- [ ] FIX-007: StreamProvider memory leaks (2 hours)
- [ ] FIX-008: Handshake phase timing (1 day)

**Total: 1.5 weeks**

Progress: [ ] Not Started | [ ] In Progress | [ ] Code Review | [ ] Testing | [ ] Complete
```

---

## 🎯 Expected Outcomes Summary

### After P0 Fixes (Week 2)
- ✅ All critical security vulnerabilities resolved (CVSS 7.5-9.1)
- ✅ No race conditions in encryption path
- ✅ Mesh deduplication working correctly
- ✅ 20x performance improvement in chat loading
- ✅ No memory leaks from providers

### After P1 Fixes (Week 4)
- ✅ 100% test coverage for MessageFragmenter
- ✅ 80%+ test coverage for BLEService
- ✅ All flaky tests resolved
- ✅ WCAG 2.1 Level A compliance
- ✅ No UI freezes during encryption

### After P2 Fixes (Week 8+)
- ✅ SOLID-compliant architecture
- ✅ No God classes (all <500 lines)
- ✅ Zero layer boundary violations
- ✅ 85%+ test coverage across all components

---

**Document Version**: 1.0
**Last Updated**: November 18, 2025
**Next Review**: After Phase 1 completion
