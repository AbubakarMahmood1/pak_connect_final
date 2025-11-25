// Contact management state provider with comprehensive features

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/services/contact_management_service.dart';
import '../../domain/entities/enhanced_contact.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';

final _logger = Logger('ContactProvider');

/// Contact service singleton provider
/// ✅ FIXED: Uses singleton instance instead of creating new instances
final contactServiceProvider = Provider<ContactManagementService>((ref) {
  final service = ContactManagementService.instance;
  service.initialize();
  return service;
});

/// Contact repository provider
final contactRepositoryProvider = Provider<ContactRepository>((ref) {
  return ContactRepository();
});

/// All enhanced contacts provider
/// ✅ FIXED: Removed infinite polling loop - use FutureProvider for one-time load
/// Contacts will be refreshed when explicitly invalidated by UI actions
final contactsProvider = FutureProvider<List<EnhancedContact>>((ref) async {
  final service = ref.watch(contactServiceProvider);
  return await service.getAllEnhancedContacts();
});

/// Auto-refresh contacts provider (opt-in for screens that need periodic updates)
/// Use this sparingly - most screens should use contactsProvider with manual refresh
/// FIX-007: Added autoDispose to prevent memory leaks
final autoRefreshContactsProvider =
    StreamProvider.autoDispose<List<EnhancedContact>>((ref) async* {
      final service = ref.watch(contactServiceProvider);

      // Initial load
      yield await service.getAllEnhancedContacts();

      // Refresh every 60 seconds (increased from 30 to reduce load)
      // Only active when this provider is actively watched
      await for (final _ in Stream.periodic(const Duration(seconds: 60))) {
        yield await service.getAllEnhancedContacts();
      }
    });

/// Single contact provider by public key
final contactDetailProvider = FutureProvider.family<EnhancedContact?, String>((
  ref,
  publicKey,
) async {
  final service = ref.watch(contactServiceProvider);
  return await service.getEnhancedContact(publicKey);
});

/// Contact search state
class ContactSearchState {
  final String query;
  final ContactSearchFilter? filter;
  final ContactSortOption sortBy;
  final bool ascending;

  const ContactSearchState({
    this.query = '',
    this.filter,
    this.sortBy = ContactSortOption.name,
    this.ascending = true,
  });

  ContactSearchState copyWith({
    String? query,
    ContactSearchFilter? filter,
    ContactSortOption? sortBy,
    bool? ascending,
  }) {
    return ContactSearchState(
      query: query ?? this.query,
      filter: filter ?? this.filter,
      sortBy: sortBy ?? this.sortBy,
      ascending: ascending ?? this.ascending,
    );
  }
}

/// Contact search state notifier
class ContactSearchNotifier extends Notifier<ContactSearchState> {
  Timer? _debounce;

  @override
  ContactSearchState build() => const ContactSearchState();

  void setQuery(String query) {
    state = state.copyWith(query: query);
  }

  void debouncedQuery(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      setQuery(query);
    });
    ref.onDispose(() {
      _debounce?.cancel();
    });
  }

  void setFilter(ContactSearchFilter? filter) {
    state = state.copyWith(filter: filter);
  }

  void setSortOption(ContactSortOption sortBy, {bool? ascending}) {
    state = state.copyWith(sortBy: sortBy, ascending: ascending);
  }

  void toggleSortDirection() {
    state = state.copyWith(ascending: !state.ascending);
  }

  void reset() {
    state = const ContactSearchState();
  }
}

/// Contact search state provider
final contactSearchStateProvider =
    NotifierProvider<ContactSearchNotifier, ContactSearchState>(() {
      return ContactSearchNotifier();
    });

/// Filtered and sorted contacts based on search state
final filteredContactsProvider = FutureProvider<ContactSearchResult>((
  ref,
) async {
  final service = ref.watch(contactServiceProvider);
  final searchState = ref.watch(contactSearchStateProvider);

  return await service.searchContacts(
    query: searchState.query,
    filter: searchState.filter,
    sortBy: searchState.sortBy,
    ascending: searchState.ascending,
  );
});

/// Contact analytics provider
final contactAnalyticsProvider = FutureProvider<ContactAnalytics>((ref) async {
  final service = ref.watch(contactServiceProvider);
  return await service.getContactAnalytics();
});

/// Recent search queries provider
final recentSearchesProvider = Provider<List<String>>((ref) {
  final service = ref.watch(contactServiceProvider);
  return service.getRecentSearches();
});

/// Privacy settings provider
final contactPrivacySettingsProvider = Provider<ContactPrivacySettings>((ref) {
  final service = ref.watch(contactServiceProvider);
  return service.getPrivacySettings();
});

/// Contact action handlers

/// Delete contact action
final deleteContactProvider =
    FutureProvider.family<ContactOperationResult, String>((
      ref,
      publicKey,
    ) async {
      final service = ref.watch(contactServiceProvider);
      final result = await service.deleteContact(publicKey);

      // Invalidate contacts list to trigger refresh
      if (result.success) {
        ref.invalidate(contactsProvider);
        ref.invalidate(filteredContactsProvider);
      }

      return result;
    });

/// Verify contact action
final verifyContactProvider = FutureProvider.family<bool, String>((
  ref,
  publicKey,
) async {
  final repository = ref.watch(contactRepositoryProvider);

  try {
    await repository.markContactVerified(publicKey);

    // Invalidate to refresh
    ref.invalidate(contactsProvider);
    ref.invalidate(filteredContactsProvider);
    ref.invalidate(contactDetailProvider(publicKey));

    _logger.info(
      '✓ Contact verified: ${publicKey.length > 16 ? '${publicKey.shortId()}...' : publicKey}',
    );
    return true;
  } catch (e) {
    _logger.severe('Failed to verify contact: $e');
    return false;
  }
});

/// Contact stats summary
class ContactStats {
  final int totalContacts;
  final int verifiedContacts;
  final int activeContacts;
  final int highSecurityContacts;

  const ContactStats({
    required this.totalContacts,
    required this.verifiedContacts,
    required this.activeContacts,
    required this.highSecurityContacts,
  });

  static const empty = ContactStats(
    totalContacts: 0,
    verifiedContacts: 0,
    activeContacts: 0,
    highSecurityContacts: 0,
  );
}

/// Quick contact stats provider for UI badges
final contactStatsProvider = FutureProvider<ContactStats>((ref) async {
  final contactsAsync = ref.watch(contactsProvider);

  return contactsAsync.when(
    data: (contacts) {
      return ContactStats(
        totalContacts: contacts.length,
        verifiedContacts: contacts
            .where((c) => c.trustStatus == TrustStatus.verified)
            .length,
        activeContacts: contacts.where((c) => c.isRecentlyActive).length,
        highSecurityContacts: contacts
            .where((c) => c.securityLevel == SecurityLevel.high)
            .length,
      );
    },
    loading: () => ContactStats.empty,
    error: (error, stackTrace) => ContactStats.empty,
  );
});
