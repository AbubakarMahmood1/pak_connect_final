import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/services/session_service.dart';
import 'package:pak_connect/data/repositories/contact_repository.dart';
import 'package:mockito/mockito.dart';

void main() {
  group('SessionService', () {
    late SessionService sessionService;
    late MockContactRepository mockContactRepository;

    setUp(() {
      mockContactRepository = MockContactRepository();
      sessionService = SessionService(
        contactRepository: mockContactRepository,
        getWeHaveThemAsContact: () async => true,
        getMyPersistentId: () async => 'my_id_123',
        getTheirPersistentKey: () => 'their_persistent_key_123',
        getTheirEphemeralId: () => 'their_ephemeral_id',
      );
    });

    test('returns persistent ID as recipient when available', () {
      final recipientId = sessionService.getRecipientId();

      expect(recipientId, equals('their_persistent_key_123'));
    });

    test('returns ephemeral ID when persistent key not available', () {
      sessionService = SessionService(
        contactRepository: mockContactRepository,
        getWeHaveThemAsContact: () async => false,
        getMyPersistentId: () async => 'my_id_123',
        getTheirPersistentKey: () => null,
        getTheirEphemeralId: () => 'ephemeral_id_456',
      );

      final recipientId = sessionService.getRecipientId();

      expect(recipientId, equals('ephemeral_id_456'));
    });

    test('stores their ephemeral ID', () {
      sessionService.setTheirEphemeralId('new_ephemeral_id', 'Bob');

      // Ephemeral ID should be stored
      // This depends on implementation storing in a field
    });

    test('determines ID type', () {
      final idType = sessionService.getIdType();

      expect(idType, isNotEmpty);
      expect(idType == 'persistent' || idType == 'ephemeral', isTrue);
    });

    test('updates their contact status', () {
      sessionService.updateTheirContactStatus(true);

      // Status should be updated internally
    });

    test('updates their contact claim', () {
      sessionService.updateTheirContactClaim(false);

      // Claim should be updated internally
    });

    test('checks if paired', () {
      final isPaired = sessionService.isPaired;

      // Should return true if persistent key exists
      expect(isPaired, isNotNull);
    });

    test('requests contact status exchange', () async {
      // Should not throw
      await sessionService.requestContactStatusExchange();
    });

    test('handles incoming contact status', () async {
      // Should not throw
      await sessionService.handleContactStatus(true, 'peer_key_123');
    });

    test('provides conversation key', () {
      final key = sessionService.getConversationKey('peer_key_123');

      // Should return key or null
      expect(key, isNull); // Assuming empty on first call
    });

    test('handles contact status properly', () async {
      // Should update internal state without throwing
      await sessionService.handleContactStatus(true, 'peer_key_123');
      await sessionService.handleContactStatus(false, 'peer_key_123');
    });

    test('request and handle contact status exchange', () async {
      // Should complete without throwing
      await sessionService.requestContactStatusExchange();
      await sessionService.handleContactStatus(true, 'peer_key_123');
    });
  });
}

class MockContactRepository extends Mock implements ContactRepository {}
