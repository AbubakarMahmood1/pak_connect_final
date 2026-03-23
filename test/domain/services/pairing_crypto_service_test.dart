import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pointycastle/export.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/services/pairing_crypto_service.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';

class _FakeContactRepository extends Fake implements IContactRepository {
  final Map<String, String> cachedSecrets = <String, String>{};
  final List<String> clearedSecretIds = <String>[];

  @override
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    cachedSecrets[publicKey] = sharedSecret;
  }

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async {
    return cachedSecrets[publicKey];
  }

  @override
  Future<void> clearCachedSecrets(String publicKey) async {
    cachedSecrets.remove(publicKey);
    clearedSecretIds.add(publicKey);
  }
}

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _publicKeyHexFromPrivateInt(int privateValue) {
  final curve = ECCurve_secp256r1();
  final publicPoint = curve.G * BigInt.from(privateValue);
  return _bytesToHex(publicPoint!.getEncoded(false));
}

void _initializeSigningForTests() {
  final privateKey = BigInt.from(42);
  final privateKeyHex = privateKey.toRadixString(16).padLeft(64, '0');
  final publicKeyHex = _publicKeyHexFromPrivateInt(42);
  SimpleCrypto.initializeSigning(privateKeyHex, publicKeyHex);
}

void main() {
  Logger.root.level = Level.OFF;

  late _FakeContactRepository contactRepository;
  late Map<String, String> runtimeSecrets;
  late PairingCryptoService service;

  setUp(() {
    SimpleCrypto.clear();
    SimpleCrypto.clearAllConversationKeys();
    contactRepository = _FakeContactRepository();
    runtimeSecrets = <String, String>{};
    service = PairingCryptoService(
      logger: Logger('PairingCryptoServiceTest'),
      contactRepository: contactRepository,
      runtimeConversationSecrets: runtimeSecrets,
    );
  });

  tearDown(() {
    SimpleCrypto.clear();
    SimpleCrypto.clearAllConversationKeys();
  });

  test('cacheSharedSecret seeds contact and alternate runtime lanes', () async {
    await service.cacheSharedSecret(
      contactId: 'contact-pk',
      alternateSessionId: 'alternate-pk',
      sharedSecret: 'shared-secret',
    );

    expect(runtimeSecrets['contact-pk'], 'shared-secret');
    expect(runtimeSecrets['alternate-pk'], 'shared-secret');
    expect(contactRepository.cachedSecrets['contact-pk'], 'shared-secret');
    expect(contactRepository.cachedSecrets['alternate-pk'], 'shared-secret');
    expect(service.hasConversationKey('contact-pk'), isTrue);
    expect(service.hasConversationKey('alternate-pk'), isTrue);
  });

  test(
    'restoreConversationFromCachedSecret restores cached runtime lane',
    () async {
      contactRepository.cachedSecrets['peer-pk'] = 'cached-secret';

      final restored = await service.restoreConversationFromCachedSecret(
        'peer-pk',
      );

      expect(restored, isTrue);
      expect(runtimeSecrets['peer-pk'], 'cached-secret');
      expect(service.hasConversationKey('peer-pk'), isTrue);
    },
  );

  test(
    'initializePairingConversationFromCachedSecret derives medium-security seed',
    () async {
      contactRepository.cachedSecrets['peer-pk'] = 'pairing-secret';

      final initialized = await service
          .initializePairingConversationFromCachedSecret(
            contactId: 'peer-pk',
            myPersistentIdProvider: () async => 'my-persistent-id',
          );

      expect(initialized, isTrue);
      expect(
        runtimeSecrets['peer-pk'],
        'pairing-secretmy-persistent-idpeer-pk',
      );
      expect(service.hasConversationKey('peer-pk'), isTrue);
    },
  );

  test('computeAndCacheSharedSecret derives and stores ECDH secret', () async {
    _initializeSigningForTests();
    final peerPublicKey = _publicKeyHexFromPrivateInt(99);

    final sharedSecret = await service.computeAndCacheSharedSecret(
      peerPublicKey,
    );

    expect(sharedSecret, isNotNull);
    expect(contactRepository.cachedSecrets[peerPublicKey], sharedSecret);
    expect(runtimeSecrets[peerPublicKey], sharedSecret);
    expect(service.hasConversationKey(peerPublicKey), isTrue);
  });

  test('clearConversationState clears runtime and cached secrets', () async {
    await service.cacheSharedSecret(
      contactId: 'contact-pk',
      alternateSessionId: 'alternate-pk',
      sharedSecret: 'shared-secret',
    );

    await service.clearConversationState(<String>[
      'contact-pk',
      'alternate-pk',
    ]);

    expect(runtimeSecrets, isEmpty);
    expect(contactRepository.cachedSecrets, isEmpty);
    expect(
      contactRepository.clearedSecretIds,
      containsAll(<String>['contact-pk', 'alternate-pk']),
    );
    expect(service.hasConversationKey('contact-pk'), isFalse);
    expect(service.hasConversationKey('alternate-pk'), isFalse);
  });
}
