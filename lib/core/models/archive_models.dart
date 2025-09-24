// Core archive models and data structures for the pak_connect archive system

import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';

/// Result of archive search operations
class ArchiveSearchResult {
  
  final List<ArchivedMessage> messages;
  final List<ArchivedChatSummary> chats;
  final Map<String, List<ArchivedMessage>> messagesByChat;
  final String query;
  final ArchiveSearchFilter? filter;
  final int totalResults;
  final int totalChatsFound;
  final Duration searchTime;
  final bool hasMore;
  final String? nextPageToken;
  final ArchiveSearchMetadata metadata;
  
  const ArchiveSearchResult({
    required this.messages,
    required this.chats,
    required this.messagesByChat,
    required this.query,
    this.filter,
    required this.totalResults,
    required this.totalChatsFound,
    required this.searchTime,
    required this.hasMore,
    this.nextPageToken,
    required this.metadata,
  });
  
  /// Create empty search result
  factory ArchiveSearchResult.empty([String query = '']) {
    return ArchiveSearchResult(
      messages: [],
      chats: [],
      messagesByChat: {},
      query: query,
      totalResults: 0,
      totalChatsFound: 0,
      searchTime: Duration.zero,
      hasMore: false,
      metadata: ArchiveSearchMetadata.empty(),
    );
  }
  
  /// Create from successful search
  factory ArchiveSearchResult.fromResults({
    required List<ArchivedMessage> messages,
    required List<ArchivedChatSummary> chats,
    required String query,
    ArchiveSearchFilter? filter,
    required Duration searchTime,
    bool hasMore = false,
    String? nextPageToken,
    Map<String, dynamic>? searchStats,
  }) {
    // Group messages by chat
    final messagesByChat = <String, List<ArchivedMessage>>{};
    for (final message in messages) {
      messagesByChat.putIfAbsent(message.chatId, () => []).add(message);
    }
    
    // Create metadata
    final metadata = ArchiveSearchMetadata(
      searchType: _determineSearchType(query, filter),
      indexesUsed: _determineIndexesUsed(query, filter),
      performanceStats: searchStats ?? {},
      suggestedFilters: _generateSuggestedFilters(messages, chats),
      relatedQueries: _generateRelatedQueries(query),
    );
    
    return ArchiveSearchResult(
      messages: messages,
      chats: chats,
      messagesByChat: messagesByChat,
      query: query,
      filter: filter,
      totalResults: messages.length,
      totalChatsFound: chats.length,
      searchTime: searchTime,
      hasMore: hasMore,
      nextPageToken: nextPageToken,
      metadata: metadata,
    );
  }
  
  /// Check if search found any results
  bool get hasResults => totalResults > 0 || totalChatsFound > 0;
  
  /// Get formatted search time
  String get formattedSearchTime {
    if (searchTime.inMilliseconds < 1000) {
      return '${searchTime.inMilliseconds}ms';
    } else {
      return '${(searchTime.inMilliseconds / 1000).toStringAsFixed(2)}s';
    }
  }
  
  /// Get search quality score (0.0-1.0)
  double get searchQuality {
    if (!hasResults) return 0.0;
    
    double score = 0.5; // Base score
    
    // Bonus for fast search
    if (searchTime.inMilliseconds < 100) {
      score += 0.2;
    } else if (searchTime.inMilliseconds < 500) 
    {
      score += 0.1;
    }
    // Bonus for relevant results
    if (totalResults > 0 && totalResults < 20) score += 0.2;
    if (totalChatsFound > 0 && totalChatsFound < 10) score += 0.1;
    
    return score.clamp(0.0, 1.0);
  }
  
  // Helper methods for factory constructor
  
  static ArchiveSearchType _determineSearchType(String query, ArchiveSearchFilter? filter) {
    if (filter?.dateRange != null) return ArchiveSearchType.dateFiltered;
    if (filter?.contactFilter != null) return ArchiveSearchType.contactFiltered;
    if (query.contains('"')) return ArchiveSearchType.exactPhrase;
    if (query.split(' ').length > 1) return ArchiveSearchType.multiTerm;
    return ArchiveSearchType.simpleTerm;
  }
  
  static List<String> _determineIndexesUsed(String query, ArchiveSearchFilter? filter) {
    final indexes = <String>['content_index'];
    if (filter?.dateRange != null) indexes.add('date_index');
    if (filter?.contactFilter != null) indexes.add('contact_index');
    if (query.length < 3) indexes.add('fuzzy_index');
    return indexes;
  }
  
  static Map<String, String> _generateSuggestedFilters(
    List<ArchivedMessage> messages,
    List<ArchivedChatSummary> chats,
  ) {
    final suggestions = <String, String>{};
    
    if (chats.length > 5) {
      final topContact = chats.reduce((a, b) => a.messageCount > b.messageCount ? a : b);
      suggestions['contact'] = 'Filter by ${topContact.contactName}';
    }
    
    if (messages.isNotEmpty) {
      final oldestMessage = messages.reduce((a, b) => 
        a.originalTimestamp.isBefore(b.originalTimestamp) ? a : b);
      final newestMessage = messages.reduce((a, b) => 
        a.originalTimestamp.isAfter(b.originalTimestamp) ? a : b);
        
      final daysDiff = newestMessage.originalTimestamp.difference(oldestMessage.originalTimestamp).inDays;
      if (daysDiff > 30) {
        suggestions['date'] = 'Filter by recent messages (last 30 days)';
      }
    }
    
    return suggestions;
  }
  
  static List<String> _generateRelatedQueries(String query) {
    // Simple related query generation
    final words = query.toLowerCase().split(' ');
    final related = <String>[];
    
    // Add variations
    if (words.length == 1) {
      related.addAll(['${words[0]}*', '"${words[0]}"']);
    } else if (words.length > 1) {
      related.add('"$query"'); // Exact phrase
      related.add(words.join(' OR ')); // Any word
    }
    
    return related.take(3).toList();
  }
}

/// Metadata about archive search operation
class ArchiveSearchMetadata {
  final ArchiveSearchType searchType;
  final List<String> indexesUsed;
  final Map<String, dynamic> performanceStats;
  final Map<String, String> suggestedFilters;
  final List<String> relatedQueries;
  
  const ArchiveSearchMetadata({
    required this.searchType,
    required this.indexesUsed,
    required this.performanceStats,
    required this.suggestedFilters,
    required this.relatedQueries,
  });
  
  factory ArchiveSearchMetadata.empty() => const ArchiveSearchMetadata(
    searchType: ArchiveSearchType.simpleTerm,
    indexesUsed: [],
    performanceStats: {},
    suggestedFilters: {},
    relatedQueries: [],
  );
}

/// Archive search filter options
class ArchiveSearchFilter {
  final String? contactFilter;
  final ArchiveDateRange? dateRange;
  final List<String>? tags;
  final ArchiveMessageTypeFilter? messageTypeFilter;
  final ArchiveSizeFilter? sizeFilter;
  final bool? onlyCompressed;
  final bool? onlySearchable;
  final ArchiveSortOption sortBy;
  final bool ascending;
  final int? limit;
  final String? afterCursor;
  
  const ArchiveSearchFilter({
    this.contactFilter,
    this.dateRange,
    this.tags,
    this.messageTypeFilter,
    this.sizeFilter,
    this.onlyCompressed,
    this.onlySearchable,
    this.sortBy = ArchiveSortOption.relevance,
    this.ascending = false,
    this.limit,
    this.afterCursor,
  });
  
  /// Create filter for recent archives only
  factory ArchiveSearchFilter.recent({int days = 30}) => ArchiveSearchFilter(
    dateRange: ArchiveDateRange.lastDays(days),
    sortBy: ArchiveSortOption.dateArchived,
  );
  
  /// Create filter for specific contact
  factory ArchiveSearchFilter.forContact(String contactName) => ArchiveSearchFilter(
    contactFilter: contactName,
    sortBy: ArchiveSortOption.dateArchived,
  );
  
  /// Create filter for large archives only
  factory ArchiveSearchFilter.largeArchives() => ArchiveSearchFilter(
    sizeFilter: ArchiveSizeFilter.large,
    sortBy: ArchiveSortOption.size,
  );
  
  Map<String, dynamic> toJson() => {
    'contactFilter': contactFilter,
    'dateRange': dateRange?.toJson(),
    'tags': tags,
    'messageTypeFilter': messageTypeFilter?.toJson(),
    'sizeFilter': sizeFilter?.index,
    'onlyCompressed': onlyCompressed,
    'onlySearchable': onlySearchable,
    'sortBy': sortBy.index,
    'ascending': ascending,
    'limit': limit,
    'afterCursor': afterCursor,
  };
  
  factory ArchiveSearchFilter.fromJson(Map<String, dynamic> json) => ArchiveSearchFilter(
    contactFilter: json['contactFilter'],
    dateRange: json['dateRange'] != null 
      ? ArchiveDateRange.fromJson(json['dateRange'])
      : null,
    tags: json['tags'] != null ? List<String>.from(json['tags']) : null,
    messageTypeFilter: json['messageTypeFilter'] != null
      ? ArchiveMessageTypeFilter.fromJson(json['messageTypeFilter'])
      : null,
    sizeFilter: json['sizeFilter'] != null 
      ? ArchiveSizeFilter.values[json['sizeFilter']]
      : null,
    onlyCompressed: json['onlyCompressed'],
    onlySearchable: json['onlySearchable'],
    sortBy: ArchiveSortOption.values[json['sortBy'] ?? 0],
    ascending: json['ascending'] ?? false,
    limit: json['limit'],
    afterCursor: json['afterCursor'],
  );
}

/// Date range for archive filtering
class ArchiveDateRange {
  final DateTime start;
  final DateTime end;
  
  const ArchiveDateRange({
    required this.start,
    required this.end,
  });
  
  /// Create range for last N days
  factory ArchiveDateRange.lastDays(int days) {
    final now = DateTime.now();
    return ArchiveDateRange(
      start: now.subtract(Duration(days: days)),
      end: now,
    );
  }
  
  /// Create range for last N months
  factory ArchiveDateRange.lastMonths(int months) {
    final now = DateTime.now();
    return ArchiveDateRange(
      start: DateTime(now.year, now.month - months, now.day),
      end: now,
    );
  }
  
  /// Create range for specific month
  factory ArchiveDateRange.month(int year, int month) {
    return ArchiveDateRange(
      start: DateTime(year, month, 1),
      end: DateTime(year, month + 1, 1).subtract(const Duration(days: 1)),
    );
  }
  
  bool contains(DateTime date) => 
    date.isAfter(start) && date.isBefore(end) || 
    date.isAtSameMomentAs(start) || 
    date.isAtSameMomentAs(end);
  
  Duration get duration => end.difference(start);
  
  Map<String, dynamic> toJson() => {
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
  };
  
  factory ArchiveDateRange.fromJson(Map<String, dynamic> json) => ArchiveDateRange(
    start: DateTime.fromMillisecondsSinceEpoch(json['start']),
    end: DateTime.fromMillisecondsSinceEpoch(json['end']),
  );
}

/// Message type filter for archives
class ArchiveMessageTypeFilter {
  final bool? hasAttachments;
  final bool? wasStarred;
  final bool? wasEdited;
  final bool? isFromMe;
  final List<MessagePriorityFilter>? priorities;
  final List<String>? contentTypes;
  
  const ArchiveMessageTypeFilter({
    this.hasAttachments,
    this.wasStarred,
    this.wasEdited,
    this.isFromMe,
    this.priorities,
    this.contentTypes,
  });
  
  Map<String, dynamic> toJson() => {
    'hasAttachments': hasAttachments,
    'wasStarred': wasStarred,
    'wasEdited': wasEdited,
    'isFromMe': isFromMe,
    'priorities': priorities?.map((p) => p.index).toList(),
    'contentTypes': contentTypes,
  };
  
  factory ArchiveMessageTypeFilter.fromJson(Map<String, dynamic> json) => ArchiveMessageTypeFilter(
    hasAttachments: json['hasAttachments'],
    wasStarred: json['wasStarred'],
    wasEdited: json['wasEdited'],
    isFromMe: json['isFromMe'],
    priorities: json['priorities'] != null 
      ? (json['priorities'] as List).map((i) => MessagePriorityFilter.values[i]).toList()
      : null,
    contentTypes: json['contentTypes'] != null 
      ? List<String>.from(json['contentTypes'])
      : null,
  );
}

/// Result of archive operations
class ArchiveOperationResult {
  final bool success;
  final String message;
  final ArchiveOperationType operationType;
  final String? archiveId;
  final Duration operationTime;
  final Map<String, dynamic>? metadata;
  final List<String> warnings;
  final ArchiveError? error;
  
  const ArchiveOperationResult._({
    required this.success,
    required this.message,
    required this.operationType,
    this.archiveId,
    required this.operationTime,
    this.metadata,
    this.warnings = const [],
    this.error,
  });
  
  /// Create successful result
  factory ArchiveOperationResult.success({
    required String message,
    required ArchiveOperationType operationType,
    String? archiveId,
    required Duration operationTime,
    Map<String, dynamic>? metadata,
    List<String> warnings = const [],
  }) => ArchiveOperationResult._(
    success: true,
    message: message,
    operationType: operationType,
    archiveId: archiveId,
    operationTime: operationTime,
    metadata: metadata,
    warnings: warnings,
  );
  
  /// Create failure result
  factory ArchiveOperationResult.failure({
    required String message,
    required ArchiveOperationType operationType,
    required Duration operationTime,
    ArchiveError? error,
    List<String> warnings = const [],
  }) => ArchiveOperationResult._(
    success: false,
    message: message,
    operationType: operationType,
    operationTime: operationTime,
    warnings: warnings,
    error: error,
  );
  
  bool get hasWarnings => warnings.isNotEmpty;
  bool get hasError => error != null;
  
  String get formattedOperationTime {
    if (operationTime.inMilliseconds < 1000) {
      return '${operationTime.inMilliseconds}ms';
    } else {
      return '${(operationTime.inMilliseconds / 1000).toStringAsFixed(2)}s';
    }
  }
}

/// Archive system statistics
class ArchiveStatistics {
  final int totalArchives;
  final int totalMessages;
  final int compressedArchives;
  final int searchableArchives;
  final int totalSizeBytes;
  final int compressedSizeBytes;
  final Map<String, int> archivesByMonth;
  final Map<String, int> messagesByContact;
  final double averageCompressionRatio;
  final DateTime? oldestArchive;
  final DateTime? newestArchive;
  final Duration averageArchiveAge;
  final ArchivePerformanceStats performanceStats;
  
  const ArchiveStatistics({
    required this.totalArchives,
    required this.totalMessages,
    required this.compressedArchives,
    required this.searchableArchives,
    required this.totalSizeBytes,
    required this.compressedSizeBytes,
    required this.archivesByMonth,
    required this.messagesByContact,
    required this.averageCompressionRatio,
    this.oldestArchive,
    this.newestArchive,
    required this.averageArchiveAge,
    required this.performanceStats,
  });
  
  /// Create empty statistics
  factory ArchiveStatistics.empty() => ArchiveStatistics(
    totalArchives: 0,
    totalMessages: 0,
    compressedArchives: 0,
    searchableArchives: 0,
    totalSizeBytes: 0,
    compressedSizeBytes: 0,
    archivesByMonth: {},
    messagesByContact: {},
    averageCompressionRatio: 0.0,
    averageArchiveAge: Duration.zero,
    performanceStats: ArchivePerformanceStats.empty(),
  );
  
  /// Get compression efficiency percentage
  double get compressionEfficiency => 
    totalSizeBytes > 0 ? ((totalSizeBytes - compressedSizeBytes) / totalSizeBytes) * 100 : 0.0;
  
  /// Get searchable percentage
  double get searchablePercentage => 
    totalArchives > 0 ? (searchableArchives / totalArchives) * 100 : 0.0;
  
  /// Get formatted total size
  String get formattedTotalSize => _formatBytes(totalSizeBytes);
  
  /// Get formatted compressed size
  String get formattedCompressedSize => _formatBytes(compressedSizeBytes);
  
  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }
}

/// Archive performance statistics
class ArchivePerformanceStats {
  final Duration averageArchiveTime;
  final Duration averageRestoreTime;
  final Duration averageSearchTime;
  final double averageMemoryUsage;
  final int operationsCount;
  final Map<String, int> operationCounts;
  final List<Duration> recentOperationTimes;
  
  const ArchivePerformanceStats({
    required this.averageArchiveTime,
    required this.averageRestoreTime,
    required this.averageSearchTime,
    required this.averageMemoryUsage,
    required this.operationsCount,
    required this.operationCounts,
    required this.recentOperationTimes,
  });
  
  factory ArchivePerformanceStats.empty() => const ArchivePerformanceStats(
    averageArchiveTime: Duration.zero,
    averageRestoreTime: Duration.zero,
    averageSearchTime: Duration.zero,
    averageMemoryUsage: 0.0,
    operationsCount: 0,
    operationCounts: {},
    recentOperationTimes: [],
  );
  
  /// Check if performance is within acceptable limits
  bool get isPerformanceAcceptable =>
    averageArchiveTime.inSeconds < 2 &&
    averageRestoreTime.inSeconds < 3 &&
    averageSearchTime.inMilliseconds < 500 &&
    averageMemoryUsage < 20 * 1024 * 1024; // 20MB
}

/// Archive error information
class ArchiveError {
  final ArchiveErrorType type;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  final DateTime timestamp;
  
  const ArchiveError({
    required this.type,
    required this.code,
    required this.message,
    this.details,
    required this.timestamp,
  });
  
  factory ArchiveError.storageError(String message, [Map<String, dynamic>? details]) =>
    ArchiveError(
      type: ArchiveErrorType.storage,
      code: 'STORAGE_ERROR',
      message: message,
      details: details,
      timestamp: DateTime.now(),
    );
  
  factory ArchiveError.compressionError(String message, [Map<String, dynamic>? details]) =>
    ArchiveError(
      type: ArchiveErrorType.compression,
      code: 'COMPRESSION_ERROR',
      message: message,
      details: details,
      timestamp: DateTime.now(),
    );
  
  factory ArchiveError.searchError(String message, [Map<String, dynamic>? details]) =>
    ArchiveError(
      type: ArchiveErrorType.search,
      code: 'SEARCH_ERROR',
      message: message,
      details: details,
      timestamp: DateTime.now(),
    );
}

// Enums

enum ArchiveOperationType {
  archive,
  restore,
  delete,
  search,
  compress,
  indexing,
  export,
}

enum ArchiveSearchType {
  simpleTerm,
  multiTerm,
  exactPhrase,
  dateFiltered,
  contactFiltered,
  complexQuery,
}

enum ArchiveSortOption {
  relevance,
  dateArchived,
  dateOriginal,
  size,
  messageCount,
  contactName,
}

enum ArchiveSizeFilter {
  small,    // < 1KB
  medium,   // 1KB - 1MB  
  large,    // > 1MB
}

enum MessagePriorityFilter {
  low,
  normal,
  high,
  urgent,
}

enum ArchiveErrorType {
  storage,
  compression,
  search,
  indexing,
  restoration,
  validation,
  network,
  permission,
}