import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/ephemeral_discovery_hint.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/hint_scanner_service.dart';
import 'package:pak_connect/domain/utils/hint_advertisement_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

import '../../data/services/ble_messaging_service_test.mocks.dart';

class _FakeMessageRepository implements IMessageRepository {
  @override
  Future<void> clearMessages(ChatId chatId) async {}

  @override
  Future<bool> deleteMessage(MessageId messageId) async => false;

  @override
  Future<List<Message>> getAllMessages() async => <Message>[];

  @override
  Future<Message?> getMessageById(MessageId messageId) async => null;

  @override
  Future<List<Message>> getMessages(ChatId chatId) async => <Message>[];

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      <Message>[];

  @override
  Future<void> migrateChatId(ChatId oldChatId, ChatId newChatId) async {}

  @override
  Future<void> saveMessage(Message message) async {}

  @override
  Future<void> updateMessage(Message message) async {}
}

class _FakeRepositoryProvider implements IRepositoryProvider {
  _FakeRepositoryProvider({
    required this.contactRepository,
    required this.messageRepository,
  });

  @override
  final MockContactRepository contactRepository;

  @override
  final IMessageRepository messageRepository;
}

Contact _buildContact({
  required String publicKey,
  String? persistentPublicKey,
  required String displayName,
}) {
  final now = DateTime.now();
  return Contact(
    publicKey: publicKey,
    persistentPublicKey: persistentPublicKey,
    displayName: displayName,
    trustStatus: TrustStatus.verified,
    securityLevel: SecurityLevel.high,
    firstSeen: now,
    lastSeen: now,
  );
}

Uint8List _buildAdvertisement({
  required String identifier,
  required Uint8List nonce,
  required bool isIntro,
}) {
  final hintBytes = HintAdvertisementService.computeHintBytes(
    identifier: identifier,
    nonce: nonce,
  );
  return HintAdvertisementService.packAdvertisement(
    nonce: nonce,
    hintBytes: hintBytes,
    isIntro: isIntro,
  );
}

void main() {
  group('HintScannerService', () {
    late _FakeRepositoryProvider repositoryProvider;
    late MockContactRepository contactRepository;
    late HintScannerService scanner;

    setUp(() {
      resetMockitoState();
      HintScannerService.clearRepositoryProvider();

      contactRepository = MockContactRepository();
      when(
        contactRepository.getAllContacts(),
      ).thenAnswer((_) async => <String, Contact>{});

      repositoryProvider = _FakeRepositoryProvider(
        contactRepository: contactRepository,
        messageRepository: _FakeMessageRepository(),
      );

      scanner = HintScannerService(repositoryProvider: repositoryProvider);
    });

    tearDown(() {
      scanner.dispose();
      HintScannerService.clearRepositoryProvider();
    });

    test('initialize preloads contacts into cache', () async {
      final alice = _buildContact(
        publicKey: 'alice-public',
        displayName: 'Alice',
      );
      final bob = _buildContact(publicKey: 'bob-public', displayName: 'Bob');

      when(contactRepository.getAllContacts()).thenAnswer(
        (_) async => <String, Contact>{
          alice.publicKey: alice,
          bob.publicKey: bob,
        },
      );

      await scanner.initialize();

      final stats = scanner.getStatistics();
      expect(stats['cached_contacts'], 2);
      expect(stats['active_intros'], 0);
      verify(contactRepository.getAllContacts()).called(1);
    });

    test(
      'checkDevice returns stranger when advertisement cannot be parsed',
      () async {
        final result = await scanner.checkDevice(
          Uint8List.fromList(<int>[1, 2, 3]),
        );
        expect(result.isStranger, isTrue);
      },
    );

    test(
      'checkDevice lazily rebuilds cache and matches known contact hint',
      () async {
        final peer = _buildContact(
          publicKey: 'peer-public',
          displayName: 'Peer',
        );
        when(
          contactRepository.getAllContacts(),
        ).thenAnswer((_) async => <String, Contact>{peer.publicKey: peer});

        final nonce = Uint8List.fromList(<int>[0x01, 0x9A]);
        final advertisement = _buildAdvertisement(
          identifier: peer.publicKey,
          nonce: nonce,
          isIntro: false,
        );

        final result = await scanner.checkDevice(advertisement);

        expect(result.isContact, isTrue);
        expect(result.contactPublicKey, peer.publicKey);
        expect(result.contactName, 'Peer');
        verify(contactRepository.getAllContacts()).called(1);
      },
    );

    test(
      'checkDevice matches contact using persistent identity when present',
      () async {
        final peer = _buildContact(
          publicKey: 'peer-public',
          persistentPublicKey: 'peer-persistent',
          displayName: 'Peer Persistent',
        );
        when(
          contactRepository.getAllContacts(),
        ).thenAnswer((_) async => <String, Contact>{peer.publicKey: peer});
        await scanner.initialize();

        final nonce = Uint8List.fromList(<int>[0xAA, 0x55]);
        final advertisement = _buildAdvertisement(
          identifier: 'peer-persistent',
          nonce: nonce,
          isIntro: false,
        );

        final result = await scanner.checkDevice(advertisement);

        expect(result.isContact, isTrue);
        expect(result.contactPublicKey, peer.publicKey);
        expect(result.contactName, 'Peer Persistent');
      },
    );

    test('checkDevice matches active intro hint payload', () async {
      final intro = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
        createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        displayName: 'QR Friend',
      );
      scanner.addActiveIntroHint(intro);

      final nonce = Uint8List.fromList(<int>[0x0F, 0x0E]);
      final advertisement = _buildAdvertisement(
        identifier: intro.hintHex,
        nonce: nonce,
        isIntro: true,
      );

      final result = await scanner.checkDevice(advertisement);

      expect(result.isIntro, isTrue);
      expect(result.introHint, intro);
    });

    test('cleanupExpiredIntros and removeIntroHint prune intro cache', () {
      final expiredHint = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList(<int>[9, 9, 9, 9, 9, 9, 9, 9]),
        createdAt: DateTime.now().subtract(const Duration(days: 2)),
        expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
        displayName: 'Expired',
      );
      final activeHint = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList(<int>[8, 8, 8, 8, 8, 8, 8, 8]),
        createdAt: DateTime.now().subtract(const Duration(minutes: 10)),
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        displayName: 'Active',
      );

      scanner.addActiveIntroHint(expiredHint);
      scanner.addActiveIntroHint(activeHint);

      scanner.cleanupExpiredIntros();
      expect(scanner.getStatistics()['active_intros'], 1);

      scanner.removeIntroHint(activeHint.hintHex);
      expect(scanner.getStatistics()['active_intros'], 0);
    });

    test('clearCaches resets contact and intro caches', () async {
      final peer = _buildContact(publicKey: 'peer-public', displayName: 'Peer');
      when(
        contactRepository.getAllContacts(),
      ).thenAnswer((_) async => <String, Contact>{peer.publicKey: peer});
      await scanner.initialize();

      final intro = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList(<int>[7, 7, 7, 7, 7, 7, 7, 7]),
        createdAt: DateTime.now().subtract(const Duration(minutes: 1)),
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        displayName: 'Intro',
      );
      scanner.addActiveIntroHint(intro);

      scanner.clearCaches();

      final stats = scanner.getStatistics();
      expect(stats['cached_contacts'], 0);
      expect(stats['active_intros'], 0);
    });

    test('falls back to configured static repository provider', () async {
      when(
        contactRepository.getAllContacts(),
      ).thenAnswer((_) async => <String, Contact>{});

      HintScannerService.configureRepositoryProvider(repositoryProvider);
      expect(HintScannerService.hasConfiguredRepositoryProvider, isTrue);

      final configuredScanner = HintScannerService();
      await configuredScanner.initialize();

      expect(configuredScanner.getStatistics()['cached_contacts'], 0);
      configuredScanner.dispose();

      HintScannerService.clearRepositoryProvider();
      expect(HintScannerService.hasConfiguredRepositoryProvider, isFalse);
    });

    test('initialize without repository provider leaves cache empty', () async {
      final noProviderScanner = HintScannerService(repositoryProvider: null);

      await noProviderScanner.initialize();

      expect(noProviderScanner.getStatistics()['cached_contacts'], 0);
      expect(noProviderScanner.getStatistics()['active_intros'], 0);
      noProviderScanner.dispose();
    });

    test('HintMatchResult helpers and string labels stay consistent', () {
      final intro = EphemeralDiscoveryHint(
        hintBytes: Uint8List.fromList(<int>[3, 3, 3, 3, 3, 3, 3, 3]),
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 1)),
        displayName: 'Intro Name',
      );

      final contact = HintMatchResult.contact(
        publicKey: 'peer-public',
        name: 'Peer Name',
      );
      final introMatch = HintMatchResult.intro(hint: intro);
      final stranger = HintMatchResult.stranger();

      expect(contact.isContact, isTrue);
      expect(introMatch.isIntro, isTrue);
      expect(stranger.isStranger, isTrue);
      expect(contact.toString(), contains('Peer Name'));
      expect(introMatch.toString(), contains('Intro Name'));
      expect(stranger.toString(), 'Stranger');
    });
  });
}
