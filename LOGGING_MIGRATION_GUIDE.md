# Logging Migration Guide

This guide shows how to migrate from `print()` statements to the proper `Logger` system.

## Why Migrate?

- ✅ **Zero flutter analyze warnings** - No more `avoid_print` lint errors
- ✅ **Production-ready** - Automatically filters logs in release builds
- ✅ **Zero performance overhead** - Logger handles filtering efficiently
- ✅ **Better debugging** - Filterable, searchable, hierarchical logs
- ✅ **Same convenience** - Keep your emojis and debug output format

## Quick Start

### Option 1: Using AppLogger directly

```dart
// OLD: Direct print statements
print('🔄 Starting background refresh...');
print('✅ Refresh completed');
print('❌ Refresh failed: $error');

// NEW: Using AppLogger
import 'package:pak_connect/core/utils/app_logger.dart';

final _logger = AppLogger.getLogger('BackgroundCache');
_logger.fine('🔄 Starting background refresh...');
_logger.info('✅ Refresh completed');
_logger.severe('❌ Refresh failed: $error');
```

### Option 2: Using the extension (shorter syntax)

```dart
import 'package:pak_connect/core/utils/app_logger.dart';

final _logger = 'BackgroundCache'.logger;
_logger.info('Something happened');
```

### Option 3: Using predefined logger names

```dart
import 'package:pak_connect/core/utils/app_logger.dart';

final _logger = AppLogger.getLogger(LoggerNames.ble);
final _securityLogger = AppLogger.getLogger(LoggerNames.security);
final _encryptionLogger = AppLogger.getLogger(LoggerNames.encryption);
```

## Log Levels Guide

Choose the right level for your logs:

| Level | When to Use | Example | Production Output |
|-------|-------------|---------|-------------------|
| `FINE` | Detailed debug info, trace-level logs | Function entry/exit, loop iterations | ❌ Hidden |
| `INFO` | Important events, state changes | Connection established, message sent | ✅ Shown (optional) |
| `WARNING` | Recoverable issues, unexpected states | Retry attempt, fallback used | ✅ Shown |
| `SEVERE` | Errors, exceptions, critical issues | Connection failed, encryption error | ✅ Shown |

```dart
// Detailed debugging (only in debug builds)
_logger.fine('🔍 Processing message ${messageId}...');
_logger.fine('📊 Current queue size: ${queue.length}');

// Important events (shown in production if configured)
_logger.info('✅ Message delivered successfully');
_logger.info('🌐 Device connected: ${deviceId}');

// Warnings (always shown in production)
_logger.warning('⚠️ Retry attempt 2/3 for message ${messageId}');
_logger.warning('🚫 Message dropped: TTL exceeded');

// Errors (always shown in production)
_logger.severe('❌ Failed to encrypt message: $error');
_logger.severe('💥 BLE connection lost', error, stackTrace);
```

## Migration Examples

### Example 1: Simple print statements

**Before:**
```dart
class BackgroundCacheService {
  static void _refreshCacheInBackground() async {
    print('🔄 Background cache refresh...');

    try {
      await HintCacheManager.updateCache();
      print('✅ Background refresh completed');
    } catch (e) {
      print('❌ Background refresh failed: $e');
    }
  }
}
```

**After:**
```dart
import 'package:pak_connect/core/utils/app_logger.dart';

class BackgroundCacheService {
  static final _logger = AppLogger.getLogger('BackgroundCache');

  static void _refreshCacheInBackground() async {
    _logger.fine('🔄 Background cache refresh...');

    try {
      await HintCacheManager.updateCache();
      _logger.info('✅ Background refresh completed');
    } catch (e) {
      _logger.severe('❌ Background refresh failed: $e');
    }
  }
}
```

### Example 2: Conditional logging with kDebugMode

**Before:**
```dart
import 'package:flutter/foundation.dart';

class EphemeralKeyManager {
  void rotateKeys() {
    if (kDebugMode) {
      print('🔄 Rotating ephemeral keys...');
    }

    // ... rotation logic ...

    if (kDebugMode) {
      print('✅ Keys rotated successfully');
    }
  }
}
```

**After:**
```dart
import 'package:pak_connect/core/utils/app_logger.dart';

class EphemeralKeyManager {
  static final _logger = AppLogger.getLogger(LoggerNames.keyManagement);

  void rotateKeys() {
    _logger.fine('🔄 Rotating ephemeral keys...');

    // ... rotation logic ...

    _logger.info('✅ Keys rotated successfully');
  }
}
```

**No more `if (kDebugMode)` needed!** The Logger automatically filters based on level.

### Example 3: Error logging with context

**Before:**
```dart
class BleService {
  Future<void> sendMessage(Message msg) async {
    try {
      await _send(msg);
      print('✅ Message sent: ${msg.id}');
    } catch (e, stackTrace) {
      print('❌ Failed to send message: $e');
      print('Stack trace: $stackTrace');
    }
  }
}
```

**After:**
```dart
import 'package:pak_connect/core/utils/app_logger.dart';

class BleService {
  static final _logger = AppLogger.getLogger(LoggerNames.bleService);

  Future<void> sendMessage(Message msg) async {
    try {
      await _send(msg);
      _logger.info('✅ Message sent: ${msg.id}');
    } catch (e, stackTrace) {
      _logger.severe('❌ Failed to send message: $e', e, stackTrace);
    }
  }
}
```

### Example 4: Using hierarchical logger names

For better log filtering and organization:

```dart
// Security module
final _logger = AppLogger.getLogger(LoggerNames.security);

// More specific: encryption sub-module
final _encLogger = AppLogger.getLogger(LoggerNames.encryption);

// Even more specific: custom hierarchical names
final _keyRotationLogger = AppLogger.getLogger('Security.KeyManagement.Rotation');
```

You can then filter logs by hierarchy:
- `Security.*` - All security logs
- `Security.KeyManagement.*` - Only key management logs
- `Security.KeyManagement.Rotation` - Only rotation logs

## Migration Strategy

You don't need to migrate everything at once. Here's a gradual approach:

### Phase 1: New code (✅ Already done!)
All new code should use Logger from the start.

### Phase 2: High-traffic files (Recommended next)
Migrate files with the most print statements:
1. `lib/core/security/ephemeral_key_manager.dart` (many prints)
2. `lib/core/security/background_cache_service.dart` (many prints)
3. `lib/data/services/ble_service.dart`
4. `lib/data/services/ble_message_handler.dart`

### Phase 3: All remaining files (Optional)
Gradually migrate remaining files as you touch them.

## Testing Your Migration

1. **Run flutter analyze** - Should see fewer `avoid_print` warnings
2. **Run in debug mode** - Logs should still appear with emojis
3. **Build release APK** - Only WARNING/SEVERE logs appear
4. **Check performance** - Should be equal or better

## Advanced: Changing Log Levels at Runtime

You can dynamically adjust log levels for specific modules:

```dart
// Make BLE module more verbose temporarily
Logger('BLE').level = Level.ALL;

// Reduce noise from mesh relay
Logger('MeshRelay').level = Level.WARNING;

// Reset to default
Logger('BLE').level = null; // Inherits from root logger
```

## Common Logger Names Reference

Use these predefined names for consistency:

```dart
// Available in LoggerNames class:
LoggerNames.app                 // 'App'
LoggerNames.meshRelay           // 'MeshRelay'
LoggerNames.meshRouter          // 'MeshRouter'
LoggerNames.offlineQueue        // 'OfflineQueue'
LoggerNames.security            // 'Security'
LoggerNames.encryption          // 'Security.Encryption'
LoggerNames.keyManagement       // 'Security.KeyManagement'
LoggerNames.spamPrevention      // 'Security.SpamPrevention'
LoggerNames.ble                 // 'BLE'
LoggerNames.bleService          // 'BLE.Service'
LoggerNames.bleScanning         // 'BLE.Scanning'
LoggerNames.bleConnection       // 'BLE.Connection'
LoggerNames.chat                // 'Chat'
LoggerNames.chatStorage         // 'Chat.Storage'
LoggerNames.contact             // 'Contact'
LoggerNames.ui                  // 'UI'
LoggerNames.power               // 'Power'
```

## FAQ

**Q: Do I need to remove my `if (kDebugMode)` checks?**
A: No! They're fine and have no performance cost in release builds. But Logger is cleaner.

**Q: Can I keep my emojis?**
A: Yes! The AppLogger preserves emojis in debug mode automatically.

**Q: Will this slow down my app?**
A: No. In release builds, filtered logs have near-zero overhead.

**Q: What about test files?**
A: You can keep `print()` in tests, or use Logger for better test output filtering.

**Q: Can I send logs to Crashlytics/Sentry?**
A: Yes! Modify `AppLogger.initialize()` to route severe logs to crash reporting services.

## Need Help?

- Check `lib/core/utils/app_logger.dart` for the full API
- See `lib/core/utils/mesh_debug_logger.dart` for a complete migration example
- The `logging` package docs: https://pub.dev/packages/logging
