# Development Guide

## Building and Running

```bash
# Get dependencies
flutter pub get

# Run the app
flutter run

# Build for production
flutter build apk --release

# Clean build artifacts
flutter clean
```

## Testing

```bash
# Run all tests
flutter test

# Run tests with coverage
flutter test --coverage

# Run specific test file
flutter test test/path/to/test_file.dart

# Run single test with timeout (for slow tests)
timeout 60 flutter test test/mesh_relay_flow_test.dart

# Run tests excluding specific tags
flutter test --exclude-tags=mesh_relay

# Run tests in compact mode (less verbose)
flutter test --reporter=compact

# Save full-suite runs to logs for later review
set -o pipefail; flutter test | tee flutter_test_latest.log
```

## Code Quality

```bash
# Run static analysis
flutter analyze

# Run tests and build in sequence
flutter test && flutter build apk
```

## Database Testing

```bash
# Test database migrations
flutter test test/database_migration_test.dart

# Test contact repository (SQLite-backed)
flutter test test/contact_repository_sqlite_test.dart
```

## Harness Checklist
- Every suite that touches the database or DI graph must call `TestSetup.initializeTestEnvironment(dbLabel: ...)` and, inside `setUp`, use `configureTestDatabase` + `setupTestDI` so sqlite files remain isolated.
- Prefer the canonical helpers in `test/test_helpers/test_setup.dart` over ad-hoc `cleanupDatabase` calls; they already disable `BatteryOptimizer` and plugin-backed singletons for Flutter tests.
- BLE tests must rely on the new `IBLEPlatformHost` seam (`lib/core/interfaces/i_ble_platform_host.dart`). When exercising `BLEServiceFacade`, inject `_FakeBlePlatformHost` plus stub sub-services (see `test/services/ble_service_facade_test.dart`) instead of instantiating `CentralManager()`/`PeripheralManager()` directly.
- Long-form harness runs should export logs by running `set -o pipefail; flutter test --coverage | tee flutter_test_latest.log`; CI depends on the log + `coverage/lcov.info`, so keep that command stable.

## Testing Patterns

### Test Organization

```
test/
├── unit/                    # Pure logic tests (no Flutter deps)
├── widget/                  # Widget tests (Flutter TestWidgets)
├── integration/             # End-to-end flows
└── *.dart                   # Mixed test files
```

### Common Test Patterns

```dart
// Unit test with Arrange-Act-Assert
void main() {
  group('NoiseSession', () {
    test('encrypts and decrypts message correctly', () {
      // Arrange
      final session = NoiseSession(pattern: 'XX');
      final plaintext = 'Hello';

      // Act
      final ciphertext = session.encryptMessage(utf8.encode(plaintext));
      final decrypted = session.decryptMessage(ciphertext);

      // Assert
      expect(utf8.decode(decrypted), equals(plaintext));
    });
  });
}
```

### Testing with SQLite

Use `sqflite_common_ffi` for desktop testing:

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  test('database test', () {
    // Test code
  });
}
```

## Common Development Tasks

### Adding a New Noise Pattern

1. Define pattern in `lib/core/security/noise/noise_patterns.dart`
2. Update `NoiseSession` to support new handshake flow
3. Add pattern selection logic in `SecurityManager`
4. Test with integration tests
5. Update documentation

### Adding a New Relay Policy

1. Create policy class in `lib/core/messaging/relay_policy.dart`
2. Implement `RelayPolicy` interface
3. Register in `RelayConfigManager`
4. Add configuration UI in settings
5. Test relay behavior with `relay_phase*_test.dart`

### Debugging Handshake Issues

1. Enable verbose logging: Set `Logger.root.level = Level.ALL`
2. Check handshake phase progression in logs (look for 🎯 emojis)
3. Verify Noise session state: `NoiseSession.state` should be `established`
4. Check identity resolution: Ensure `currentEphemeralId` matches sender
5. Use `test/debug_handshake_test.dart` for isolated testing

### Debugging Relay Issues

1. Check `SeenMessageStore`: May contain stale entries (clear after 5 minutes)
2. Verify relay enabled: `MeshRelayEngine.isRelayEnabled`
3. Check topology: `NetworkTopologyAnalyzer.estimateNetworkSize()`
4. Inspect routes: `SmartMeshRouter.findRoute(targetKey)`
5. Use `test/relay_phase*_test.dart` for regression testing

## Logging Strategy

### Structured Logging with Emojis

The codebase uses emoji-prefixed logging for easy visual parsing:

```dart
import 'package:logging/logging.dart';

final _logger = Logger('ComponentName');

_logger.info('🎯 Critical decision point');
_logger.warning('⚠️ Potential issue detected');
_logger.severe('❌ Error occurred', error, stackTrace);
```

**Emoji Key**:
- 🎯 Decision points
- ✅ Success/completion
- ❌ Errors
- ⚠️ Warnings
- 🔐 Security operations
- 📡 BLE operations
- 🔄 Relay operations
- 💾 Database operations

## Integration Checklist

When integrating new features:

- [ ] Update schema version if database changes
- [ ] Add migration logic in `DatabaseHelper`
- [ ] Update relevant providers in `lib/presentation/providers/`
- [ ] Add logging with appropriate emoji prefixes
- [ ] Write unit tests (target >85% coverage)
- [ ] Test with BLE on real devices (emulator BLE is unreliable)
- [ ] Update CLAUDE.md if architecture changes
- [ ] Run `flutter analyze` (should have zero errors)
