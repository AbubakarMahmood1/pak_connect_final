import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/repositories/user_preferences.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'test_helpers/test_setup.dart';

void main() {
  final List<LogRecord> logRecords = [];
  final Set<String> allowedSevere = {};

  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'username_propagation');
  });

  group('Username Propagation Tests', () {
    late UserPreferences userPreferences;
    late BLEStateManager stateManager;

    setUp(() {
      logRecords.clear();
      Logger.root.level = Level.ALL;
      Logger.root.onRecord.listen(logRecords.add);
      userPreferences = UserPreferences();
      stateManager = BLEStateManager();
    });

    tearDown(() {
      final severeErrors = logRecords
          .where((log) => log.level >= Level.SEVERE)
          .where(
            (log) =>
                !allowedSevere.any((pattern) => log.message.contains(pattern)),
          )
          .toList();
      expect(
        severeErrors,
        isEmpty,
        reason:
            'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}',
      );
    });

    test('UserPreferences should update username storage', () async {
      // Setup
      final String testUsername =
          'TestUser${DateTime.now().millisecondsSinceEpoch}';

      // Test
      await userPreferences.setUserName(testUsername);

      // Verify storage
      final storedUsername = await userPreferences.getUserName();
      expect(storedUsername, equals(testUsername));
    });

    test(
      'BLEStateManager should trigger callback on username change',
      () async {
        // Setup
        final String testUsername =
            'CallbackTest${DateTime.now().millisecondsSinceEpoch}';
        String? callbackUsername;

        stateManager.onMyUsernameChanged = (username) {
          callbackUsername = username;
        };

        // Test
        await stateManager.setMyUserName(testUsername);

        // Verify
        expect(stateManager.myUserName, equals(testUsername));
        expect(callbackUsername, equals(testUsername));
      },
    );

    test('Username should be properly cached and invalidated', () async {
      // Setup
      final String initialUsername =
          'Initial${DateTime.now().millisecondsSinceEpoch}';
      final String updatedUsername =
          'Updated${DateTime.now().millisecondsSinceEpoch}';

      // Set initial username
      await stateManager.setMyUserName(initialUsername);
      expect(stateManager.myUserName, equals(initialUsername));

      // Update username with callbacks
      await stateManager.setMyUserNameWithCallbacks(updatedUsername);

      // Verify cache is invalidated and updated
      expect(stateManager.myUserName, equals(updatedUsername));

      // Verify storage is consistent
      final storedUsername = await userPreferences.getUserName();
      expect(storedUsername, equals(updatedUsername));
    });
  });
}
