import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/domain/services/simple_crypto.dart';
import 'package:pak_connect/core/exceptions/encryption_exception.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/models/security_level.dart';

// Simple mock for testing - no external dependencies needed
class _MockContactRepository implements IContactRepository {
  final Contact? _contact;
  final String? _cachedSecret;

  _MockContactRepository({Contact? contact, String? cachedSecret})
    : _contact = contact,
      _cachedSecret = cachedSecret;

  @override
  Future<Contact?> getContactByAnyId(String id) async => _contact;

  @override
  Future<String?> getCachedSharedSecret(String publicKey) async =>
      _cachedSecret;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('Encryption Fail-Open Security Tests', () {
    setUp(() {
      SimpleCrypto.resetDeprecatedWrapperUsageCounts();
    });

    tearDown(() {
      final usage = SimpleCrypto.getDeprecatedWrapperUsageCounts();
      expect(
        usage['total'],
        equals(0),
        reason:
            'Deprecated SimpleCrypto wrappers were used unexpectedly: $usage',
      );
    });

    test('EncryptionException contains proper error information', () {
      // Arrange & Act
      final exception = EncryptionException(
        'Test encryption failed',
        publicKey: 'test_key_1234567890',
        encryptionMethod: 'ECDH',
        cause: Exception('Original error'),
      );

      // Assert
      expect(exception.message, equals('Test encryption failed'));
      expect(exception.publicKey, equals('test_key_1234567890'));
      expect(exception.encryptionMethod, equals('ECDH'));
      expect(exception.cause, isA<Exception>());

      final exceptionString = exception.toString();
      expect(exceptionString, contains('EncryptionException'));
      expect(exceptionString, contains('Test encryption failed'));
      expect(exceptionString, contains('method: ECDH'));
      expect(exceptionString, contains('key: test_key'));
      expect(exceptionString, contains('cause:'));
    });

    test('EncryptionException handles short public keys', () {
      // Arrange & Act
      final exception = EncryptionException(
        'Test error',
        publicKey: 'short',
        encryptionMethod: 'test',
      );

      // Assert - Should not throw on short keys
      expect(exception.toString(), isNotEmpty);
    });

    test('EncryptionException handles null optional fields', () {
      // Arrange & Act
      final exception = EncryptionException('Test error');

      // Assert
      expect(exception.message, equals('Test error'));
      expect(exception.publicKey, isNull);
      expect(exception.encryptionMethod, isNull);
      expect(exception.cause, isNull);

      final exceptionString = exception.toString();
      expect(exceptionString, equals('EncryptionException: Test error'));
    });

    test(
      'encryptMessage throws EncryptionException on global encryption method',
      () async {
        // Arrange
        const testMessage = 'Test message';
        const publicKey = 'test_public_key_12345';

        // Mock contact with LOW security level (no encryption keys)
        final contact = Contact(
          publicKey: publicKey,
          displayName: 'Test Contact',
          securityLevel: SecurityLevel.low,
          trustStatus: TrustStatus.newContact,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        );

        final mockRepo = _MockContactRepository(contact: contact);

        // Act & Assert
        expect(
          () => SecurityManager.instance.encryptMessage(
            testMessage,
            publicKey,
            mockRepo,
          ),
          throwsA(
            isA<EncryptionException>().having(
              (e) => e.encryptionMethod,
              'encryptionMethod',
              'global',
            ),
          ),
        );
      },
    );

    test(
      'encryptBinaryPayload throws EncryptionException when no encryption available',
      () async {
        // Arrange
        final testData = Uint8List.fromList(List<int>.generate(100, (i) => i));
        const publicKey = 'test_public_key_12345';

        // Mock contact with LOW security level (no encryption keys)
        final contact = Contact(
          publicKey: publicKey,
          displayName: 'Test Contact',
          securityLevel: SecurityLevel.low,
          trustStatus: TrustStatus.newContact,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        );

        final mockRepo = _MockContactRepository(contact: contact);

        // Act & Assert - encryptBinaryPayload should throw when no encryption method is available
        expect(
          () => SecurityManager.instance.encryptBinaryPayload(
            testData,
            publicKey,
            mockRepo,
          ),
          throwsA(isA<EncryptionException>()),
        );
      },
    );

    test(
      'encryptBinaryPayload with proper Uint8List type exercises encryption logic',
      () async {
        // Arrange
        final testData = Uint8List.fromList([1, 2, 3, 4, 5]);
        const publicKey = 'test_public_key_12345';

        // Mock contact with LOW security level (triggers global encryption path)
        final contact = Contact(
          publicKey: publicKey,
          displayName: 'Test Contact',
          securityLevel: SecurityLevel.low,
          trustStatus: TrustStatus.newContact,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        );

        final mockRepo = _MockContactRepository(contact: contact);

        // Act & Assert - Should throw EncryptionException (not TypeError)
        // This validates the test now properly exercises the encryption path
        expect(
          () => SecurityManager.instance.encryptBinaryPayload(
            testData,
            publicKey,
            mockRepo,
          ),
          throwsA(
            isA<EncryptionException>().having(
              (e) => e.encryptionMethod,
              'encryptionMethod',
              'global',
            ),
          ),
        );
      },
    );

    test(
      'decryptMessage global fallback uses explicit legacy compatibility path',
      () async {
        // Arrange
        const plaintext = 'legacy inbound message';
        const publicKey = 'test_public_key_12345';

        final contact = Contact(
          publicKey: publicKey,
          displayName: 'Test Contact',
          securityLevel: SecurityLevel.low,
          trustStatus: TrustStatus.newContact,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        );
        final mockRepo = _MockContactRepository(contact: contact);
        final legacyMarkedPayload = SimpleCrypto.encodeLegacyPlaintext(
          plaintext,
        );

        // Act
        final decrypted = await SecurityManager.instance.decryptMessage(
          legacyMarkedPayload,
          publicKey,
          mockRepo,
        );

        // Assert
        expect(decrypted, equals(plaintext));
        final usage = SimpleCrypto.getDeprecatedWrapperUsageCounts();
        expect(usage['encrypt'], equals(0));
        expect(usage['decrypt'], equals(0));
      },
    );

    test(
      'decryptBinaryPayload global fallback uses explicit legacy compatibility path',
      () async {
        // Arrange
        final plaintextBytes = Uint8List.fromList([1, 2, 3, 4, 5, 250, 251]);
        const publicKey = 'test_public_key_12345';

        final contact = Contact(
          publicKey: publicKey,
          displayName: 'Test Contact',
          securityLevel: SecurityLevel.low,
          trustStatus: TrustStatus.newContact,
          firstSeen: DateTime.now(),
          lastSeen: DateTime.now(),
        );
        final mockRepo = _MockContactRepository(contact: contact);
        final legacyMarkedPayload = SimpleCrypto.encodeLegacyPlaintext(
          base64.encode(plaintextBytes),
        );
        final encryptedInput = Uint8List.fromList(
          utf8.encode(legacyMarkedPayload),
        );

        // Act
        final decrypted = await SecurityManager.instance.decryptBinaryPayload(
          encryptedInput,
          publicKey,
          mockRepo,
        );

        // Assert
        expect(decrypted, equals(plaintextBytes));
        final usage = SimpleCrypto.getDeprecatedWrapperUsageCounts();
        expect(usage['encrypt'], equals(0));
        expect(usage['decrypt'], equals(0));
      },
    );
  });
}
