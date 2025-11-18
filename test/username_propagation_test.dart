import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/data/repositories/user_preferences.dart';
import 'package:pak_connect/data/services/ble_state_manager.dart';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment(dbLabel: 'username_propagation');
  });

  group('Username Propagation Tests', () {
    late UserPreferences userPreferences;
    late BLEStateManager stateManager;

    setUp(() {
      userPreferences = UserPreferences();
      stateManager = BLEStateManager();
    });

    test(
      'UserPreferences should update username and notify listeners',
      () async {
        // Setup
        final String testUsername =
            'TestUser${DateTime.now().millisecondsSinceEpoch}';
        String? receivedUsername;

        // Listen to username stream
        final subscription = UserPreferences.usernameStream.listen((username) {
          receivedUsername = username;
        });

        // Test
        await userPreferences.setUserName(testUsername);

        // Allow stream to emit
        await Future.delayed(Duration(milliseconds: 100));

        // Verify
        expect(receivedUsername, equals(testUsername));

        // Verify storage
        final storedUsername = await userPreferences.getUserName();
        expect(storedUsername, equals(testUsername));

        // Cleanup
        await subscription.cancel();
      },
    );

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
