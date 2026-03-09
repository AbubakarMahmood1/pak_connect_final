
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/enhanced_contact.dart';
import 'package:pak_connect/domain/interfaces/i_contact_repository.dart';
import 'package:pak_connect/domain/models/security_level.dart';
import 'package:pak_connect/domain/services/contact_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/presentation/providers/contact_provider.dart';

class _FakeContactManagementService extends Fake
    implements ContactManagementService {
  int getEnhancedContactByIdCalls = 0;
  final List<String> deletedContactIds = <String>[];
  ContactOperationResult deleteResult = ContactOperationResult.success('ok');
  final Map<String, EnhancedContact?> contactsById =
      <String, EnhancedContact?>{};

  @override
  Future<void> initialize() async {}

  @override
  Future<List<EnhancedContact>> getAllEnhancedContacts() async => const [];

  @override
  Future<EnhancedContact?> getEnhancedContactById(UserId userId) async {
    getEnhancedContactByIdCalls++;
    return contactsById[userId.value];
  }

  @override
  Future<ContactSearchResult> searchContacts({
    required String query,
    ContactSearchFilter? filter,
    ContactSortOption sortBy = ContactSortOption.name,
    bool ascending = true,
  }) async {
    return ContactSearchResult(
      contacts: const [],
      query: query,
      totalResults: 0,
      searchTime: Duration.zero,
      appliedFilter: filter,
      sortedBy: sortBy,
      ascending: ascending,
    );
  }

  @override
  Future<ContactAnalytics> getContactAnalytics() async {
    return ContactAnalytics.empty();
  }

  @override
  List<String> getRecentSearches() => const <String>[];

  @override
  ContactPrivacySettings getPrivacySettings() {
    return const ContactPrivacySettings(
      allowAddressBookSync: false,
      allowContactExport: false,
      enableContactAnalytics: false,
    );
  }

  @override
  Future<ContactOperationResult> deleteContactById(UserId userId) async {
    deletedContactIds.add(userId.value);
    return deleteResult;
  }
}

class _FakeContactRepository extends Fake implements IContactRepository {
  final List<String> verifyCalls = <String>[];
  bool throwOnVerify = false;

  @override
  Future<void> markContactVerified(String publicKey) async {
    if (throwOnVerify) throw StateError('verify failed');
    verifyCalls.add(publicKey);
  }
}

void main() {
  group('contact_provider', () {
    test('ContactSearchNotifier updates and resets state', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(contactSearchStateProvider.notifier);
      expect(container.read(contactSearchStateProvider).query, isEmpty);

      notifier.setQuery('alice');
      expect(container.read(contactSearchStateProvider).query, 'alice');

      const filter = ContactSearchFilter(
        securityLevel: SecurityLevel.high,
        onlyRecentlyActive: true,
      );
      notifier.setFilter(filter);
      expect(container.read(contactSearchStateProvider).filter, filter);

      notifier.setSortOption(ContactSortOption.lastSeen, ascending: false);
      expect(
        container.read(contactSearchStateProvider).sortBy,
        ContactSortOption.lastSeen,
      );
      expect(container.read(contactSearchStateProvider).ascending, isFalse);

      notifier.toggleSortDirection();
      expect(container.read(contactSearchStateProvider).ascending, isTrue);

      notifier.reset();
      final resetState = container.read(contactSearchStateProvider);
      expect(resetState.query, isEmpty);
      expect(resetState.filter, isNull);
      expect(resetState.sortBy, ContactSortOption.name);
      expect(resetState.ascending, isTrue);
    });

    test('ContactSearchNotifier debouncedQuery updates after delay', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(contactSearchStateProvider.notifier);
      notifier.debouncedQuery('bob');

      expect(container.read(contactSearchStateProvider).query, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(container.read(contactSearchStateProvider).query, 'bob');
    });

    test('contactDetailProvider returns null for empty public key', () async {
      final service = _FakeContactManagementService();
      final container = ProviderContainer(
        overrides: [contactServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);

      final result = await container.read(contactDetailProvider('').future);
      expect(result, isNull);
      expect(service.getEnhancedContactByIdCalls, 0);
    });

    test('verifyContactProvider handles empty, success, and failure', () async {
      final repository = _FakeContactRepository();
      final container = ProviderContainer(
        overrides: [contactRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      final emptyResult = await container.read(
        verifyContactProvider('').future,
      );
      expect(emptyResult, isFalse);

      final successResult = await container.read(
        verifyContactProvider('peer-key').future,
      );
      expect(successResult, isTrue);
      expect(repository.verifyCalls, <String>['peer-key']);

      repository.throwOnVerify = true;
      final failureResult = await container.read(
        verifyContactProvider('peer-key-2').future,
      );
      expect(failureResult, isFalse);
    });

    test(
      'deleteContactProvider validates key and forwards to service',
      () async {
        final service = _FakeContactManagementService()
          ..deleteResult = ContactOperationResult.success('deleted');
        final container = ProviderContainer(
          overrides: [contactServiceProvider.overrideWithValue(service)],
        );
        addTearDown(container.dispose);

        final invalid = await container.read(deleteContactProvider('').future);
        expect(invalid.success, isFalse);
        expect(invalid.message, 'Contact key is empty');
        expect(service.deletedContactIds, isEmpty);

        final valid = await container.read(
          deleteContactProvider('peer').future,
        );
        expect(valid.success, isTrue);
        expect(service.deletedContactIds, <String>['peer']);
      },
    );
  });
}
