import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/services/crypto_verification_service.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';

void main() {
  group('CryptoVerificationService', () {
    late _FakeContactRepository repository;

    setUp(() {
      repository = _FakeContactRepository();
      SimpleCrypto.initialize();
      _initializeSigningForTests();
    });

    tearDown(() {
      SimpleCrypto.clear();
      SimpleCrypto.clearAllConversationKeys();
    });

    test('generateVerificationChallenge returns expected tagged format', () {
      final challenge =
          CryptoVerificationService.generateVerificationChallenge();

      expect(challenge, startsWith('CRYPTO_VERIFY_'));
      final parts = challenge.split('_');
      expect(parts.length, 4);
      expect(int.tryParse(parts[2]), isNotNull);
      expect(parts[3].length, 4);
    });

    test('verifyCryptoStandards returns detailed results map', () async {
      final results = await CryptoVerificationService.verifyCryptoStandards(
        null,
        null,
      );

      expect(results['timestamp'], isA<String>());
      expect(results['tests'], isA<Map<String, dynamic>>());
      final tests = results['tests'] as Map<String, dynamic>;
      expect(tests.containsKey('ecdhKeyGeneration'), isTrue);
      expect(tests.containsKey('conversationEncryption'), isTrue);
      expect(tests.containsKey('enhancedKeyDerivation'), isTrue);
      expect(tests.containsKey('messageSigning'), isTrue);
      expect(results['overallSuccess'], isA<bool>());
    });

    test(
      'verifyCryptoStandards includes keyStorage and ecdhSharedSecret branches',
      () async {
        final results = await CryptoVerificationService.verifyCryptoStandards(
          'not_a_valid_public_key',
          repository,
        );

        final tests = results['tests'] as Map<String, dynamic>;
        expect(tests['keyStorage'], isA<Map>());
        expect((tests['keyStorage'] as Map)['success'], isTrue);
        expect(tests['ecdhSharedSecret'], isA<Map>());
        expect((tests['ecdhSharedSecret'] as Map)['success'], isFalse);
        expect(results['overallSuccess'], isFalse);
      },
    );

    test(
      'verifyCryptoStandards reports signing failure when signing is not ready',
      () async {
        SimpleCrypto.clear();
        SimpleCrypto.initialize();

        final results = await CryptoVerificationService.verifyCryptoStandards(
          null,
          null,
        );
        final tests = results['tests'] as Map<String, dynamic>;

        expect((tests['messageSigning'] as Map)['success'], isFalse);
        expect(results['overallSuccess'], isFalse);
      },
    );

    test(
      'testBidirectionalEncryption returns failure result for invalid contact key',
      () async {
        final result =
            await CryptoVerificationService.testBidirectionalEncryption(
              'not_a_valid_public_key',
              repository,
              'hello world',
            );

        expect(result['testName'], 'Bidirectional Encryption');
        expect(result['success'], isFalse);
        expect(result['error'], isA<String>());
      },
    );
  });
}

class _FakeContactRepository implements IContactRepository {
  final Map<String, String> _secrets = {};

  @override
  Future<void> cacheSharedSecret(String publicKey, String sharedSecret) async {
    _secrets[publicKey] = sharedSecret;
  }

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async {
    return _secrets[publicKey];
  }

  @override
  Future<void> clearCachedSecrets(String publicKey) async {
    _secrets.remove(publicKey);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void _initializeSigningForTests() {
  final curve = ECCurve_secp256r1();
  final privateKey = BigInt.from(42);
  final publicPoint = curve.G * privateKey;
  final privateKeyHex = privateKey.toRadixString(16).padLeft(64, '0');
  final publicKeyHex = _bytesToHex(publicPoint!.getEncoded(false));

  SimpleCrypto.initializeSigning(privateKeyHex, publicKeyHex);
}

String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
