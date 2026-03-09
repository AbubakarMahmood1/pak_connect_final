// Phase 12.16: PairingLifecycleService coverage
// Targets: ensureContactExistsAfterHandshake, cacheSharedSecret,
//          upgradeContactToMediumSecurity, handlePersistentKeyExchange

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/pairing_lifecycle_service.dart';
import 'package:pak_connect/domain/interfaces/i_identity_manager.dart';
import 'package:pak_connect/domain/interfaces/i_security_service.dart';
import 'package:pak_connect/domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';

// ─── Fakes ───────────────────────────────────────────────────────────

class _FakeContactRepository extends Fake implements ContactRepository {
  final Map<String, Contact> contacts = {};
  final Map<String, String> cachedSecrets = {};
  final List<String> savedContacts = [];
  SecurityLevel? lastUpdatedLevel;
  String? lastUpdatedEphemeralId;

  @override
  Future<Contact?> getContactByUserId(UserId userId) async =>
      contacts[userId.value];

  @override
  Future<Contact?> getContact(String publicKey) async =>
      contacts[publicKey];

  @override
  Future<void> saveContactWithSecurity(
    String publicKey,
    String displayName,
    SecurityLevel securityLevel, {
    String? currentEphemeralId,
    String? persistentPublicKey,
  }) async {
    savedContacts.add(publicKey);
    contacts[publicKey] = Contact(
      publicKey: publicKey,
      displayName: displayName,
      trustStatus: TrustStatus.newContact,
      securityLevel: securityLevel,
      firstSeen: DateTime.now(),
      lastSeen: DateTime.now(),
      currentEphemeralId: currentEphemeralId,
      persistentPublicKey: persistentPublicKey,
    );
  }

  @override
  Future<void> updateContactSecurityLevel(
    String publicKey,
    SecurityLevel level,
  ) async {
    lastUpdatedLevel = level;
  }

  @override
  Future<void> updateContactEphemeralId(
    String publicKey,
    String ephemeralId,
  ) async {
    lastUpdatedEphemeralId = ephemeralId;
  }

  @override
  Future<void> cacheSharedSecret(String publicKey, String secret) async {
    cachedSecrets[publicKey] = secret;
  }
}

class _FakeSecurityService extends Fake implements ISecurityService {
  final List<(String, String)> registeredMappings = [];

  @override
  void registerIdentityMapping({
    required String persistentPublicKey,
    required String ephemeralID,
  }) {
    registeredMappings.add((persistentPublicKey, ephemeralID));
  }
}

class _FakeIdentityManager extends Fake implements IIdentityManager {
  String? lastPersistentKey;
  String? lastSessionId;

  @override
  void setTheirPersistentKey(String key, {String? ephemeralId}) {
    lastPersistentKey = key;
  }

  @override
  void setCurrentSessionId(String? sessionId) {
    lastSessionId = sessionId;
  }
}

void main() {
  Logger.root.level = Level.OFF;

  late _FakeContactRepository contactRepo;
  late _FakeSecurityService securityService;
  late _FakeIdentityManager identityManager;
  late IdentitySessionState identityState;
  late Map<String, String> conversationKeys;
  late List<Map<String, String>> migrationCalls;

  late PairingLifecycleService service;

  setUp(() {
    contactRepo = _FakeContactRepository();
    securityService = _FakeSecurityService();
    identityManager = _FakeIdentityManager();
    identityState = IdentitySessionState();
    conversationKeys = {};
    migrationCalls = [];

    service = PairingLifecycleService(
      logger: Logger('Test'),
      contactRepository: contactRepo,
      identityState: identityState,
      conversationKeys: conversationKeys,
      myPersistentIdProvider: () async => 'my-persistent-id',
      triggerChatMigration: ({
        required String ephemeralId,
        required String persistentKey,
        String? contactName,
      }) async {
        migrationCalls.add({
          'ephemeralId': ephemeralId,
          'persistentKey': persistentKey,
          'contactName': ?contactName,
        });
      },
      identityManager: identityManager,
      securityService: securityService,
    );

    SimpleCrypto.clearAllConversationKeys();
  });

  tearDown(() {
    SimpleCrypto.clearAllConversationKeys();
  });

  group('ensureContactExistsAfterHandshake', () {
    test('creates new contact with LOW security when not found', () async {
      await service.ensureContactExistsAfterHandshake(
        'pk-123',
        'Alice',
        ephemeralId: 'eph-456',
      );

      expect(contactRepo.savedContacts, contains('pk-123'));
      expect(contactRepo.contacts['pk-123']?.displayName, 'Alice');
      expect(
        contactRepo.contacts['pk-123']?.securityLevel,
        SecurityLevel.low,
      );
    });

    test('skips when publicKey is empty', () async {
      await service.ensureContactExistsAfterHandshake('', 'Alice');

      expect(contactRepo.savedContacts, isEmpty);
    });

    test('updates ephemeralId for existing contact', () async {
      contactRepo.contacts['pk-123'] = Contact(
        publicKey: 'pk-123',
        displayName: 'Alice',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      );

      await service.ensureContactExistsAfterHandshake(
        'pk-123',
        'Alice',
        ephemeralId: 'new-eph',
      );

      expect(contactRepo.lastUpdatedEphemeralId, 'new-eph');
    });

    test('does not re-save existing contact at LOW or above', () async {
      contactRepo.contacts['pk-123'] = Contact(
        publicKey: 'pk-123',
        displayName: 'Alice',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
      );

      await service.ensureContactExistsAfterHandshake('pk-123', 'Alice');

      // Should not have saved a new contact
      expect(contactRepo.savedContacts, isEmpty);
      // Should not have downgraded
      expect(contactRepo.lastUpdatedLevel, isNull);
    });
  });

  group('cacheSharedSecret', () {
    test('caches secret for contact and initializes conversation', () async {
      await service.cacheSharedSecret(
        contactId: 'contact-pk',
        sharedSecret: 'shared-secret-123',
      );

      expect(conversationKeys['contact-pk'], 'shared-secret-123');
      expect(contactRepo.cachedSecrets['contact-pk'], 'shared-secret-123');
      expect(SimpleCrypto.hasConversationKey('contact-pk'), isTrue);
    });

    test('caches for both contact and alternate session ID', () async {
      await service.cacheSharedSecret(
        contactId: 'contact-pk',
        alternateSessionId: 'alternate-pk',
        sharedSecret: 'secret',
      );

      expect(conversationKeys['contact-pk'], 'secret');
      expect(conversationKeys['alternate-pk'], 'secret');
      expect(contactRepo.cachedSecrets['alternate-pk'], 'secret');
    });

    test('skips when contactId is empty', () async {
      await service.cacheSharedSecret(
        contactId: '',
        sharedSecret: 'secret',
      );

      expect(conversationKeys, isEmpty);
      expect(contactRepo.cachedSecrets, isEmpty);
    });

    test('does not duplicate when alternate == contact', () async {
      await service.cacheSharedSecret(
        contactId: 'same-pk',
        alternateSessionId: 'same-pk',
        sharedSecret: 'secret',
      );

      // Only one entry
      expect(conversationKeys.length, 1);
      expect(conversationKeys['same-pk'], 'secret');
    });
  });

  group('upgradeContactToMediumSecurity', () {
    test('upgrades existing contact and triggers migration', () async {
      contactRepo.contacts['eph-id'] = Contact(
        publicKey: 'eph-id',
        displayName: 'Bob',
        trustStatus: TrustStatus.newContact,
        securityLevel: SecurityLevel.low,
        firstSeen: DateTime.now(),
        lastSeen: DateTime.now(),
        currentEphemeralId: 'eph-id',
      );

      await service.upgradeContactToMediumSecurity(
        theirEphemeralId: 'eph-id',
        theirPersistentKey: 'persistent-key',
        displayName: 'Bob',
      );

      // Contact saved with MEDIUM
      expect(contactRepo.savedContacts, contains('eph-id'));
      expect(
        contactRepo.contacts['eph-id']?.securityLevel,
        SecurityLevel.medium,
      );

      // Identity mapping registered
      expect(securityService.registeredMappings, hasLength(1));
      expect(
        securityService.registeredMappings[0],
        ('persistent-key', 'eph-id'),
      );

      // Chat migration triggered
      expect(migrationCalls, hasLength(1));
      expect(migrationCalls[0]['persistentKey'], 'persistent-key');
    });

    test('returns early when ephemeralId is null', () async {
      await service.upgradeContactToMediumSecurity(
        theirEphemeralId: null,
        theirPersistentKey: 'pk',
      );

      expect(contactRepo.savedContacts, isEmpty);
      expect(migrationCalls, isEmpty);
    });

    test('returns early when ephemeralId is empty', () async {
      await service.upgradeContactToMediumSecurity(
        theirEphemeralId: '',
        theirPersistentKey: 'pk',
      );

      expect(contactRepo.savedContacts, isEmpty);
    });

    test('returns early when contact not found', () async {
      await service.upgradeContactToMediumSecurity(
        theirEphemeralId: 'unknown-eph',
        theirPersistentKey: 'pk',
      );

      expect(migrationCalls, isEmpty);
    });
  });

  group('handlePersistentKeyExchange', () {
    test('returns early when no ephemeral ID in identity state', () async {
      // identityState has no ephemeral ID set
      await service.handlePersistentKeyExchange(
        theirPersistentKey: 'pk',
      );

      expect(identityManager.lastPersistentKey, isNull);
      expect(contactRepo.savedContacts, isEmpty);
    });

    test('sets persistent key on identity state when ephemeral available',
        () async {
      identityState.setTheirEphemeralId('their-eph-id');

      // The method will call EphemeralKeyManager.generateMyEphemeralKey()
      // which requires static initialization. We catch the error path
      // to verify the pre-error behavior is correct.
      try {
        await service.handlePersistentKeyExchange(
          theirPersistentKey: 'their-persistent-key',
          displayName: 'Charlie',
        );
      } catch (_) {
        // EphemeralKeyManager not initialized is expected in unit tests
      }

      // Before the EphemeralKeyManager call, these should have been set
      expect(identityManager.lastPersistentKey, 'their-persistent-key');
      expect(identityManager.lastSessionId, 'their-persistent-key');

      // Security service mapping registered
      expect(securityService.registeredMappings, hasLength(1));

      // Contact saved (happens before generateMyEphemeralKey call)
      expect(contactRepo.savedContacts, contains('their-eph-id'));
    });

    test('uses default display name when null', () async {
      identityState.setTheirEphemeralId('their-eph');

      try {
        await service.handlePersistentKeyExchange(
          theirPersistentKey: 'pk',
          displayName: null,
        );
      } catch (_) {
        // EphemeralKeyManager not initialized is expected
      }

      final savedContact = contactRepo.contacts['their-eph'];
      expect(savedContact?.displayName, 'User');
    });
  });
}
