# Logging Quick Start - TL;DR

## For New Code (Use This Going Forward)

```dart
import 'package:pak_connect/core/utils/app_logger.dart';

class MyService {
  static final _logger = AppLogger.getLogger('MyService');

  void myMethod() {
    _logger.fine('🔍 Debug details here');
    _logger.info('✅ Important event happened');
    _logger.warning('⚠️ Something unexpected');
    _logger.severe('❌ Error: $error');
  }
}
```

That's it! No `if (kDebugMode)`, no lint warnings, automatically filtered in production.

## Log Levels - When to Use

```dart
// Use FINE for detailed debug traces (hidden in production)
_logger.fine('Processing message ${id}...');
_logger.fine('Queue size: ${queue.length}');

// Use INFO for important events (optional in production)
_logger.info('✅ Connection established');
_logger.info('📤 Message sent successfully');

// Use WARNING for issues (shown in production)
_logger.warning('⚠️ Retry attempt 2/3');
_logger.warning('🚫 Message dropped: TTL exceeded');

// Use SEVERE for errors (always shown in production)
_logger.severe('❌ Failed to connect: $error');
_logger.severe('💥 Encryption failed', error, stackTrace);
```

## Quick Reference

| What You Want | What To Write |
|---------------|---------------|
| Debug trace info | `_logger.fine('...')` |
| Important event | `_logger.info('...')` |
| Warning/issue | `_logger.warning('...')` |
| Error/exception | `_logger.severe('...', error, stackTrace)` |

## Predefined Logger Names

```dart
// Use these for consistency:
AppLogger.getLogger(LoggerNames.ble)
AppLogger.getLogger(LoggerNames.security)
AppLogger.getLogger(LoggerNames.encryption)
AppLogger.getLogger(LoggerNames.meshRelay)
// ... see app_logger.dart for full list
```

## Output Format

**Debug mode** (your console during development):
```
🔍 [MyService] Processing message abc123...
✅ [MyService] Message sent successfully
⚠️ [MyService] Retry attempt 2/3
❌ [MyService] Connection failed
  ↳ Error: TimeoutException
```

**Release mode** (production devices):
```
[WARNING] MyService: Retry attempt 2/3
[SEVERE] MyService: Connection failed
```

## Migration from print()

**Before:**
```dart
if (kDebugMode) {
  print('🔄 Starting process...');
}
print('✅ Process complete');
```

**After:**
```dart
_logger.fine('🔄 Starting process...');
_logger.info('✅ Process complete');
```

## Benefits

✅ No lint warnings
✅ Automatic filtering in production
✅ Zero performance overhead
✅ Same emojis, same convenience
✅ Professional logging infrastructure

## Full Documentation

- Complete guide: `LOGGING_MIGRATION_GUIDE.md`
- Implementation summary: `LOGGING_SUMMARY.md`
- Source code: `lib/core/utils/app_logger.dart`
