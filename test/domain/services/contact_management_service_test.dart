import 'dart:convert';

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

  group('ContactManagementService', () {
    late _FakeContactRepository contactRepository;
    late _FakeMessageRepository messageRepository;
    late ContactManagementService service;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      contactRepository = _FakeContactRepository({
        'pub_high': _contact(
          key: 'pub_high',
          name: 'Alice',
          trustStatus: TrustStatus.verified,
          securityLevel: SecurityLevel.high,
        ),
        'pub_medium': _contact(
          key: 'pub_medium',
          name: 'Bob',
          trustStatus: TrustStatus.newContact,
          securityLevel: SecurityLevel.medium,
        ),
        'pub_low': _contact(
          key: 'pub_low',
          name: 'Carol',
          trustStatus: TrustStatus.keyChanged,
          securityLevel: SecurityLevel.low,
        ),
      });
      messageRepository = _FakeMessageRepository({
        'pub_high': [
          _message(
            id: 'm1',
            chatId: 'pub_high',
            content: 'hi',
            fromMe: true,
            timestamp: DateTime(2026, 1, 1, 10),
          ),
          _message(
            id: 'm2',
            chatId: 'pub_high',
            content: 'hello',
            fromMe: false,
            timestamp: DateTime(2026, 1, 1, 10, 3),
          ),
        ],
        'pub_medium': [
          _message(
            id: 'm3',
            chatId: 'pub_medium',
            content: 'medium contact message',
            fromMe: false,
            timestamp: DateTime(2026, 1, 2, 9),
          ),
        ],
      });
      service = ContactManagementService.withDependencies(
        contactRepository: contactRepository,
        messageRepository: messageRepository,
      );
    });

    test('initialize loads persisted settings/search/groups and is idempotent', () async {
      final persistedGroup = jsonEncode({
        'id': 'group_1',
        'name': 'Persisted',
        'description': 'Loaded from prefs',
        'member_public_keys': ['pub_high'],
        'created_at': DateTime(2026, 1, 1).millisecondsSinceEpoch,
        'last_modified': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      });

      SharedPreferences.setMockInitialValues({
        'contact_mgmt_address_book_sync': true,
        'contact_mgmt_contact_export': false,
        'contact_mgmt_analytics': true,
        'contact_search_history': ['older', 'newer'],
        'contact_groups': [persistedGroup],
      });

      service = ContactManagementService.withDependencies(
        contactRepository: contactRepository,
        messageRepository: messageRepository,
      );

      await service.initialize();
      await service.initialize();

      final settings = service.getPrivacySettings();
      expect(settings.allowAddressBookSync, isTrue);
      expect(settings.allowContactExport, isFalse);
      expect(settings.enableContactAnalytics, isTrue);
      expect(service.getRecentSearches(), ['newer', 'older']);

      final enhanced = await service.getEnhancedContact('pub_high');
      expect(enhanced, isNotNull);
      expect(enhanced!.groupMemberships, contains('Persisted'));
    });

    test('searchContacts defaults to HIGH-security contacts and tracks history', () async {
      final result = await service.searchContacts(query: 'alice');

      expect(result.totalResults, 1);
      expect(result.contacts.single.publicKey, 'pub_high');
      expect(service.getRecentSearches().first, 'alice');
    });

    test('searchContacts filter overrides default HIGH-only behavior', () async {
      final result = await service.searchContacts(
        query: '',
        filter: const ContactSearchFilter(securityLevel: SecurityLevel.medium),
      );

      expect(result.totalResults, 1);
      expect(result.contacts.single.publicKey, 'pub_medium');
    });

    test('createContactGroup prevents duplicates and addContactToGroup updates memberships', () async {
      final created = await service.createContactGroup(
        name: 'Friends',
        description: 'Trusted contacts',
      );
      expect(created.success, isTrue);

      final duplicate = await service.createContactGroup(
        name: 'Friends',
        description: 'Duplicate',
      );
      expect(duplicate.success, isFalse);

      final added = await service.addContactToGroup('pub_high', 'Friends');
      expect(added.success, isTrue);

      final enhanced = await service.getEnhancedContact('pub_high');
      expect(enhanced, isNotNull);
      expect(enhanced!.groupMemberships, contains('Friends'));
    });

    test('deleteContactById clears secrets, removes from groups, and deletes contact', () async {
      await service.createContactGroup(
        name: 'Team',
        description: 'Project team',
        memberPublicKeys: const ['pub_high'],
      );

      final deleted = await service.deleteContactById(UserId('pub_high'));
      expect(deleted.success, isTrue);
      expect(contactRepository.deletedPublicKeys, contains('pub_high'));
      expect(contactRepository.clearedSecretsFor, contains('pub_high'));
      expect(await service.getEnhancedContact('pub_high'), isNull);
    });

    test('deleteContacts reports mixed successes and failures', () async {
      final bulk = await service.deleteContacts([
        'pub_high',
        'pub_missing',
        'pub_medium',
      ]);

      expect(bulk.totalOperations, 3);
      expect(bulk.successCount, 2);
      expect(bulk.failureCount, 1);
      expect(bulk.failedItems, ['pub_missing']);
    });

    test('exportContacts is blocked by privacy settings and succeeds when enabled', () async {
      final blocked = await service.exportContacts();
      expect(blocked.success, isFalse);

      await service.updatePrivacySettings(
        const ContactPrivacySettings(
          allowAddressBookSync: false,
          allowContactExport: true,
          enableContactAnalytics: false,
        ),
      );

      final exported = await service.exportContacts(
        format: ContactExportFormat.json,
        includeSecurityData: false,
      );
      expect(exported.success, isTrue);

      final prefs = await SharedPreferences.getInstance();
      final exports = prefs.getStringList('contact_exports');
      expect(exports, isNotNull);
      expect(exports, isNotEmpty);

      final metadata = jsonDecode(exports!.last) as Map<String, dynamic>;
      final exportedData = prefs.getString(metadata['key'] as String);
      expect(exportedData, isNotNull);
      expect(exportedData!, contains('[REDACTED]'));
    });

    test('getContactAnalytics aggregates trust/security distribution', () async {
      final analytics = await service.getContactAnalytics();

      expect(analytics.totalContacts, 3);
      expect(analytics.verifiedContacts, 1);
      expect(analytics.highSecurityContacts, 1);
      expect(analytics.securityLevelDistribution[SecurityLevel.medium], 1);
      expect(analytics.trustStatusDistribution[TrustStatus.keyChanged], 1);
      expect(analytics.averageContactAge, isNot(Duration.zero));
    });
  });
}

Contact _contact({
  required String key,
  required String name,
  required TrustStatus trustStatus,
  required SecurityLevel securityLevel,
}) {
  return Contact(
    publicKey: key,
    displayName: name,
    trustStatus: trustStatus,
    securityLevel: securityLevel,
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
  required DateTime timestamp,
}) {
  return Message(
    id: MessageId(id),
    chatId: ChatId(chatId),
    content: content,
    timestamp: timestamp,
    isFromMe: fromMe,
    status: MessageStatus.delivered,
  );
}

class _FakeContactRepository implements IContactRepository {
  _FakeContactRepository(this._contacts);

  final Map<String, Contact> _contacts;
  final List<String> deletedPublicKeys = [];
  final List<String> clearedSecretsFor = [];

  @override
  Future<Map<String, Contact>> getAllContacts() async => Map.of(_contacts);

  @override
  Future<Contact?> getContact(String publicKey) async => _contacts[publicKey];

  @override
  Future<Contact?> getContactByUserId(UserId userId) async =>
      _contacts[userId.value];

  @override
  Future<bool> deleteContact(String publicKey) async {
    deletedPublicKeys.add(publicKey);
    return _contacts.remove(publicKey) != null;
  }

  @override
  Future<void> clearCachedSecrets(String publicKey) async {
    clearedSecretsFor.add(publicKey);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected method call: $invocation');
}

class _FakeMessageRepository implements IMessageRepository {
  _FakeMessageRepository(this._messagesByContact);

  final Map<String, List<Message>> _messagesByContact;

  @override
  Future<List<Message>> getMessagesForContact(String publicKey) async =>
      List.of(_messagesByContact[publicKey] ?? const []);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Unexpected method call: $invocation');
}
