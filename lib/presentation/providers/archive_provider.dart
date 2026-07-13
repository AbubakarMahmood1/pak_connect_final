// Archive state management provider using Riverpod
// Manages archive operations, search, and UI state

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../../domain/services/archive_management_service.dart';
import '../../domain/services/archive_search_service.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/values/id_types.dart';
import '../../domain/models/archive_models.dart';
import 'di_providers.dart';

/// Logger for archive provider
final _logger = Logger('ArchiveProvider');
const _archiveOperationUnset = Object();

/// Archive management service provider (singleton)
/// ✅ FIXED: Uses singleton instance instead of creating new instances
final archiveManagementServiceProvider = Provider<ArchiveManagementService>((
  ref,
) {
  final service =
      resolveFromAppServicesOrServiceLocator<ArchiveManagementService>(
        fromServices: (services) => services.archiveManagementService,
        dependencyName: 'ArchiveManagementService',
      );

  // Initialize service when first accessed (idempotent - safe to call multiple times)
  service.initialize().catchError((error) {
    _logger.severe('Failed to initialize archive management service: $error');
  });

  // Note: Don't dispose singleton on provider disposal - it's shared across app
  // The singleton will be disposed when app terminates

  return service;
});

/// Archive search service provider (singleton)
/// ✅ FIXED: Uses singleton instance instead of creating new instances
final archiveSearchServiceProvider = Provider<ArchiveSearchService>((ref) {
  final service = resolveFromAppServicesOrServiceLocator<ArchiveSearchService>(
    fromServices: (services) => services.archiveSearchService,
    dependencyName: 'ArchiveSearchService',
  );

  // Initialize service when first accessed (idempotent - safe to call multiple times)
  service.initialize().catchError((error) {
    _logger.severe('Failed to initialize archive search service: $error');
  });

  // Note: Don't dispose singleton on provider disposal - it's shared across app
  // The singleton will be disposed when app terminates

  return service;
});

/// Archive update events stream (bridged through Riverpod)
/// ✅ Phase 6: Archive updates exposed via StreamProvider for proper lifecycle management
final archiveUpdatesProvider = StreamProvider<ArchiveUpdateEvent>((ref) {
  final service = ref.watch(archiveManagementServiceProvider);
  return service.archiveUpdates;
});

/// Archive policy update events stream (bridged through Riverpod)
/// ✅ Phase 6: Archive policy updates exposed via StreamProvider
final archivePolicyUpdatesProvider = StreamProvider<ArchivePolicyEvent>((ref) {
  final service = ref.watch(archiveManagementServiceProvider);
  return service.policyUpdates;
});

/// Archive maintenance events stream (bridged through Riverpod)
/// ✅ Phase 6: Archive maintenance updates exposed via StreamProvider
final archiveMaintenanceUpdatesProvider =
    StreamProvider<ArchiveMaintenanceEvent>((ref) {
      final service = ref.watch(archiveManagementServiceProvider);
      return service.maintenanceUpdates;
    });

/// Archive statistics provider
final archiveStatisticsProvider = FutureProvider<ArchiveStatistics>((
  ref,
) async {
  final managementService = ref.watch(archiveManagementServiceProvider);

  try {
    final analytics = await managementService.getArchiveAnalytics();
    return analytics.statistics;
  } catch (e) {
    _logger.severe('Failed to get archive statistics: $e');
    return ArchiveStatistics.empty();
  }
});

/// Archive list provider with optional filtering
final archiveListProvider =
    FutureProvider.family<List<ArchivedChatSummary>, ArchiveListFilter?>((
      ref,
      filter,
    ) async {
      final managementService = ref.watch(archiveManagementServiceProvider);

      try {
        final summaries = await managementService.getEnhancedArchiveSummaries(
          filter: filter?.searchFilter,
          limit: filter?.limit ?? 50,
          offset: filter?.afterCursor != null
              ? int.tryParse(filter!.afterCursor!)
              : null,
        );

        // Convert enhanced summaries to basic summaries for UI
        return summaries.map((enhanced) => enhanced.summary).toList();
      } catch (e) {
        _logger.severe('Failed to get archive list: $e');
        return [];
      }
    });

/// Archive search results provider
final archiveSearchProvider =
    FutureProvider.family<AdvancedSearchResult, ArchiveSearchQuery>((
      ref,
      query,
    ) async {
      final searchService = ref.watch(archiveSearchServiceProvider);

      if (query.query.trim().isEmpty) {
        return AdvancedSearchResult.error(
          query: query.query,
          error: 'Empty query',
          searchTime: Duration.zero,
        );
      }

      try {
        return await searchService.search(
          query: query.query,
          filter: query.filter,
          options: query.options,
          limit: query.limit,
        );
      } catch (e) {
        _logger.severe('Failed to perform archive search: $e');
        return AdvancedSearchResult.error(
          query: query.query,
          error: 'Search failed: $e',
          searchTime: Duration.zero,
        );
      }
    });

/// Search suggestions provider
final archiveSearchSuggestionsProvider =
    FutureProvider.family<List<SearchSuggestion>, String>((
      ref,
      partialQuery,
    ) async {
      final searchService = ref.watch(archiveSearchServiceProvider);

      if (partialQuery.trim().isEmpty) {
        return [];
      }

      try {
        return await searchService.getSearchSuggestions(
          partialQuery: partialQuery,
          limit: 10,
        );
      } catch (e) {
        _logger.warning('Failed to get search suggestions: $e');
        return [];
      }
    });

/// Individual archived chat provider
final archivedChatProvider = FutureProvider.family<ArchivedChat?, ArchiveId>((
  ref,
  archiveId,
) async {
  final managementService = ref.watch(archiveManagementServiceProvider);

  try {
    return await managementService.getArchivedChat(archiveId);
  } catch (e) {
    _logger.severe('Failed to get archived chat: $e');
    return null;
  }
});

/// Archive operations state
class ArchiveOperationsState {
  final bool isArchiving;
  final bool isRestoring;
  final bool isDeleting;
  final String? currentOperation;
  final Map<String, double> operationProgress;
  final List<String> recentErrors;
  final List<String> recentSuccesses;

  const ArchiveOperationsState({
    this.isArchiving = false,
    this.isRestoring = false,
    this.isDeleting = false,
    this.currentOperation,
    this.operationProgress = const {},
    this.recentErrors = const [],
    this.recentSuccesses = const [],
  });

  ArchiveOperationsState copyWith({
    bool? isArchiving,
    bool? isRestoring,
    bool? isDeleting,
    Object? currentOperation = _archiveOperationUnset,
    Map<String, double>? operationProgress,
    List<String>? recentErrors,
    List<String>? recentSuccesses,
  }) {
    return ArchiveOperationsState(
      isArchiving: isArchiving ?? this.isArchiving,
      isRestoring: isRestoring ?? this.isRestoring,
      isDeleting: isDeleting ?? this.isDeleting,
      currentOperation: identical(currentOperation, _archiveOperationUnset)
          ? this.currentOperation
          : currentOperation as String?,
      operationProgress: operationProgress ?? this.operationProgress,
      recentErrors: recentErrors ?? this.recentErrors,
      recentSuccesses: recentSuccesses ?? this.recentSuccesses,
    );
  }

  bool get hasActiveOperation => isArchiving || isRestoring || isDeleting;
}

/// Modern Riverpod 3.0 Archive Operations Notifier
/// ✅ Phase 6: Migrated from manual StreamSubscription to ref.listen pattern
class ArchiveOperationsNotifier extends Notifier<ArchiveOperationsState> {
  Timer? _searchDebounceTimer;

  @override
  ArchiveOperationsState build() {
    // ✅ Phase 6: Use ref.listen instead of manual StreamSubscription
    // This provides automatic lifecycle management and disposal
    ref.listen<AsyncValue<ArchiveUpdateEvent>>(archiveUpdatesProvider, (
      prev,
      next,
    ) {
      next.whenData(_handleArchiveUpdateEvent);
    });

    // Cleanup on dispose
    ref.onDispose(() {
      _searchDebounceTimer?.cancel();
    });

    return const ArchiveOperationsState();
  }

  void _handleArchiveUpdateEvent(ArchiveUpdateEvent event) {
    final isArchiving = event.type == ArchiveUpdateEventType.archived
        ? false
        : state.isArchiving;
    final isRestoring = event.type == ArchiveUpdateEventType.restored
        ? false
        : state.isRestoring;
    final isDeleting = event.type == ArchiveUpdateEventType.deleted
        ? false
        : state.isDeleting;
    final message = switch (event.type) {
      ArchiveUpdateEventType.archived => 'Archived chat ${event.chatId}',
      ArchiveUpdateEventType.restored => 'Restored archive ${event.archiveId}',
      ArchiveUpdateEventType.deleted => 'Deleted archive ${event.archiveId}',
    };

    state = state.copyWith(
      isArchiving: isArchiving,
      isRestoring: isRestoring,
      isDeleting: isDeleting,
      currentOperation: isArchiving || isRestoring || isDeleting
          ? state.currentOperation
          : null,
      recentSuccesses: _appendSuccess(message),
    );
  }

  List<String> _appendSuccess(String message) {
    if (state.recentSuccesses.isNotEmpty &&
        state.recentSuccesses.last == message) {
      return state.recentSuccesses;
    }
    return [...state.recentSuccesses, message];
  }

  /// Debounced search to avoid hammering DB on each keystroke
  void debouncedSearch(String query) {
    _searchDebounceTimer?.cancel();
    _searchDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      ref.read(archiveUIStateProvider.notifier).updateSearchQuery(query);
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    try {
      final ArchiveSearchService searchService = ref.read(
        archiveSearchServiceProvider,
      );
      await searchService.search(
        query: query,
        filter: null,
        options: null,
        limit: 50,
      );
    } catch (e) {
      _logger.warning('Archive search failed: $e');
    }
  }

  /// Archive a chat
  /// ✅ Phase 6: Uses ref.read to access service instead of storing instance
  Future<ArchiveOperationResult> archiveChat({
    required ChatId chatId,
    String? reason,
    Map<String, dynamic>? metadata,
  }) async {
    state = state.copyWith(
      isArchiving: true,
      currentOperation: 'Archiving chat...',
    );

    try {
      final managementService = ref.read(archiveManagementServiceProvider);
      final result = await managementService.archiveChat(
        chatId: chatId.value,
        reason: reason,
        metadata: metadata,
      );

      if (!result.success) {
        state = state.copyWith(
          isArchiving: false,
          currentOperation: null,
          recentErrors: [...state.recentErrors, result.message],
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isArchiving: false,
        currentOperation: null,
        recentErrors: [...state.recentErrors, 'Archive failed: $e'],
      );

      return ArchiveOperationResult.failure(
        message: 'Archive operation failed: $e',
        operationType: ArchiveOperationType.archive,
        operationTime: Duration.zero,
      );
    }
  }

  /// Restore a chat from archive
  /// ✅ Phase 6: Uses ref.read to access service instead of storing instance
  Future<ArchiveOperationResult> restoreChat({
    required ArchiveId archiveId,
    String? targetChatId,
    bool overwriteExisting = false,
  }) async {
    state = state.copyWith(
      isRestoring: true,
      currentOperation: 'Restoring chat...',
    );

    try {
      final managementService = ref.read(archiveManagementServiceProvider);
      final result = await managementService.restoreChat(
        archiveId: archiveId,
        overwriteExisting: overwriteExisting,
        targetChatId: targetChatId,
      );

      if (!result.success) {
        state = state.copyWith(
          isRestoring: false,
          currentOperation: null,
          recentErrors: [...state.recentErrors, result.message],
        );
      }

      return result;
    } catch (e) {
      state = state.copyWith(
        isRestoring: false,
        currentOperation: null,
        recentErrors: [...state.recentErrors, 'Restore failed: $e'],
      );

      return ArchiveOperationResult.failure(
        message: 'Restore operation failed: $e',
        operationType: ArchiveOperationType.restore,
        operationTime: Duration.zero,
      );
    }
  }

  /// Delete archived chat permanently
  Future<bool> deleteArchivedChat(ArchiveId archiveId) async {
    state = state.copyWith(
      isDeleting: true,
      currentOperation: 'Deleting archived chat...',
    );

    try {
      final managementService = ref.read(archiveManagementServiceProvider);
      final result = await managementService.deleteArchivedChat(archiveId);

      if (!result.success) {
        state = state.copyWith(
          isDeleting: false,
          currentOperation: null,
          recentErrors: [...state.recentErrors, result.message],
        );
        return false;
      }

      state = state.copyWith(
        isDeleting: false,
        currentOperation: null,
        recentSuccesses: _appendSuccess('Deleted archive $archiveId'),
      );

      return true;
    } catch (e) {
      state = state.copyWith(
        isDeleting: false,
        currentOperation: null,
        recentErrors: [...state.recentErrors, 'Delete failed: $e'],
      );

      return false;
    }
  }

  /// Clear recent messages
  void clearRecentMessages() {
    state = state.copyWith(recentErrors: [], recentSuccesses: []);
  }
}

/// Modern NotifierProvider for archive operations
final archiveOperationsProvider =
    NotifierProvider<ArchiveOperationsNotifier, ArchiveOperationsState>(() {
      return ArchiveOperationsNotifier();
    });

/// Legacy compatibility - redirects to modern provider
@Deprecated('Use archiveOperationsProvider directly instead')
final archiveOperationsStateProvider = Provider<ArchiveOperationsState>((ref) {
  return ref.watch(archiveOperationsProvider);
});

/// Filter parameters for archive list
class ArchiveListFilter {
  final ArchiveSearchFilter? searchFilter;
  final int? limit;
  final String? afterCursor;
  final ArchiveSortOption sortBy;
  final bool ascending;

  const ArchiveListFilter({
    this.searchFilter,
    this.limit,
    this.afterCursor,
    this.sortBy = ArchiveSortOption.dateArchived,
    this.ascending = false,
  });

  ArchiveListFilter copyWith({
    ArchiveSearchFilter? searchFilter,
    int? limit,
    String? afterCursor,
    ArchiveSortOption? sortBy,
    bool? ascending,
  }) {
    return ArchiveListFilter(
      searchFilter: searchFilter ?? this.searchFilter,
      limit: limit ?? this.limit,
      afterCursor: afterCursor ?? this.afterCursor,
      sortBy: sortBy ?? this.sortBy,
      ascending: ascending ?? this.ascending,
    );
  }
}

/// Search query parameters
class ArchiveSearchQuery {
  final String query;
  final ArchiveSearchFilter? filter;
  final SearchOptions? options;
  final int limit;

  const ArchiveSearchQuery({
    required this.query,
    this.filter,
    this.options,
    this.limit = 50,
  });

  ArchiveSearchQuery copyWith({
    String? query,
    ArchiveSearchFilter? filter,
    SearchOptions? options,
    int? limit,
  }) {
    return ArchiveSearchQuery(
      query: query ?? this.query,
      filter: filter ?? this.filter,
      options: options ?? this.options,
      limit: limit ?? this.limit,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ArchiveSearchQuery &&
        other.query == query &&
        other.filter == filter &&
        other.options == options &&
        other.limit == limit;
  }

  @override
  int get hashCode {
    return Object.hash(query, filter, options, limit);
  }
}

/// Archive UI state
class ArchiveUIState {
  final bool isSearchMode;
  final String searchQuery;
  final ArchiveListFilter? currentFilter;
  final ArchiveId? selectedArchiveId;
  final bool showStatistics;

  const ArchiveUIState({
    this.isSearchMode = false,
    this.searchQuery = '',
    this.currentFilter,
    this.selectedArchiveId,
    this.showStatistics = true,
  });

  ArchiveUIState copyWith({
    bool? isSearchMode,
    String? searchQuery,
    ArchiveListFilter? currentFilter,
    ArchiveId? selectedArchiveId,
    bool? showStatistics,
  }) {
    return ArchiveUIState(
      isSearchMode: isSearchMode ?? this.isSearchMode,
      searchQuery: searchQuery ?? this.searchQuery,
      currentFilter: currentFilter ?? this.currentFilter,
      selectedArchiveId: selectedArchiveId ?? this.selectedArchiveId,
      showStatistics: showStatistics ?? this.showStatistics,
    );
  }
}

/// Modern Riverpod 3.0 Archive UI State Notifier
class ArchiveUIStateNotifier extends Notifier<ArchiveUIState> {
  @override
  ArchiveUIState build() {
    return const ArchiveUIState();
  }

  void toggleSearchMode() {
    state = state.copyWith(
      isSearchMode: !state.isSearchMode,
      searchQuery: state.isSearchMode ? '' : state.searchQuery,
    );
  }

  void updateSearchQuery(String query) {
    state = state.copyWith(searchQuery: query);
  }

  void updateFilter(ArchiveListFilter? filter) {
    state = state.copyWith(currentFilter: filter);
  }

  void selectArchive(ArchiveId? archiveId) {
    state = state.copyWith(selectedArchiveId: archiveId);
  }

  void toggleStatistics() {
    state = state.copyWith(showStatistics: !state.showStatistics);
  }

  void clearSearch() {
    state = state.copyWith(
      isSearchMode: false,
      searchQuery: '',
      currentFilter: null,
    );
  }
}

/// Modern NotifierProvider for archive UI state
final archiveUIStateProvider =
    NotifierProvider<ArchiveUIStateNotifier, ArchiveUIState>(() {
      return ArchiveUIStateNotifier();
    });

/// Legacy compatibility - redirects to modern provider
@Deprecated('Use archiveUIStateProvider directly instead')
final archiveUICurrentStateProvider = Provider<ArchiveUIState>((ref) {
  return ref.watch(archiveUIStateProvider);
});
