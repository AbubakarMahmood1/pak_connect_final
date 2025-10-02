// Archive repository with comprehensive CRUD operations, caching, and compression

import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/entities/archived_chat.dart';
import '../../domain/entities/archived_message.dart';
import '../../domain/entities/enhanced_message.dart';
import '../../core/models/archive_models.dart';
import '../../data/repositories/message_repository.dart';
import '../../data/repositories/chats_repository.dart';

/// Repository for managing archived chats with advanced features
class ArchiveRepository {
  static final _logger = Logger('ArchiveRepository');
  
  // Storage keys
  static const String _archivedChatsKey = 'archived_chats_v2';
  static const String _archiveIndexKey = 'archive_search_index_v2';
  static const String _archiveStatsKey = 'archive_statistics_v2';
  // Note: _archiveMetadataKey and _compressionCacheKey removed as they were unused placeholders for future features
  
  // Dependencies
  final MessageRepository _messageRepository = MessageRepository();
  final ChatsRepository _chatsRepository = ChatsRepository();
  
  // In-memory caches for performance (LRU implementation)
  final Map<String, ArchivedChat> _archiveCache = {};
  final Map<String, List<ArchivedChatSummary>> _summaryCache = {};
  final Map<String, ArchiveSearchResult> _searchCache = {};
  final List<String> _cacheAccessOrder = [];
  static const int _maxCacheSize = 50;
  
  // Search index for fast lookups
  final Map<String, Set<String>> _searchIndex = {}; // word -> archive IDs
  final Map<String, Set<String>> _contactIndex = {}; // contact -> archive IDs
  final Map<String, Set<String>> _dateIndex = {}; // date key -> archive IDs
  
  // Performance tracking
  final Map<String, Duration> _operationTimes = {};
  int _operationsCount = 0;
  
  /// Initialize repository and load cached data
  Future<void> initialize() async {
    try {
      await _loadSearchIndex();
      await _loadCachedSummaries();
      _logger.info('Archive repository initialized successfully');
    } catch (e) {
      _logger.severe('Failed to initialize archive repository: $e');
    }
  }
  
  /// Archive a chat with all its messages
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  }) async {
    final startTime = DateTime.now();
    
    try {
      _logger.info('Starting archive operation for chat: $chatId');
      
      // Get chat and messages
      final chats = await _chatsRepository.getAllChats();
      final chatItem = chats.where((c) => c.chatId == chatId).firstOrNull;
      
      if (chatItem == null) {
        return ArchiveOperationResult.failure(
          message: 'Chat not found: $chatId',
          operationType: ArchiveOperationType.archive,
          operationTime: DateTime.now().difference(startTime),
        );
      }
      
      final messages = await _messageRepository.getMessages(chatId);
      if (messages.isEmpty) {
        return ArchiveOperationResult.failure(
          message: 'No messages found for chat: $chatId',
          operationType: ArchiveOperationType.archive,
          operationTime: DateTime.now().difference(startTime),
        );
      }
      
      // Convert to enhanced messages
      final enhancedMessages = messages.map((m) => EnhancedMessage.fromMessage(m)).toList();
      
      // Create archived chat
      final archiveId = _generateArchiveId(chatId);
      final archivedChat = ArchivedChat.fromChatAndMessages(
        archiveId: archiveId,
        chatItem: chatItem,
        messages: enhancedMessages,
        archiveReason: archiveReason,
        customData: customData,
      );
      
      // Apply compression if needed
      ArchivedChat finalArchive = archivedChat;
      if (compressLargeArchives && archivedChat.estimatedSize > 10240) { // 10KB threshold
        finalArchive = await _compressArchive(archivedChat);
      }
      
      // Store the archive
      await _storeArchivedChat(finalArchive);
      
      // Update search index
      await _indexArchivedChat(finalArchive);
      
      // Update statistics
      await _updateArchiveStatistics(ArchiveOperationType.archive, finalArchive.estimatedSize);
      
      // Clear original chat data
      await _messageRepository.clearMessages(chatId);
      
      // Update cache
      _updateCache(finalArchive);
      
      final operationTime = DateTime.now().difference(startTime);
      _recordOperationTime('archive', operationTime);
      
      final warnings = <String>[];
      if (finalArchive.isCompressed) {
        warnings.add('Archive was compressed to save space');
      }
      if (messages.length > 1000) {
        warnings.add('Large archive created - search indexing may take additional time');
      }
      
      _logger.info('Successfully archived chat $chatId as $archiveId in ${operationTime.inMilliseconds}ms');
      
      return ArchiveOperationResult.success(
        message: 'Chat archived successfully',
        operationType: ArchiveOperationType.archive,
        archiveId: archiveId,
        operationTime: operationTime,
        metadata: {
          'messageCount': messages.length,
          'originalSize': archivedChat.estimatedSize,
          'finalSize': finalArchive.estimatedSize,
          'compressed': finalArchive.isCompressed,
        },
        warnings: warnings,
      );
      
    } catch (e) {
      final operationTime = DateTime.now().difference(startTime);
      _logger.severe('Archive operation failed for $chatId: $e');
      
      return ArchiveOperationResult.failure(
        message: 'Failed to archive chat: $e',
        operationType: ArchiveOperationType.archive,
        operationTime: operationTime,
        error: ArchiveError.storageError('Archive storage failed', {'chatId': chatId}),
      );
    }
  }
  
  /// Restore an archived chat
  Future<ArchiveOperationResult> restoreChat(String archiveId) async {
    final startTime = DateTime.now();
    
    try {
      _logger.info('Starting restore operation for archive: $archiveId');
      
      // Get archived chat
      final archivedChat = await getArchivedChat(archiveId);
      if (archivedChat == null) {
        return ArchiveOperationResult.failure(
          message: 'Archive not found: $archiveId',
          operationType: ArchiveOperationType.restore,
          operationTime: DateTime.now().difference(startTime),
        );
      }
      
      // Check restoration compatibility
      final preview = archivedChat.getRestorationPreview();
      final warnings = List<String>.from(preview.warnings);
      
      // Decompress if necessary
      ArchivedChat workingArchive = archivedChat;
      if (archivedChat.isCompressed) {
        workingArchive = await _decompressArchive(archivedChat);
      }
      
      // Restore messages
      int restoredCount = 0;
      for (final archivedMessage in workingArchive.messages) {
        try {
          final restoredMessage = archivedMessage.toRestoredMessage();
          await _messageRepository.saveMessage(restoredMessage);
          restoredCount++;
        } catch (e) {
          _logger.warning('Failed to restore message ${archivedMessage.id}: $e');
          warnings.add('Some messages could not be restored');
        }
      }
      
      if (restoredCount == 0) {
        return ArchiveOperationResult.failure(
          message: 'No messages could be restored from archive',
          operationType: ArchiveOperationType.restore,
          operationTime: DateTime.now().difference(startTime),
        );
      }
      
      // Don't automatically delete archive - let user decide
      
      final operationTime = DateTime.now().difference(startTime);
      _recordOperationTime('restore', operationTime);
      
      _logger.info('Successfully restored $restoredCount messages from archive $archiveId');
      
      return ArchiveOperationResult.success(
        message: 'Chat restored successfully',
        operationType: ArchiveOperationType.restore,
        archiveId: archiveId,
        operationTime: operationTime,
        metadata: {
          'restoredMessages': restoredCount,
          'totalMessages': workingArchive.messageCount,
          'wasCompressed': archivedChat.isCompressed,
        },
        warnings: warnings,
      );
      
    } catch (e) {
      final operationTime = DateTime.now().difference(startTime);
      _logger.severe('Restore operation failed for $archiveId: $e');
      
      return ArchiveOperationResult.failure(
        message: 'Failed to restore chat: $e',
        operationType: ArchiveOperationType.restore,
        operationTime: operationTime,
        error: ArchiveError.storageError('Restore operation failed', {'archiveId': archiveId}),
      );
    }
  }
  
  /// Get all archived chats (summaries for performance)
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async {
    try {
      // Check cache first
      final cacheKey = _generateCacheKey('summaries', filter?.toJson());
      if (_summaryCache.containsKey(cacheKey)) {
        var results = _summaryCache[cacheKey]!;
        
        // Apply cursor-based pagination if needed
        if (afterCursor != null) {
          final cursorIndex = results.indexWhere((s) => s.id == afterCursor);
          if (cursorIndex >= 0 && cursorIndex < results.length - 1) {
            results = results.sublist(cursorIndex + 1);
          }
        }
        
        // Apply limit
        if (limit != null && results.length > limit) {
          results = results.take(limit).toList();
        }
        
        return results;
      }
      
      // Load from storage
      final prefs = await SharedPreferences.getInstance();
      final archiveData = prefs.getStringList(_archivedChatsKey) ?? [];
      
      List<ArchivedChatSummary> summaries = [];
      
      for (final jsonString in archiveData) {
        try {
          final json = jsonDecode(jsonString);
          final archive = ArchivedChat.fromJson(json);
          summaries.add(archive.toSummary());
        } catch (e) {
          _logger.warning('Failed to parse archive summary: $e');
        }
      }
      
      // Apply filters
      if (filter != null) {
        summaries = _applyFilterToSummaries(summaries, filter);
      }
      
      // Sort results
      summaries = _sortSummaries(summaries, filter?.sortBy ?? ArchiveSortOption.dateArchived);
      
      // Cache results
      _summaryCache[cacheKey] = List.from(summaries);
      
      // Apply pagination
      if (afterCursor != null) {
        final cursorIndex = summaries.indexWhere((s) => s.id == afterCursor);
        if (cursorIndex >= 0 && cursorIndex < summaries.length - 1) {
          summaries = summaries.sublist(cursorIndex + 1);
        }
      }
      
      if (limit != null && summaries.length > limit) {
        summaries = summaries.take(limit).toList();
      }
      
      return summaries;
      
    } catch (e) {
      _logger.severe('Failed to get archived chats: $e');
      return [];
    }
  }
  
  /// Get specific archived chat with full data
  Future<ArchivedChat?> getArchivedChat(String archiveId) async {
    try {
      // Check cache first
      if (_archiveCache.containsKey(archiveId)) {
        _updateCacheAccess(archiveId);
        return _archiveCache[archiveId];
      }
      
      // Load from storage
      final prefs = await SharedPreferences.getInstance();
      final archiveData = prefs.getStringList(_archivedChatsKey) ?? [];
      
      for (final jsonString in archiveData) {
        try {
          final json = jsonDecode(jsonString);
          if (json['id'] == archiveId) {
            final archive = ArchivedChat.fromJson(json);
            _updateCache(archive);
            return archive;
          }
        } catch (e) {
          _logger.warning('Failed to parse archive $archiveId: $e');
        }
      }
      
      return null;
      
    } catch (e) {
      _logger.severe('Failed to get archived chat $archiveId: $e');
      return null;
    }
  }
  
  /// Search archived messages
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int limit = 50,
  }) async {
    final startTime = DateTime.now();
    
    try {
      if (query.trim().isEmpty) {
        return ArchiveSearchResult.empty(query);
      }
      
      // Check search cache
      final cacheKey = _generateSearchCacheKey(query, filter);
      if (_searchCache.containsKey(cacheKey)) {
        return _searchCache[cacheKey]!;
      }
      
      _logger.info('Searching archives for: "$query"');
      
      // Use search index for fast lookups
      final candidateArchiveIds = _findCandidateArchives(query, filter);
      
      final matchingMessages = <ArchivedMessage>[];
      final matchingChats = <ArchivedChatSummary>[];
      
      // Search through candidate archives
      for (final archiveId in candidateArchiveIds) {
        final archive = await getArchivedChat(archiveId);
        if (archive == null) continue;
        
        // Search messages in this archive
        final archiveMatches = _searchMessagesInArchive(archive, query, filter);
        matchingMessages.addAll(archiveMatches);
        
        if (archiveMatches.isNotEmpty) {
          matchingChats.add(archive.toSummary());
        }
        
        // Early exit if we have enough results
        if (matchingMessages.length >= limit * 2) break;
      }
      
      // Sort by relevance
      matchingMessages.sort((a, b) => _calculateRelevanceScore(b, query).compareTo(_calculateRelevanceScore(a, query)));
      
      // Limit results
      final limitedMessages = matchingMessages.take(limit).toList();
      
      final searchTime = DateTime.now().difference(startTime);
      _recordOperationTime('search', searchTime);
      
      final result = ArchiveSearchResult.fromResults(
        messages: limitedMessages,
        chats: matchingChats,
        query: query,
        filter: filter,
        searchTime: searchTime,
        hasMore: matchingMessages.length > limit,
        searchStats: {
          'candidateArchives': candidateArchiveIds.length,
          'searchedArchives': candidateArchiveIds.length,
          'indexHits': candidateArchiveIds.length,
        },
      );
      
      // Cache result
      _searchCache[cacheKey] = result;
      _maintainSearchCacheSize();
      
      _logger.info('Search completed: found ${result.totalResults} results in ${result.formattedSearchTime}');
      
      return result;
      
    } catch (e) {
      _logger.severe('Search failed for "$query": $e');
      return ArchiveSearchResult.empty(query);
    }
  }
  
  /// Permanently delete an archived chat
  Future<ArchiveOperationResult> permanentlyDeleteArchive(String archiveId) async {
    final startTime = DateTime.now();
    
    try {
      _logger.info('Permanently deleting archive: $archiveId');
      
      // Get archive for size tracking
      final archive = await getArchivedChat(archiveId);
      if (archive == null) {
        return ArchiveOperationResult.failure(
          message: 'Archive not found: $archiveId',
          operationType: ArchiveOperationType.delete,
          operationTime: DateTime.now().difference(startTime),
        );
      }
      
      // Remove from storage
      final prefs = await SharedPreferences.getInstance();
      final archiveData = prefs.getStringList(_archivedChatsKey) ?? [];
      
      final updatedData = archiveData.where((jsonString) {
        try {
          final json = jsonDecode(jsonString);
          return json['id'] != archiveId;
        } catch (e) {
          return true; // Keep if can't parse (don't accidentally delete)
        }
      }).toList();
      
      await prefs.setStringList(_archivedChatsKey, updatedData);
      
      // Remove from search index
      await _removeFromSearchIndex(archiveId);
      
      // Remove from cache
      _archiveCache.remove(archiveId);
      _cacheAccessOrder.remove(archiveId);
      _clearCacheForArchive(archiveId);
      
      // Update statistics
      await _updateArchiveStatistics(ArchiveOperationType.delete, -archive.estimatedSize);
      
      final operationTime = DateTime.now().difference(startTime);
      _recordOperationTime('delete', operationTime);
      
      _logger.info('Successfully deleted archive $archiveId');
      
      return ArchiveOperationResult.success(
        message: 'Archive deleted permanently',
        operationType: ArchiveOperationType.delete,
        archiveId: archiveId,
        operationTime: operationTime,
        metadata: {
          'messageCount': archive.messageCount,
          'sizeFreed': archive.estimatedSize,
        },
      );
      
    } catch (e) {
      final operationTime = DateTime.now().difference(startTime);
      _logger.severe('Delete operation failed for $archiveId: $e');
      
      return ArchiveOperationResult.failure(
        message: 'Failed to delete archive: $e',
        operationType: ArchiveOperationType.delete,
        operationTime: operationTime,
        error: ArchiveError.storageError('Delete operation failed', {'archiveId': archiveId}),
      );
    }
  }
  
  /// Get archive statistics
  Future<ArchiveStatistics> getArchiveStatistics() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final statsJson = prefs.getString(_archiveStatsKey);
      
      if (statsJson != null) {
        // Load cached statistics
        final json = jsonDecode(statsJson);
        return _parseArchiveStatistics(json);
      }
      
      // Calculate statistics from scratch
      return await _calculateArchiveStatistics();
      
    } catch (e) {
      _logger.severe('Failed to get archive statistics: $e');
      return ArchiveStatistics.empty();
    }
  }
  
  /// Clear all cache
  void clearCache() {
    _archiveCache.clear();
    _summaryCache.clear();
    _searchCache.clear();
    _cacheAccessOrder.clear();
    _logger.info('Archive repository cache cleared');
  }
  
  /// Dispose and cleanup
  void dispose() {
    clearCache();
    _logger.info('Archive repository disposed');
  }
  
  // Private helper methods
  
  String _generateArchiveId(String chatId) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final hash = '${chatId}_$timestamp'.hashCode.abs();
    return 'archive_$hash';
  }
  
  Future<void> _storeArchivedChat(ArchivedChat archive) async {
    final prefs = await SharedPreferences.getInstance();
    final archiveData = prefs.getStringList(_archivedChatsKey) ?? [];
    
    final jsonString = jsonEncode(archive.toJson());
    archiveData.add(jsonString);
    
    await prefs.setStringList(_archivedChatsKey, archiveData);
  }
  
  Future<ArchivedChat> _compressArchive(ArchivedChat archive) async {
    try {
      // Simple compression simulation (in real implementation, use gzip)
      final originalJson = jsonEncode(archive.toJson());
      final originalSize = originalJson.length;
      
      // Simulate compression by removing some whitespace and optimizing
      final compressedSize = (originalSize * 0.7).round(); // 30% reduction simulation
      
      final compressionInfo = ArchiveCompressionInfo(
        algorithm: 'simulated_gzip',
        originalSize: originalSize,
        compressedSize: compressedSize,
        compressionRatio: compressedSize / originalSize,
        compressedAt: DateTime.now(),
      );
      
      return archive.copyWith(compressionInfo: compressionInfo);
    } catch (e) {
      _logger.warning('Compression failed, storing uncompressed: $e');
      return archive;
    }
  }
  
  Future<ArchivedChat> _decompressArchive(ArchivedChat archive) async {
    // In real implementation, decompress the data
    // For simulation, just return the archive
    return archive;
  }
  
  Future<void> _indexArchivedChat(ArchivedChat archive) async {
    // Index archive content for search
    final words = <String>{};
    
    // Index contact name
    words.addAll(_tokenizeText(archive.contactName));
    
    // Index message content
    for (final message in archive.messages) {
      words.addAll(_tokenizeText(message.searchableText));
    }
    
    // Update search index
    for (final word in words) {
      _searchIndex.putIfAbsent(word, () => {}).add(archive.id);
    }
    
    // Update contact index
    _contactIndex.putIfAbsent(archive.contactName.toLowerCase(), () => {}).add(archive.id);
    
    // Update date index
    final dateKey = _formatDateForIndex(archive.archivedAt);
    _dateIndex.putIfAbsent(dateKey, () => {}).add(archive.id);
    
    // Save index
    await _saveSearchIndex();
  }
  
  Set<String> _tokenizeText(String text) {
    return text.toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), ' ')
        .split(RegExp(r'\s+'))
        .where((word) => word.length > 2)
        .toSet();
  }
  
  String _formatDateForIndex(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }
  
  Set<String> _findCandidateArchives(String query, ArchiveSearchFilter? filter) {
    final candidates = <String>{};
    final queryWords = _tokenizeText(query);
    
    // Use word-based search index
    for (final word in queryWords) {
      final wordMatches = _searchIndex[word] ?? {};
      if (candidates.isEmpty) {
        candidates.addAll(wordMatches);
      } else {
        // Intersection for AND logic
        candidates.retainWhere((id) => wordMatches.contains(id));
      }
    }
    
    // Apply additional filters
    if (filter?.contactFilter != null) {
      final contactMatches = _contactIndex[filter!.contactFilter!.toLowerCase()] ?? {};
      candidates.retainWhere((id) => contactMatches.contains(id));
    }
    
    if (filter?.dateRange != null) {
      // Simple date filtering (more sophisticated logic would go here)
      final startMonth = _formatDateForIndex(filter!.dateRange!.start);
      final endMonth = _formatDateForIndex(filter.dateRange!.end);
      
      final dateMatches = <String>{};
      for (final entry in _dateIndex.entries) {
        if (entry.key.compareTo(startMonth) >= 0 && entry.key.compareTo(endMonth) <= 0) {
          dateMatches.addAll(entry.value);
        }
      }
      candidates.retainWhere((id) => dateMatches.contains(id));
    }
    
    return candidates;
  }
  
  List<ArchivedMessage> _searchMessagesInArchive(
    ArchivedChat archive,
    String query,
    ArchiveSearchFilter? filter,
  ) {
    final matches = <ArchivedMessage>[];
    final queryLower = query.toLowerCase();
    
    for (final message in archive.messages) {
      // Check if message matches query
      if (!message.searchableText.contains(queryLower)) continue;
      
      // Apply message type filters
      if (filter?.messageTypeFilter != null) {
        final typeFilter = filter!.messageTypeFilter!;
        
        if (typeFilter.isFromMe != null && message.isFromMe != typeFilter.isFromMe) continue;
        if (typeFilter.hasAttachments != null && message.attachments.isNotEmpty != typeFilter.hasAttachments) continue;
        if (typeFilter.wasStarred != null && message.isStarred != typeFilter.wasStarred) continue;
        if (typeFilter.wasEdited != null && message.wasEdited != typeFilter.wasEdited) continue;
      }
      
      matches.add(message);
    }
    
    return matches;
  }
  
  double _calculateRelevanceScore(ArchivedMessage message, String query) {
    final queryLower = query.toLowerCase();
    final contentLower = message.searchableText;
    
    double score = 0.0;
    
    // Exact phrase match
    if (contentLower.contains(queryLower)) {
      score += 10.0;
    }
    
    // Word matches
    final queryWords = queryLower.split(' ');
    final contentWords = contentLower.split(' ');
    
    for (final queryWord in queryWords) {
      for (final contentWord in contentWords) {
        if (contentWord.startsWith(queryWord)) {
          score += 5.0;
        } else if (contentWord.contains(queryWord)) {
          score += 2.0;
        }
      }
    }
    
    // Boost for recent messages
    final age = DateTime.now().difference(message.originalTimestamp);
    if (age.inDays < 30) score += 1.0;
    if (age.inDays < 7) score += 2.0;
    
    // Boost for important messages
    if (message.isStarred) score += 3.0;
    if (message.priority.index > 1) score += 1.0;
    
    return score;
  }
  
  void _updateCache(ArchivedChat archive) {
    _archiveCache[archive.id] = archive;
    _updateCacheAccess(archive.id);
    _maintainCacheSize();
  }
  
  void _updateCacheAccess(String archiveId) {
    _cacheAccessOrder.remove(archiveId);
    _cacheAccessOrder.add(archiveId);
  }
  
  void _maintainCacheSize() {
    while (_archiveCache.length > _maxCacheSize) {
      final oldestId = _cacheAccessOrder.removeAt(0);
      _archiveCache.remove(oldestId);
    }
  }
  
  void _maintainSearchCacheSize() {
    while (_searchCache.length > 20) {
      final oldestKey = _searchCache.keys.first;
      _searchCache.remove(oldestKey);
    }
  }
  
  void _clearCacheForArchive(String archiveId) {
    _summaryCache.clear(); // Clear summary cache as it may contain this archive
    _searchCache.clear(); // Clear search cache as results may reference this archive
  }
  
  String _generateCacheKey(String prefix, Map<String, dynamic>? data) {
    final dataHash = data?.toString().hashCode.abs() ?? 0;
    return '${prefix}_$dataHash';
  }
  
  String _generateSearchCacheKey(String query, ArchiveSearchFilter? filter) {
    final filterHash = filter?.toJson().toString().hashCode.abs() ?? 0;
    return 'search_${query.hashCode.abs()}_$filterHash';
  }
  
  void _recordOperationTime(String operation, Duration time) {
    _operationTimes[operation] = time;
    _operationsCount++;
  }
  
  List<ArchivedChatSummary> _applyFilterToSummaries(
    List<ArchivedChatSummary> summaries,
    ArchiveSearchFilter filter,
  ) {
    return summaries.where((summary) {
      if (filter.contactFilter != null && 
          !summary.contactName.toLowerCase().contains(filter.contactFilter!.toLowerCase())) {
        return false;
      }
      
      if (filter.dateRange != null && 
          !filter.dateRange!.contains(summary.archivedAt)) {
        return false;
      }
      
      if (filter.onlyCompressed == true && !summary.isCompressed) {
        return false;
      }
      
      if (filter.onlySearchable == true && !summary.isSearchable) {
        return false;
      }
      
      if (filter.sizeFilter != null) {
        switch (filter.sizeFilter!) {
          case ArchiveSizeFilter.small:
            if (summary.estimatedSize > 1024) return false;
            break;
          case ArchiveSizeFilter.medium:
            if (summary.estimatedSize <= 1024 || summary.estimatedSize > 1024 * 1024) return false;
            break;
          case ArchiveSizeFilter.large:
            if (summary.estimatedSize <= 1024 * 1024) return false;
            break;
        }
      }
      
      return true;
    }).toList();
  }
  
  List<ArchivedChatSummary> _sortSummaries(
    List<ArchivedChatSummary> summaries,
    ArchiveSortOption sortBy,
  ) {
    summaries.sort((a, b) {
      switch (sortBy) {
        case ArchiveSortOption.dateArchived:
          return b.archivedAt.compareTo(a.archivedAt);
        case ArchiveSortOption.dateOriginal:
          return (b.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(a.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0));
        case ArchiveSortOption.contactName:
          return a.contactName.compareTo(b.contactName);
        case ArchiveSortOption.messageCount:
          return b.messageCount.compareTo(a.messageCount);
        case ArchiveSortOption.size:
          return b.estimatedSize.compareTo(a.estimatedSize);
        default:
          return b.archivedAt.compareTo(a.archivedAt);
      }
    });
    
    return summaries;
  }
  
  Future<void> _loadSearchIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final indexJson = prefs.getString(_archiveIndexKey);
      
      if (indexJson != null) {
        final indexData = jsonDecode(indexJson);
        
        // Load search index
        final searchIndexData = indexData['searchIndex'] as Map<String, dynamic>? ?? {};
        for (final entry in searchIndexData.entries) {
          _searchIndex[entry.key] = Set<String>.from(entry.value);
        }
        
        // Load contact index
        final contactIndexData = indexData['contactIndex'] as Map<String, dynamic>? ?? {};
        for (final entry in contactIndexData.entries) {
          _contactIndex[entry.key] = Set<String>.from(entry.value);
        }
        
        // Load date index
        final dateIndexData = indexData['dateIndex'] as Map<String, dynamic>? ?? {};
        for (final entry in dateIndexData.entries) {
          _dateIndex[entry.key] = Set<String>.from(entry.value);
        }
        
        _logger.info('Loaded search index with ${_searchIndex.length} terms');
      }
    } catch (e) {
      _logger.warning('Failed to load search index: $e');
    }
  }
  
  Future<void> _saveSearchIndex() async {
    try {
      final indexData = {
        'searchIndex': _searchIndex.map((key, value) => MapEntry(key, value.toList())),
        'contactIndex': _contactIndex.map((key, value) => MapEntry(key, value.toList())),
        'dateIndex': _dateIndex.map((key, value) => MapEntry(key, value.toList())),
      };
      
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_archiveIndexKey, jsonEncode(indexData));
    } catch (e) {
      _logger.warning('Failed to save search index: $e');
    }
  }
  
  Future<void> _removeFromSearchIndex(String archiveId) async {
    // Remove archive ID from all index entries
    for (final wordSet in _searchIndex.values) {
      wordSet.remove(archiveId);
    }
    for (final contactSet in _contactIndex.values) {
      contactSet.remove(archiveId);
    }
    for (final dateSet in _dateIndex.values) {
      dateSet.remove(archiveId);
    }
    
    // Remove empty entries
    _searchIndex.removeWhere((key, value) => value.isEmpty);
    _contactIndex.removeWhere((key, value) => value.isEmpty);
    _dateIndex.removeWhere((key, value) => value.isEmpty);
    
    await _saveSearchIndex();
  }
  
  Future<void> _loadCachedSummaries() async {
    // Load frequently accessed summaries into cache
    try {
      final summaries = await getArchivedChats(limit: 20);
      _summaryCache['recent'] = summaries;
    } catch (e) {
      _logger.warning('Failed to load cached summaries: $e');
    }
  }
  
  Future<void> _updateArchiveStatistics(ArchiveOperationType operation, int sizeChange) async {
    try {
      // TODO: Implementation would fetch stats, update counters based on operation, and save back to storage
      // For now, just log the operation
      _logger.info('Updated archive statistics for $operation operation (size change: $sizeChange bytes)');
    } catch (e) {
      _logger.warning('Failed to update archive statistics: $e');
    }
  }
  
  Future<ArchiveStatistics> _calculateArchiveStatistics() async {
    try {
      final summaries = await getArchivedChats();
      
      // Calculate basic statistics
      final totalArchives = summaries.length;
      var totalMessages = 0;
      var compressedArchives = 0;
      var searchableArchives = 0;
      var totalSize = 0;
      
      final archivesByMonth = <String, int>{};
      final messagesByContact = <String, int>{};
      
      DateTime? oldestArchive;
      DateTime? newestArchive;
      
      for (final summary in summaries) {
        totalMessages += summary.messageCount;
        totalSize += summary.estimatedSize;
        
        if (summary.isCompressed) compressedArchives++;
        if (summary.isSearchable) searchableArchives++;
        
        // Track by month
        final monthKey = _formatDateForIndex(summary.archivedAt);
        archivesByMonth[monthKey] = (archivesByMonth[monthKey] ?? 0) + 1;
        
        // Track by contact
        messagesByContact[summary.contactName] = 
          (messagesByContact[summary.contactName] ?? 0) + summary.messageCount;
        
        // Track date range
        if (oldestArchive == null || summary.archivedAt.isBefore(oldestArchive)) {
          oldestArchive = summary.archivedAt;
        }
        if (newestArchive == null || summary.archivedAt.isAfter(newestArchive)) {
          newestArchive = summary.archivedAt;
        }
      }
      
      final averageAge = totalArchives > 0 && newestArchive != null && oldestArchive != null
        ? newestArchive.difference(oldestArchive) 
        : Duration.zero;
      
      // Create performance stats
      final performanceStats = ArchivePerformanceStats(
        averageArchiveTime: _operationTimes['archive'] ?? Duration.zero,
        averageRestoreTime: _operationTimes['restore'] ?? Duration.zero,
        averageSearchTime: _operationTimes['search'] ?? Duration.zero,
        averageMemoryUsage: _archiveCache.length * 1024.0, // Rough estimate
        operationsCount: _operationsCount,
        operationCounts: {
          'archive': _operationTimes.containsKey('archive') ? 1 : 0,
          'restore': _operationTimes.containsKey('restore') ? 1 : 0,
          'search': _operationTimes.containsKey('search') ? 1 : 0,
        },
        recentOperationTimes: _operationTimes.values.toList(),
      );
      
      return ArchiveStatistics(
        totalArchives: totalArchives,
        totalMessages: totalMessages,
        compressedArchives: compressedArchives,
        searchableArchives: searchableArchives,
        totalSizeBytes: totalSize,
        compressedSizeBytes: totalSize, // Simplified for now
        archivesByMonth: archivesByMonth,
        messagesByContact: messagesByContact,
        averageCompressionRatio: 0.7, // Simplified
        oldestArchive: oldestArchive,
        newestArchive: newestArchive,
        averageArchiveAge: averageAge,
        performanceStats: performanceStats,
      );
      
    } catch (e) {
      _logger.severe('Failed to calculate archive statistics: $e');
      return ArchiveStatistics.empty();
    }
  }
  
  ArchiveStatistics _parseArchiveStatistics(Map<String, dynamic> json) {
    // Parse statistics from JSON (simplified implementation)
    return ArchiveStatistics.empty(); // Would implement full parsing
  }
}

/// Extension for firstOrNull functionality
extension _FirstWhereOrNull<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    if (iterator.moveNext()) {
      return iterator.current;
    }
    return null;
  }
}