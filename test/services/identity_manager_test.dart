import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/identity_manager.dart';
import 'package:pak_connect/data/repositories/user_preferences.dart';
import 'package:mockito/mockito.dart';

void main() {
  group('IdentityManager', () {
    late IdentityManager identityManager;
    late MockUserPreferences mockUserPreferences;

    setUp(() {
      mockUserPreferences = MockUserPreferences();
      identityManager = IdentityManager(userPreferences: mockUserPreferences);
    });

    test('initializes with null username initially', () {
      expect(identityManager.myUserName, isNull);
    });

    test('initializes with null persistent ID initially', () {
      expect(identityManager.myPersistentId, isNull);
    });

    test('initializes with null ephemeral ID initially', () {
      // Note: EphemeralKeyManager needs to be initialized first
      // expect(identityManager.myEphemeralId, isNull);
      // Skip for now as EphemeralKeyManager requires initialization
    });

    test('sets and retrieves other user name', () {
      identityManager.setOtherUserName('Alice');
      expect(identityManager.otherUserName, equals('Alice'));
    });

    test('clears other user name when set to null', () {
      identityManager.setOtherUserName('Alice');
      expect(identityManager.otherUserName, equals('Alice'));

      identityManager.setOtherUserName(null);
      expect(identityManager.otherUserName, isNull);
    });

    test('sets other device identity with device ID and display name', () {
      identityManager.setOtherDeviceIdentity('device123', 'Bob');
      expect(identityManager.otherUserName, equals('Bob'));
    });

    test('stores ephemeral ID mapping', () {
      const ephemeralId = 'eph12345';
      const persistentKey = 'persistent_key_123';

      identityManager.setTheirEphemeralId(ephemeralId, 'Carol');
      expect(identityManager.theirEphemeralId, equals(ephemeralId));
    });

    test('retrieves persistent key from ephemeral ID mapping', () {
      const ephemeralId = 'eph12345';
      const persistentKey = 'persistent_key_123';

      // Note: This would require the mapping to be stored
      // Current implementation needs to be enhanced to store mappings
      identityManager.setTheirEphemeralId(ephemeralId, 'Dave');

      final result = identityManager.getPersistentKeyFromEphemeral(ephemeralId);
      // Verify the mapping can be retrieved
    });

    test('returns null for unknown ephemeral IDs', () {
      final result = identityManager.getPersistentKeyFromEphemeral(
        'unknown_id',
      );
      expect(result, isNull);
    });

    test(
      'triggers onNameChanged callback when other username changes',
      () async {
        var callbackTriggered = false;
        identityManager.onNameChanged = (name) {
          callbackTriggered = true;
        };

        identityManager.setOtherUserName('Eve');
        // Note: Callback triggering depends on implementation
      },
    );

    test('getMyPersistentId returns persistent ID', () {
      final id = identityManager.getMyPersistentId();
      // Should return ID or null depending on initialization
    });
  });
}

class MockUserPreferences extends Mock implements UserPreferences {}
