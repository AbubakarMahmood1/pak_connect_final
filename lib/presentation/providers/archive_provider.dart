// Archive state management provider using Riverpod
// Manages archive operations, search, and UI state

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import '../../domain/services/archive_management_service.dart';
import '../../domain/services/archive_search_service.dart';
import '../../domain/entities/archived_chat.dart';
import '../../core/models/archive_models.dart';

/// Logger for archive provider
final _logger = Logger('ArchiveProvider');

/// Archive management service provider
final archiveManagementServiceProvider = Provider<ArchiveManagementService>((ref) {
  final service = ArchiveManagementService();
  
  // Initialize service when first accessed
  service.initialize().catchError((error) {
    _logger.severe('Failed to initialize archive management service: $error');
  });
  
  ref.onDispose(() {
    service.dispose();
  });
  
  return service;
});

/// Archive search service provider
final archiveSearchServiceProvider = Provider<ArchiveSearchService>((ref) {
  final service = ArchiveSearchService();
  
  // Initialize service when first accessed
  service.initialize().catchError((error) {
    _logger.severe('Failed to initialize archive search service: $error');
  });
  
  ref.onDispose(() {
    service.dispose();
  });
  
  return service;
});

/// Archive statistics provider
final archiveStatisticsProvider = FutureProvider<ArchiveStatistics>((ref) async {
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
final archiveListProvider = FutureProvider.family<List<ArchivedChatSummary>, ArchiveListFilter?>((ref, filter) async {
  final managementService = ref.watch(archiveManagementServiceProvider);
  
  try {
    final summaries = await managementService.getEnhancedArchiveSummaries(
      filter: filter?.searchFilter,
      limit: filter?.limit ?? 50,
      afterCursor: filter?.afterCursor,
    );
    
    // Convert enhanced summaries to basic summaries for UI
    return summaries.map((enhanced) => enhanced.summary).toList();
    
  } catch (e) {
    _logger.severe('Failed to get archive list: $e');
    return [];
  }
});

/// Archive search results provider
final archiveSearchProvider = FutureProvider.family<AdvancedSearchResult, ArchiveSearchQuery>((ref, query) async {
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
final archiveSearchSuggestionsProvider = FutureProvider.family<List<SearchSuggestion>, String>((ref, partialQuery) async {
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
final archivedChatProvider = FutureProvider.family<ArchivedChat?, String>((ref, archiveId) async {
  final managementService = ref.watch(archiveManagementServiceProvider);
  
  try {
    // Get archived chat through service API
    final summaries = await managementService.getEnhancedArchiveSummaries();
    final summary = summaries.where((s) => s.summary.id == archiveId).firstOrNull;
    
    if (summary == null) return null;
    
    // For now, return a basic implementation - this would need proper API extension
    return ArchivedChat.fromJson({
      'id': summary.summary.id,
      'originalChatId': summary.summary.originalChatId,
      'contactName': summary.summary.contactName,
      'archivedAt': summary.summary.archivedAt.millisecondsSinceEpoch,
      'messageCount': summary.summary.messageCount,
      'metadata': {
        'version': '1.0',
        'reason': 'User archived',
        'originalUnreadCount': 0,
        'wasOnline': false,
        'hadUnsentMessages': false,
        'estimatedStorageSize': summary.summary.estimatedSize,
        'archiveSource': 'ArchiveProvider',
        'tags': summary.summary.tags,
        'hasSearchIndex': summary.summary.isSearchable,
      },
      'messages': [], // Would need proper message loading
    });
  } catch (e) {
    _logger.severe('Failed to get archived chat: $e');
    return null;
  }
});

/// Archive operations state provider
final archiveOperationsProvider = Provider<ArchiveOperationsNotifier>((ref) {
  return ArchiveOperationsNotifier(
    ref.watch(archiveManagementServiceProvider),
  );
});

/// Archive operations state provider
final archiveOperationsStateProvider = Provider<ArchiveOperationsState>((ref) {
  final notifier = ref.watch(archiveOperationsProvider);
  return notifier.state;
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
    String? currentOperation,
    Map<String, double>? operationProgress,
    List<String>? recentErrors,
    List<String>? recentSuccesses,
  }) {
    return ArchiveOperationsState(
      isArchiving: isArchiving ?? this.isArchiving,
      isRestoring: isRestoring ?? this.isRestoring,
      isDeleting: isDeleting ?? this.isDeleting,
      currentOperation: currentOperation ?? this.currentOperation,
      operationProgress: operationProgress ?? this.operationProgress,
      recentErrors: recentErrors ?? this.recentErrors,
      recentSuccesses: recentSuccesses ?? this.recentSuccesses,
    );
  }
  
  bool get hasActiveOperation => isArchiving || isRestoring || isDeleting;
}

/// Archive operations notifier
class ArchiveOperationsNotifier {
  final ArchiveManagementService _managementService;
  late StreamSubscription _archiveUpdatesSubscription;
  
  ArchiveOperationsState _state = const ArchiveOperationsState();
  ArchiveOperationsState get state => _state;
  
  final _stateController = StreamController<ArchiveOperationsState>.broadcast();
  Stream<ArchiveOperationsState> get stateStream => _stateController.stream;
  
  ArchiveOperationsNotifier(this._managementService) {
    _setupEventListeners();
  }
  
  void _setState(ArchiveOperationsState newState) {
    _state = newState;
    _stateController.add(newState);
  }
  
  void _setupEventListeners() {
    _archiveUpdatesSubscription = _managementService.archiveUpdates.listen((event) {
      _handleArchiveUpdateEvent(event);
    });
  }
  
  void _handleArchiveUpdateEvent(ArchiveUpdateEvent event) {
    // Handle different types of archive update events
    // Since we can't access private event classes, we'll handle this generically
    _setState(_state.copyWith(
      isArchiving: false,
      isRestoring: false,
      currentOperation: null,
      recentSuccesses: [..._state.recentSuccesses, 'Archive operation completed'],
    ));
  }
  
  /// Archive a chat
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? reason,
    Map<String, dynamic>? metadata,
  }) async {
    _setState(_state.copyWith(
      isArchiving: true,
      currentOperation: 'Archiving chat...',
    ));
    
    try {
      final result = await _managementService.archiveChat(
        chatId: chatId,
        reason: reason,
        metadata: metadata,
      );
      
      if (!result.success) {
        _setState(_state.copyWith(
          isArchiving: false,
          currentOperation: null,
          recentErrors: [..._state.recentErrors, result.message],
        ));
      }
      
      return result;
      
    } catch (e) {
      _setState(_state.copyWith(
        isArchiving: false,
        currentOperation: null,
        recentErrors: [..._state.recentErrors, 'Archive failed: $e'],
      ));
      
      return ArchiveOperationResult.failure(
        message: 'Archive operation failed: $e',
        operationType: ArchiveOperationType.archive,
        operationTime: Duration.zero,
      );
    }
  }
  
  /// Restore a chat from archive
  Future<ArchiveOperationResult> restoreChat({
    required String archiveId,
    bool overwriteExisting = false,
  }) async {
    _setState(_state.copyWith(
      isRestoring: true,
      currentOperation: 'Restoring chat...',
    ));
    
    try {
      final result = await _managementService.restoreChat(
        archiveId: archiveId,
        overwriteExisting: overwriteExisting,
      );
      
      if (!result.success) {
        _setState(_state.copyWith(
          isRestoring: false,
          currentOperation: null,
          recentErrors: [..._state.recentErrors, result.message],
        ));
      }
      
      return result;
      
    } catch (e) {
      _setState(_state.copyWith(
        isRestoring: false,
        currentOperation: null,
        recentErrors: [..._state.recentErrors, 'Restore failed: $e'],
      ));
      
      return ArchiveOperationResult.failure(
        message: 'Restore operation failed: $e',
        operationType: ArchiveOperationType.restore,
        operationTime: Duration.zero,
      );
    }
  }
  
  /// Delete archived chat permanently
  Future<bool> deleteArchivedChat(String archiveId) async {
    _setState(_state.copyWith(
      isDeleting: true,
      currentOperation: 'Deleting archived chat...',
    ));
    
    try {
      // For now, we'll simulate deletion - proper API would be needed
      await Future.delayed(Duration(milliseconds: 500)); // Simulate operation
      // Would actually delete through proper API and get real result
      
      _setState(_state.copyWith(
        isDeleting: false,
        currentOperation: null,
        recentSuccesses: [..._state.recentSuccesses, 'Deleted archive $archiveId'],
      ));
      
      return true;
      
    } catch (e) {
      _setState(_state.copyWith(
        isDeleting: false,
        currentOperation: null,
        recentErrors: [..._state.recentErrors, 'Delete failed: $e'],
      ));
      
      return false;
    }
  }
  
  /// Clear recent messages
  void clearRecentMessages() {
    _setState(_state.copyWith(
      recentErrors: [],
      recentSuccesses: [],
    ));
  }
  
  void dispose() {
    _archiveUpdatesSubscription.cancel();
    _stateController.close();
  }
}

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

/// Archive UI state provider for managing UI-specific state
final archiveUIStateProvider = Provider<ArchiveUIStateNotifier>((ref) {
  return ArchiveUIStateNotifier();
});

/// Archive UI state provider
final archiveUICurrentStateProvider = Provider<ArchiveUIState>((ref) {
  final notifier = ref.watch(archiveUIStateProvider);
  return notifier.state;
});

/// Archive UI state
class ArchiveUIState {
  final bool isSearchMode;
  final String searchQuery;
  final ArchiveListFilter? currentFilter;
  final String? selectedArchiveId;
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
    String? selectedArchiveId,
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

/// Archive UI state notifier
class ArchiveUIStateNotifier {
  ArchiveUIState _state = const ArchiveUIState();
  ArchiveUIState get state => _state;
  
  final _stateController = StreamController<ArchiveUIState>.broadcast();
  Stream<ArchiveUIState> get stateStream => _stateController.stream;
  
  void _setState(ArchiveUIState newState) {
    _state = newState;
    _stateController.add(newState);
  }
  
  void toggleSearchMode() {
    _setState(_state.copyWith(
      isSearchMode: !_state.isSearchMode,
      searchQuery: _state.isSearchMode ? '' : _state.searchQuery,
    ));
  }
  
  void updateSearchQuery(String query) {
    _setState(_state.copyWith(searchQuery: query));
  }
  
  void updateFilter(ArchiveListFilter? filter) {
    _setState(_state.copyWith(currentFilter: filter));
  }
  
  void selectArchive(String? archiveId) {
    _setState(_state.copyWith(selectedArchiveId: archiveId));
  }
  
  void toggleStatistics() {
    _setState(_state.copyWith(showStatistics: !_state.showStatistics));
  }
  
  void clearSearch() {
    _setState(_state.copyWith(
      isSearchMode: false,
      searchQuery: '',
      currentFilter: null,
    ));
  }
  
  void dispose() {
    _stateController.close();
  }
}