# PRNG Seeding and Archive PLAINTEXT Migration Fixes - Validation Guide

## Overview
This document describes the security fixes applied to address:
1. **P0.3 — Weak PRNG seeding** in 4 cryptographic files
2. **P0.2 regression — Archive PLAINTEXT migration bug**

## Changes Summary

### Part 1: Weak PRNG Seeding Fixes (4 files)

All four files previously used timestamp-based seeds for cryptographic random number generation, which is insecure because:
- Timestamps are predictable and have low entropy
- Multiple calls within microseconds produce nearly identical seeds
- For ECDSA, predictable k-nonce values can leak private keys

**Files Fixed:**
1. `lib/data/repositories/user_preferences.dart` (lines 116-121)
2. `lib/core/services/simple_crypto.dart` (lines 255-260)
3. `lib/core/security/signing_manager.dart` (lines 40-45)
4. `lib/core/security/message_security.dart` (lines 287-292)

**Before (INSECURE):**
```dart
final seed = List<int>.generate(
  32,
  (i) => DateTime.now().millisecondsSinceEpoch ~/ (i + 1),
);
secureRandom.seed(KeyParameter(Uint8List.fromList(seed)));
```

**After (SECURE):**
```dart
final random = Random.secure();
final seed = Uint8List.fromList(
  List<int>.generate(32, (_) => random.nextInt(256)),
);
secureRandom.seed(KeyParameter(seed));
```

### Part 2: Archive PLAINTEXT Migration Bug Fix

During the P0.2 transition, some archive values were stored as:
`enc::archive::v1::PLAINTEXT:hello world`

The legacy decryption code attempted to decode `PLAINTEXT:hello world` as base64, which failed, causing users to see the raw prefixed string.

**File Fixed:**
- `lib/core/security/archive_crypto.dart` (lines 35-41)

**Fix Applied:**
```dart
if (value.startsWith(_legacyPrefix)) {
  final ciphertext = value.substring(_legacyPrefix.length);
  
  // Handle P0.2 transition window: PLAINTEXT: marker inside legacy prefix
  if (ciphertext.startsWith('PLAINTEXT:')) {
    return ciphertext.substring('PLAINTEXT:'.length);
  }
  
  // Continue with normal legacy decryption...
```

## Validation Steps

### 1. Run Tests
Execute the comprehensive test suite:
```bash
flutter test test/core/security/prng_and_archive_fixes_test.dart
```

**Expected Results:**
- ✅ Signing same message twice produces different signatures
- ✅ No timestamp-based PRNG patterns in cryptographic source files
- ✅ Archive PLAINTEXT migration handles `enc::archive::v1::PLAINTEXT:` values
- ✅ Archive legacy encrypted values still decrypt correctly
- ✅ Archive v2 format still works
- ✅ Roundtrip encrypt/decrypt preserves data

### 2. Manual Code Review
Verify the changes:
```bash
# View the fixed files
git show HEAD:lib/data/repositories/user_preferences.dart | grep -A10 "Random.secure"
git show HEAD:lib/core/services/simple_crypto.dart | grep -A10 "Random.secure"
git show HEAD:lib/core/security/signing_manager.dart | grep -A10 "Random.secure"
git show HEAD:lib/core/security/message_security.dart | grep -A10 "Random.secure"
git show HEAD:lib/core/security/archive_crypto.dart | grep -A5 "PLAINTEXT:"
```

### 3. Verify No Remaining Timestamp-Based PRNG
Run the grep command to ensure no other cryptographic code uses timestamp seeding:
```bash
grep -rn 'millisecondsSinceEpoch\|microsecondsSinceEpoch' lib/ --include="*.dart"
```

**Expected:** Only non-cryptographic uses (message IDs, timestamps, logging) should appear.

**Cryptographic contexts to watch for:**
- Near `FortunaRandom()`
- Near `secureRandom.seed()`
- Near `KeyParameter()`
- Near `ECKeyGenerator()`
- Near `ECDSASigner()`

### 4. Test Archive Migration in Real App
Test the archive PLAINTEXT migration with real user data:

1. **Setup:**
   - Identify a device/database with legacy `enc::archive::v1::PLAINTEXT:` values
   
2. **Test Cases:**
   ```
   Input: "enc::archive::v1::PLAINTEXT:hello"
   Expected: "hello"
   
   Input: "plain text no prefix"
   Expected: "plain text no prefix"
   
   Input: "enc::archive::v1::<valid-base64-encrypted-data>"
   Expected: Decrypted plaintext value
   ```

3. **UI Validation:**
   - Archive view should display clean plaintext
   - No `enc::archive::v1::PLAINTEXT:` prefixes visible to users
   - No decryption errors in logs

### 5. Security Regression Testing
Verify signing/encryption still works correctly:

**Test ECDSA Signing:**
```dart
final sig1 = SimpleCrypto.signMessage("test");
final sig2 = SimpleCrypto.signMessage("test");
assert(sig1 != sig2); // MUST be different (random k-nonce)
```

**Test Key Generation:**
```dart
// Generate two keys and verify they're different
final key1 = await UserPreferences.generateECDHKeyPair();
final key2 = await UserPreferences.generateECDHKeyPair();
assert(key1.privateKey != key2.privateKey);
```

## Security Impact

### Before Fixes
- **CRITICAL:** Weak PRNG seeding could allow:
  - Private key recovery from ECDSA signatures
  - Predictable encryption keys
  - Replay attacks using predictable nonces
  
- **HIGH:** Archive PLAINTEXT migration bug:
  - Users permanently see garbled `enc::archive::v1::PLAINTEXT:` strings
  - Data inaccessible despite being plaintext

### After Fixes
- ✅ Cryptographically secure random number generation
- ✅ Non-deterministic k-nonce for ECDSA (prevents key recovery)
- ✅ Unpredictable encryption keys and IVs
- ✅ Archive migration handles all legacy formats correctly

## Files Changed
1. `lib/data/repositories/user_preferences.dart` - Added `import 'dart:math'`, fixed PRNG seeding
2. `lib/core/services/simple_crypto.dart` - Added `import 'dart:math'`, fixed PRNG seeding
3. `lib/core/security/signing_manager.dart` - Added `import 'dart:math'`, fixed PRNG seeding
4. `lib/core/security/message_security.dart` - Added `import 'dart:math'`, fixed PRNG seeding
5. `lib/core/security/archive_crypto.dart` - Fixed PLAINTEXT migration handling
6. `test/core/security/prng_and_archive_fixes_test.dart` - New comprehensive test suite

## References
- Reference implementation: `lib/core/security/ephemeral_key_manager.dart` lines 117-121 (FIX-003)
- Related: P0.2 encryption migration in PR #55
- NIST SP 800-90A: Recommendations for Random Number Generation
- RFC 6979: Deterministic Usage of DSA and ECDSA (explains k-nonce importance)

## PR Checklist
- [x] All 4 PRNG seeding vulnerabilities fixed
- [x] Archive PLAINTEXT migration bug fixed
- [x] Comprehensive tests added
- [x] All tests pass
- [x] No new timestamp-based PRNG patterns introduced
- [x] Security implications documented
- [ ] Manual validation on real device/database
- [ ] Code review by security-aware reviewer

## Additional Notes
⚠️ **Important:** Code search was limited to 10 results per query. After merging, run:
```bash
grep -rn 'millisecondsSinceEpoch\|microsecondsSinceEpoch' lib/
```
And verify every remaining use is non-cryptographic (logging, timestamps, message IDs).
