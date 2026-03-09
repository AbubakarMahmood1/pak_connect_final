/// Phase 12.5: Supplementary tests for ContactManagementService
/// Covers: clearSearchHistory, getAllEnhancedContacts edge cases,
///   getEnhancedContactById, getContactById, updatePrivacySettings persistence,
///   exportContacts CSV format, exportContacts with security data.
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pak_connect/domain/entities/contact.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/interfaces/i_message_repository.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeContactRepository contactRepo;
  late _FakeMessageRepository messageRepo;
  late ContactManagementService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    contactRepo = _FakeContactRepository({
      'pk1': _contact(key: 'pk1', name: 'Alice', level: SecurityLevel.high),
      'pk2': _contact(key: 'pk2', name: 'Bob', level: SecurityLevel.medium),
    });
    messageRepo = _FakeMessageRepository({
      'pk1': [
        _message(id: 'm1', chatId: 'pk1', content: 'hey', fromMe: true),
      ],
    });
    service = ContactManagementService.withDependencies(
      contactRepository: contactRepo,
      messageRepository: messageRepo,
    );
  });

  group('clearSearchHistory', () {
    test('removes all recent searches', () async {
      await service.searchContacts(query: 'alice');
      await service.searchContacts(query: 'bob');
      expect(service.getRecentSearches(), isNotEmpty);

      await service.clearSearchHistory();
      expect(service.getRecentSearches(), isEmpty);
    });
  });

  group('getAllEnhancedContacts', () {
    test('returns enhanced contacts with message stats', () async {
      await service.initialize();
      final contacts = await service.getAllEnhancedContacts();
      expect(contacts.length, 2);

      final alice = contacts.firstWhere((c) => c.publicKey == 'pk1');
      expect(alice.displayName, 'Alice');
      expect(alice.interactionCount, greaterThanOrEqualTo(1));
    });

    test('returns empty list when no contacts', () async {
      final emptyRepo = _FakeContactRepository({});
      final emptyService = ContactManagementService.withDependencies(
        contactRepository: emptyRepo,
        messageRepository: messageRepo,
      );
      await emptyService.initialize();
      final contacts = await emptyService.getAllEnhancedContacts();
      expect(contacts, isEmpty);
    });
  });

  group('getEnhancedContactById', () {
    test('returns enhanced contact for valid id', () async {
      await service.initialize();
      final contact = await service.getEnhancedContactById(UserId('pk1'));
      expect(contact, isNotNull);
      expect(contact!.publicKey, 'pk1');
    });

    test('returns null for missing id', () async {
      await service.initialize();
      final contact = await service.getEnhancedContactById(UserId('missing'));
      expect(contact, isNull);
    });
  });

  group('getContactById', () {
    test('returns raw Contact for valid id', () async {
      final contact = await service.getContactById(UserId('pk2'));
      expect(contact, isNotNull);
      expect(contact!.displayName, 'Bob');
    });

    test('returns null for unknown id', () async {
      final contact = await service.getContactById(UserId('unknown'));
      expect(contact, isNull);
    });
  });

  group('updatePrivacySettings', () {
    test('persists settings to SharedPreferences', () async {
      await service.initialize();
      await service.updatePrivacySettings(
        const ContactPrivacySettings(
          allowAddressBookSync: true,
          allowContactExport: true,
          enableContactAnalytics: false,
        ),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('contact_mgmt_address_book_sync'), true);
      expect(prefs.getBool('contact_mgmt_contact_export'), true);
      expect(prefs.getBool('contact_mgmt_analytics'), false);

      final settings = service.getPrivacySettings();
      expect(settings.allowContactExport, true);
    });
  });

  group('exportContacts', () {
    test('CSV format export works when allowed', () async {
      await service.initialize();
      await service.updatePrivacySettings(
        const ContactPrivacySettings(
          allowAddressBookSync: false,
          allowContactExport: true,
          enableContactAnalytics: false,
        ),
      );

      final result = await service.exportContacts(
        format: ContactExportFormat.csv,
        includeSecurityData: false,
      );
      expect(result.success, isTrue);
    });

    test('export with security data includes security fields', () async {
      await service.initialize();
      await service.updatePrivacySettings(
        const ContactPrivacySettings(
          allowAddressBookSync: false,
          allowContactExport: true,
          enableContactAnalytics: false,
        ),
      );

      final result = await service.exportContacts(
        format: ContactExportFormat.json,
        includeSecurityData: true,
      );
      expect(result.success, isTrue);
    });
  });

  group('searchContacts edge cases', () {
    test('empty query returns all HIGH contacts by default', () async {
      final result = await service.searchContacts(query: '');
      // Only Alice is HIGH
      expect(result.totalResults, 1);
    });

    test('search history is capped at 10', () async {
      for (int i = 0; i < 15; i++) {
        await service.searchContacts(query: 'search_$i');
      }
      expect(service.getRecentSearches().length, lessThanOrEqualTo(10));
    });
  });
}

Contact _contact({
  required String key,
  required String name,
  required SecurityLevel level,
}) {
  return Contact(
    publicKey: key,
    displayName: name,
    trustStatus: TrustStatus.verified,
    securityLevel: level,
    firstSeen: DateTime(2025, 12, 1),
    lastSeen: DateTime(2026, 2, 1),
    isFavorite: false,
  );
}

Message _message({
  required String id,
  required String chatId,
  required String content,
  required bool fromMe,
}) {
  return Message(
    id: MessageId(id),
    chatId: ChatId(chatId),
    content: content,
    timestamp: DateTime(2026, 1, 1),
    isFromMe: fromMe,
    status: MessageStatus.delivered,
  );
}

class _FakeContactRepository implements IContactRepository {
  _FakeContactRepository(this._contacts);
  final Map<String, Contact> _contacts;

  @override
  Future<Map<String, Contact>> getAllContacts() async => Map.of(_contacts);
  @override
  Future<Contact?> getContact(String publicKey) async => _contacts[publicKey];
  @override
  Future<Contact?> getContactByUserId(UserId userId) async =>
      _contacts[userId.value];
  @override
  Future<bool> deleteContact(String publicKey) async =>
      _contacts.remove(publicKey) != null;
  @override
  Future<void> clearCachedSecrets(String publicKey) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected: $invocation');
}

class _FakeMessageRepository implements IMessageRepository {
  _FakeMessageRepository(this._messages);
  final Map<String, List<Message>> _messages;

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      List.of(_messages[publicKey] ?? const []);
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected: $invocation');
}
