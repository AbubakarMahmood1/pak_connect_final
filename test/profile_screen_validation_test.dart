// Automated validation tests for Profile Screen
// Tests all backend implementations and UI functionality

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/data/repositories/user_preferences.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:pak_connect/data/repositories/chats_repository.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'dart:convert';
import 'test_helpers/test_setup.dart';

void main() {
  setUpAll(() async {
    await TestSetup.initializeTestEnvironment();
  });

  setUp(() async {
    await TestSetup.cleanupDatabase();
    TestSetup.resetSharedPreferences();
  });

  group('Profile Screen Backend Validation', () {
    late UserPreferences userPreferences;
    late ContactRepository contactRepository;
    late ChatsRepository chatsRepository;

    setUp(() {
      userPreferences = UserPreferences();
      contactRepository = ContactRepository();
      chatsRepository = ChatsRepository();
    });

    tearDown(() async {
      UserPreferences.dispose();
      await TestSetup.completeCleanup();
    });

    // ==============================================
    // TEST 1: USERNAME MANAGEMENT
    // ==============================================
    test('Username can be set and retrieved', () async {
      // Arrange
      const testUsername = 'TestUser123';

      // Act
      await userPreferences.setUserName(testUsername);
      final retrievedName = await userPreferences.getUserName();

      // Assert
      expect(retrievedName, equals(testUsername));
    });

    test('Username updates are reactive via stream', () async {
      // Arrange
      const testUsername = 'ReactiveUser';
      final streamValues = <String>[];

      // Act
      final subscription = UserPreferences.usernameStream.listen(
        (username) => streamValues.add(username),
      );

      await userPreferences.setUserName(testUsername);
      await Future.delayed(Duration(milliseconds: 100)); // Allow stream to emit

      // Assert
      expect(streamValues, contains(testUsername));

      // Cleanup
      await subscription.cancel();
    });

    test('UsernameNotifier updates correctly', () async {
      // Arrange
      final container = ProviderContainer(
        overrides: [usernameProvider.overrideWith(_TestUsernameNotifier.new)],
      );
      const newUsername = 'NotifierTest';

      // Act
      final notifier = container.read(usernameProvider.notifier);
      await notifier.updateUsername(newUsername);
      final username = await container.read(usernameProvider.future);

      // Assert
      expect(username, equals(newUsername));

      // Cleanup
      container.dispose();
    });

    // ==============================================
    // TEST 2: DEVICE ID MANAGEMENT
    // ==============================================
    test('Device ID is generated and persisted', () async {
      // Act
      final deviceId1 = await userPreferences.getOrCreateDeviceId();
      final deviceId2 = await userPreferences.getOrCreateDeviceId();

      // Assert
      expect(deviceId1, isNotEmpty);
      expect(
        deviceId1,
        equals(deviceId2),
        reason: 'Device ID should be persistent',
      );
      expect(
        deviceId1,
        startsWith('dev_'),
        reason: 'Device ID should have correct format',
      );
    });

    // ==============================================
    // TEST 3: ENCRYPTION KEYS
    // ==============================================
    test('Encryption key pair can be generated', () async {
      // Act
      final keyPair = await userPreferences.getOrCreateKeyPair();

      // Assert
      expect(keyPair['public'], isNotEmpty);
      expect(keyPair['private'], isNotEmpty);
      expect(
        keyPair['public']!.length,
        greaterThan(50),
        reason: 'Public key should be substantial',
      );
      expect(
        keyPair['private']!.length,
        greaterThan(50),
        reason: 'Private key should be substantial',
      );
    });

    test('Public key can be retrieved independently', () async {
      // Arrange
      await userPreferences.getOrCreateKeyPair(); // Ensure keys exist

      // Act
      final publicKey = await userPreferences.getPublicKey();

      // Assert
      expect(publicKey, isNotEmpty);
    });

    test('Key regeneration creates new keys', () async {
      // Arrange
      final originalKeyPair = await userPreferences.getOrCreateKeyPair();
      final originalPublicKey = originalKeyPair['public'];

      // Act
      await userPreferences.regenerateKeyPair();
      final newPublicKey = await userPreferences.getPublicKey();

      // Assert
      expect(newPublicKey, isNotEmpty);
      expect(
        newPublicKey,
        isNot(equals(originalPublicKey)),
        reason: 'Regenerated key should be different',
      );
    });

    // ==============================================
    // TEST 4: STATISTICS - CONTACT COUNT
    // ==============================================
    test('Contact count returns valid number', () async {
      // Act
      final count = await contactRepository.getContactCount();

      // Assert
      expect(count, isA<int>());
      expect(count, greaterThanOrEqualTo(0));
    });

    test('Verified contact count returns valid number', () async {
      // Act
      final count = await contactRepository.getVerifiedContactCount();

      // Assert
      expect(count, isA<int>());
      expect(count, greaterThanOrEqualTo(0));
    });

    test('Verified count is less than or equal to total count', () async {
      // Act
      final totalCount = await contactRepository.getContactCount();
      final verifiedCount = await contactRepository.getVerifiedContactCount();

      // Assert
      expect(
        verifiedCount,
        lessThanOrEqualTo(totalCount),
        reason: 'Verified contacts cannot exceed total contacts',
      );
    });

    // ==============================================
    // TEST 5: STATISTICS - CHAT COUNT
    // ==============================================
    test('Chat count returns valid number', () async {
      // Act
      final count = await chatsRepository.getChatCount();

      // Assert
      expect(count, isA<int>());
      expect(count, greaterThanOrEqualTo(0));
    });

    test('Archived chat count returns valid number', () async {
      // Act
      final count = await chatsRepository.getArchivedChatCount();

      // Assert
      expect(count, isA<int>());
      expect(count, greaterThanOrEqualTo(0));
    });

    // ==============================================
    // TEST 6: STATISTICS - MESSAGE COUNT
    // ==============================================
    test('Total message count returns valid number', () async {
      // Act
      final count = await chatsRepository.getTotalMessageCount();

      // Assert
      expect(count, isA<int>());
      expect(count, greaterThanOrEqualTo(0));
    });

    // ==============================================
    // TEST 7: QR CODE DATA GENERATION
    // ==============================================
    test('QR data contains all required fields', () async {
      // Arrange
      const testUsername = 'QRTestUser';
      await userPreferences.setUserName(testUsername);
      final deviceId = await userPreferences.getOrCreateDeviceId();
      final publicKey = await userPreferences.getPublicKey();

      // Act
      final qrData = {
        'displayName': testUsername,
        'publicKey': publicKey,
        'deviceId': deviceId,
        'version': 1,
      };
      final qrJson = jsonEncode(qrData);
      final decoded = jsonDecode(qrJson);

      // Assert
      expect(decoded['displayName'], equals(testUsername));
      expect(decoded['publicKey'], equals(publicKey));
      expect(decoded['deviceId'], equals(deviceId));
      expect(decoded['version'], equals(1));
    });

    test('QR data is valid JSON', () async {
      // Arrange
      const testUsername = 'JSONTestUser';
      await userPreferences.setUserName(testUsername);
      final deviceId = await userPreferences.getOrCreateDeviceId();
      final publicKey = await userPreferences.getPublicKey();

      // Act
      final qrData = {
        'displayName': testUsername,
        'publicKey': publicKey,
        'deviceId': deviceId,
        'version': 1,
      };
      final qrJson = jsonEncode(qrData);

      // Assert
      expect(
        () => jsonDecode(qrJson),
        returnsNormally,
        reason: 'QR data should be valid JSON',
      );
    });

    // ==============================================
    // TEST 8: PUBLIC KEY CACHE INVALIDATION
    // ==============================================
    // REMOVED: ChatsRepository no longer caches public keys after FIX-006 optimization
    // The JOIN query strategy eliminates the need for caching

    // ==============================================
    // TEST 9: DATA PERSISTENCE ACROSS RESTARTS
    // ==============================================
    test('Username persists across instance recreations', () async {
      // Arrange
      const testUsername = 'PersistentUser';
      final prefs1 = UserPreferences();
      await prefs1.setUserName(testUsername);

      // Act - Create new instance to simulate app restart
      final prefs2 = UserPreferences();
      final retrievedName = await prefs2.getUserName();

      // Assert
      expect(retrievedName, equals(testUsername));
    });

    test('Device ID persists across instance recreations', () async {
      // Arrange
      final prefs1 = UserPreferences();
      final deviceId1 = await prefs1.getOrCreateDeviceId();

      // Act - Create new instance to simulate app restart
      final prefs2 = UserPreferences();
      final deviceId2 = await prefs2.getOrCreateDeviceId();

      // Assert
      expect(
        deviceId2,
        equals(deviceId1),
        reason: 'Device ID should remain the same across restarts',
      );
    });

    // ==============================================
    // TEST 10: ERROR HANDLING
    // ==============================================
    test('Empty username is replaced with default', () async {
      // Arrange
      await userPreferences.setUserName('');

      // Act
      final username = await userPreferences.getUserName();

      // Assert
      expect(
        username,
        equals('User'),
        reason: 'Empty username should default to "User"',
      );
    });

    test('Statistics methods handle errors gracefully', () async {
      // Act & Assert - Should not throw, even if database has issues
      expect(() => contactRepository.getContactCount(), returnsNormally);
      expect(
        () => contactRepository.getVerifiedContactCount(),
        returnsNormally,
      );
      expect(() => chatsRepository.getChatCount(), returnsNormally);
      expect(() => chatsRepository.getTotalMessageCount(), returnsNormally);
    });
  });

  group('Profile Screen Integration Tests', () {
    // ==============================================
    // TEST 11: FULL PROFILE DATA LOAD
    // ==============================================
    test('All profile data can be loaded successfully', () async {
      // Arrange
      final userPreferences = UserPreferences();
      final contactRepository = ContactRepository();
      final chatsRepository = ChatsRepository();

      // Act - Load all data as profile screen would
      final username = await userPreferences.getUserName();
      final deviceId = await userPreferences.getOrCreateDeviceId();
      final publicKey = await userPreferences.getPublicKey();
      final contactCount = await contactRepository.getContactCount();
      final verifiedCount = await contactRepository.getVerifiedContactCount();
      final chatCount = await chatsRepository.getChatCount();
      final messageCount = await chatsRepository.getTotalMessageCount();

      // Assert - All data should be valid
      expect(username, isNotEmpty);
      expect(deviceId, isNotEmpty);
      expect(publicKey, isNotEmpty);
      expect(contactCount, greaterThanOrEqualTo(0));
      expect(verifiedCount, greaterThanOrEqualTo(0));
      expect(chatCount, greaterThanOrEqualTo(0));
      expect(messageCount, greaterThanOrEqualTo(0));
    });

    // ==============================================
    // TEST 12: REFRESH FUNCTIONALITY
    // ==============================================
    test('Profile refresh loads updated data', () async {
      // Arrange
      final userPreferences = UserPreferences();
      const initialName = 'InitialName';
      const updatedName = 'UpdatedName';

      // Act - Initial load
      await userPreferences.setUserName(initialName);
      final name1 = await userPreferences.getUserName();

      // Update data
      await userPreferences.setUserName(updatedName);

      // Refresh (reload)
      final name2 = await userPreferences.getUserName();

      // Assert
      expect(name1, equals(initialName));
      expect(name2, equals(updatedName));
    });
  });
}

class _TestUsernameNotifier extends UsernameNotifier {
  @override
  Future<String> build() async {
    return await UserPreferences().getUserName();
  }

  @override
  Future<void> updateUsername(String newUsername) async {
    state = const AsyncValue.loading();
    await UserPreferences().setUserName(newUsername);
    state = AsyncValue.data(newUsername);
  }
}
