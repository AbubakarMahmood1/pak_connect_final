/// Supplementary tests for archive_models.dart
/// Covers: factory constructors, computed getters, formatters,
/// serialization round-trips, search result metadata helpers.
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
 group('ArchiveSearchResult', () {
 test('empty() creates result with zero counts', () {
 final result = ArchiveSearchResult.empty('test query');
 expect(result.query, 'test query');
 expect(result.totalResults, 0);
 expect(result.totalChatsFound, 0);
 expect(result.hasMore, false);
 expect(result.hasResults, false);
 expect(result.messages, isEmpty);
 expect(result.chats, isEmpty);
 });

 test('hasResults is true when totalResults > 0', () {
 final result = ArchiveSearchResult(messages: [],
 chats: [],
 messagesByChat: {},
 query: 'q',
 totalResults: 5,
 totalChatsFound: 0,
 searchTime: Duration.zero,
 hasMore: false,
 metadata: ArchiveSearchMetadata.empty(),
);
 expect(result.hasResults, true);
 });

 test('formattedSearchTime shows ms for fast searches', () {
 final result = ArchiveSearchResult(messages: [],
 chats: [],
 messagesByChat: {},
 query: 'q',
 totalResults: 0,
 totalChatsFound: 0,
 searchTime: const Duration(milliseconds: 42),
 hasMore: false,
 metadata: ArchiveSearchMetadata.empty(),
);
 expect(result.formattedSearchTime, '42ms');
 });

 test('formattedSearchTime shows seconds for slow searches', () {
 final result = ArchiveSearchResult(messages: [],
 chats: [],
 messagesByChat: {},
 query: 'q',
 totalResults: 0,
 totalChatsFound: 0,
 searchTime: const Duration(milliseconds: 1500),
 hasMore: false,
 metadata: ArchiveSearchMetadata.empty(),
);
 expect(result.formattedSearchTime, '1.50s');
 });

 test('searchQuality is 0 when no results', () {
 final result = ArchiveSearchResult.empty();
 expect(result.searchQuality, 0.0);
 });

 test('searchQuality gives bonus for fast + relevant results', () {
 final result = ArchiveSearchResult(messages: [],
 chats: [],
 messagesByChat: {},
 query: 'test',
 totalResults: 5,
 totalChatsFound: 2,
 searchTime: const Duration(milliseconds: 50),
 hasMore: false,
 metadata: ArchiveSearchMetadata.empty(),
);
 // base 0.5 + fast(0.2) + relevant results(0.2) + few chats(0.1) = 1.0
 expect(result.searchQuality, closeTo(1.0, 0.01));
 });
 });

 group('ArchiveSearchMetadata', () {
 test('empty() creates default metadata', () {
 final meta = ArchiveSearchMetadata.empty();
 expect(meta.searchType, ArchiveSearchType.simpleTerm);
 expect(meta.indexesUsed, isEmpty);
 expect(meta.relatedQueries, isEmpty);
 });
 });

 group('ArchiveSearchFilter', () {
 test('recent() creates date-filtered sort', () {
 final filter = ArchiveSearchFilter.recent(days: 7);
 expect(filter.dateRange, isNotNull);
 expect(filter.sortBy, ArchiveSortOption.dateArchived);
 });

 test('forContact() creates contact-filtered', () {
 final filter = ArchiveSearchFilter.forContact('Alice');
 expect(filter.contactFilter, 'Alice');
 expect(filter.sortBy, ArchiveSortOption.dateArchived);
 });

 test('largeArchives() creates size-filtered', () {
 final filter = ArchiveSearchFilter.largeArchives();
 expect(filter.sizeFilter, ArchiveSizeFilter.large);
 expect(filter.sortBy, ArchiveSortOption.size);
 });

 test('toJson/fromJson round-trip preserves fields', () {
 final original = ArchiveSearchFilter(contactFilter: 'Bob',
 tags: ['important'],
 onlyCompressed: true,
 onlySearchable: false,
 sortBy: ArchiveSortOption.dateOriginal,
 ascending: true,
 limit: 50,
 afterCursor: 'cursor123',
);

 final json = original.toJson();
 final restored = ArchiveSearchFilter.fromJson(json);

 expect(restored.contactFilter, 'Bob');
 expect(restored.tags, ['important']);
 expect(restored.onlyCompressed, true);
 expect(restored.onlySearchable, false);
 expect(restored.sortBy, ArchiveSortOption.dateOriginal);
 expect(restored.ascending, true);
 expect(restored.limit, 50);
 expect(restored.afterCursor, 'cursor123');
 });

 test('fromJson handles null optional fields', () {
 final json = <String, dynamic>{
 'contactFilter': null,
 'dateRange': null,
 'tags': null,
 'messageTypeFilter': null,
 'sizeFilter': null,
 'onlyCompressed': null,
 'onlySearchable': null,
 'sortBy': null,
 'ascending': null,
 'limit': null,
 'afterCursor': null,
 };
 final restored = ArchiveSearchFilter.fromJson(json);
 expect(restored.contactFilter, isNull);
 expect(restored.dateRange, isNull);
 expect(restored.sortBy, ArchiveSortOption.relevance);
 expect(restored.ascending, false);
 });
 });

 group('ArchiveDateRange', () {
 test('lastDays() creates correct range', () {
 final range = ArchiveDateRange.lastDays(7);
 final diff = range.end.difference(range.start).inDays;
 expect(diff, 7);
 });

 test('lastMonths() creates correct range', () {
 final range = ArchiveDateRange.lastMonths(3);
 expect(range.start.isBefore(range.end), true);
 });

 test('month() creates range for specific month', () {
 final range = ArchiveDateRange.month(2025, 6);
 expect(range.start, DateTime(2025, 6, 1));
 expect(range.end, DateTime(2025, 6, 30));
 });

 test('contains() checks date within range', () {
 final range = ArchiveDateRange(start: DateTime(2025, 1, 1),
 end: DateTime(2025, 12, 31),
);
 expect(range.contains(DateTime(2025, 6, 15)), true);
 expect(range.contains(DateTime(2024, 6, 15)), false);
 // Boundary: exactly at start
 expect(range.contains(DateTime(2025, 1, 1)), true);
 // Boundary: exactly at end
 expect(range.contains(DateTime(2025, 12, 31)), true);
 });

 test('duration returns correct value', () {
 final range = ArchiveDateRange(start: DateTime(2025, 1, 1),
 end: DateTime(2025, 1, 11),
);
 expect(range.duration.inDays, 10);
 });

 test('toJson/fromJson round-trip', () {
 final original = ArchiveDateRange(start: DateTime(2025, 3, 1),
 end: DateTime(2025, 3, 31),
);
 final json = original.toJson();
 final restored = ArchiveDateRange.fromJson(json);
 expect(restored.start, original.start);
 expect(restored.end, original.end);
 });
 });

 group('ArchiveMessageTypeFilter', () {
 test('toJson/fromJson round-trip with all fields', () {
 final original = ArchiveMessageTypeFilter(hasAttachments: true,
 wasStarred: false,
 wasEdited: true,
 isFromMe: false,
 priorities: [MessagePriorityFilter.high, MessagePriorityFilter.urgent],
 contentTypes: ['text', 'image'],
);
 final json = original.toJson();
 final restored = ArchiveMessageTypeFilter.fromJson(json);
 expect(restored.hasAttachments, true);
 expect(restored.wasStarred, false);
 expect(restored.wasEdited, true);
 expect(restored.isFromMe, false);
 expect(restored.priorities!.length, 2);
 expect(restored.contentTypes, ['text', 'image']);
 });

 test('fromJson handles null priorities and contentTypes', () {
 final json = <String, dynamic>{
 'hasAttachments': null,
 'wasStarred': null,
 'wasEdited': null,
 'isFromMe': null,
 'priorities': null,
 'contentTypes': null,
 };
 final restored = ArchiveMessageTypeFilter.fromJson(json);
 expect(restored.priorities, isNull);
 expect(restored.contentTypes, isNull);
 });
 });

 group('ArchiveOperationResult', () {
 test('success() creates successful result', () {
 final result = ArchiveOperationResult.success(message: 'Archived OK',
 operationType: ArchiveOperationType.archive,
 archiveId: ArchiveId('arc-1'),
 operationTime: const Duration(milliseconds: 100),
);
 expect(result.success, true);
 expect(result.hasError, false);
 expect(result.hasWarnings, false);
 });

 test('failure() creates failed result', () {
 final error = ArchiveError.storageError('Disk full');
 final result = ArchiveOperationResult.failure(message: 'Failed to archive',
 operationType: ArchiveOperationType.archive,
 operationTime: const Duration(seconds: 2),
 error: error,
 warnings: ['Low disk space'],
);
 expect(result.success, false);
 expect(result.hasError, true);
 expect(result.hasWarnings, true);
 });

 test('formattedOperationTime shows ms for fast ops', () {
 final result = ArchiveOperationResult.success(message: 'OK',
 operationType: ArchiveOperationType.search,
 operationTime: const Duration(milliseconds: 55),
);
 expect(result.formattedOperationTime, '55ms');
 });

 test('formattedOperationTime shows seconds for slow ops', () {
 final result = ArchiveOperationResult.success(message: 'OK',
 operationType: ArchiveOperationType.compress,
 operationTime: const Duration(milliseconds: 2345),
);
 expect(result.formattedOperationTime, '2.35s');
 });
 });

 group('ArchiveStatistics', () {
 test('empty() creates zeroed stats', () {
 final stats = ArchiveStatistics.empty();
 expect(stats.totalArchives, 0);
 expect(stats.totalMessages, 0);
 expect(stats.compressionEfficiency, 0.0);
 expect(stats.searchablePercentage, 0.0);
 });

 test('compressionEfficiency calculates correctly', () {
 final stats = ArchiveStatistics(totalArchives: 10,
 totalMessages: 100,
 compressedArchives: 5,
 searchableArchives: 8,
 totalSizeBytes: 10000,
 compressedSizeBytes: 7000,
 archivesByMonth: {},
 messagesByContact: {},
 averageCompressionRatio: 0.7,
 averageArchiveAge: Duration.zero,
 performanceStats: ArchivePerformanceStats.empty(),
);
 // (10000 - 7000) / 10000 * 100 = 30%
 expect(stats.compressionEfficiency, closeTo(30.0, 0.01));
 });

 test('searchablePercentage calculates correctly', () {
 final stats = ArchiveStatistics(totalArchives: 20,
 totalMessages: 100,
 compressedArchives: 5,
 searchableArchives: 15,
 totalSizeBytes: 10000,
 compressedSizeBytes: 7000,
 archivesByMonth: {},
 messagesByContact: {},
 averageCompressionRatio: 0.7,
 averageArchiveAge: Duration.zero,
 performanceStats: ArchivePerformanceStats.empty(),
);
 expect(stats.searchablePercentage, closeTo(75.0, 0.01));
 });

 test('formattedTotalSize formats bytes', () {
 final stats = ArchiveStatistics(totalArchives: 1,
 totalMessages: 1,
 compressedArchives: 0,
 searchableArchives: 0,
 totalSizeBytes: 500,
 compressedSizeBytes: 0,
 archivesByMonth: {},
 messagesByContact: {},
 averageCompressionRatio: 0.0,
 averageArchiveAge: Duration.zero,
 performanceStats: ArchivePerformanceStats.empty(),
);
 expect(stats.formattedTotalSize, '500B');
 });

 test('formattedTotalSize formats KB', () {
 final stats = ArchiveStatistics(totalArchives: 1,
 totalMessages: 1,
 compressedArchives: 0,
 searchableArchives: 0,
 totalSizeBytes: 5 * 1024,
 compressedSizeBytes: 0,
 archivesByMonth: {},
 messagesByContact: {},
 averageCompressionRatio: 0.0,
 averageArchiveAge: Duration.zero,
 performanceStats: ArchivePerformanceStats.empty(),
);
 expect(stats.formattedTotalSize, '5.0KB');
 });

 test('formattedTotalSize formats MB', () {
 final stats = ArchiveStatistics(totalArchives: 1,
 totalMessages: 1,
 compressedArchives: 0,
 searchableArchives: 0,
 totalSizeBytes: 5 * 1024 * 1024,
 compressedSizeBytes: 0,
 archivesByMonth: {},
 messagesByContact: {},
 averageCompressionRatio: 0.0,
 averageArchiveAge: Duration.zero,
 performanceStats: ArchivePerformanceStats.empty(),
);
 expect(stats.formattedTotalSize, '5.0MB');
 });

 test('formattedTotalSize formats GB', () {
 final stats = ArchiveStatistics(totalArchives: 1,
 totalMessages: 1,
 compressedArchives: 0,
 searchableArchives: 0,
 totalSizeBytes: 2 * 1024 * 1024 * 1024,
 compressedSizeBytes: 0,
 archivesByMonth: {},
 messagesByContact: {},
 averageCompressionRatio: 0.0,
 averageArchiveAge: Duration.zero,
 performanceStats: ArchivePerformanceStats.empty(),
);
 expect(stats.formattedTotalSize, '2.00GB');
 });

 test('formattedCompressedSize uses _formatBytes', () {
 final stats = ArchiveStatistics(totalArchives: 1,
 totalMessages: 1,
 compressedArchives: 0,
 searchableArchives: 0,
 totalSizeBytes: 0,
 compressedSizeBytes: 2048,
 archivesByMonth: {},
 messagesByContact: {},
 averageCompressionRatio: 0.0,
 averageArchiveAge: Duration.zero,
 performanceStats: ArchivePerformanceStats.empty(),
);
 expect(stats.formattedCompressedSize, '2.0KB');
 });
 });

 group('ArchivePerformanceStats', () {
 test('empty() creates default perf stats', () {
 final perf = ArchivePerformanceStats.empty();
 expect(perf.operationsCount, 0);
 expect(perf.isPerformanceAcceptable, true);
 });

 test('isPerformanceAcceptable is false when archive too slow', () {
 final perf = ArchivePerformanceStats(averageArchiveTime: const Duration(seconds: 5),
 averageRestoreTime: Duration.zero,
 averageSearchTime: Duration.zero,
 averageMemoryUsage: 0,
 operationsCount: 10,
 operationCounts: {},
 recentOperationTimes: [],
);
 expect(perf.isPerformanceAcceptable, false);
 });

 test('isPerformanceAcceptable is false when memory too high', () {
 final perf = ArchivePerformanceStats(averageArchiveTime: Duration.zero,
 averageRestoreTime: Duration.zero,
 averageSearchTime: Duration.zero,
 averageMemoryUsage: 30 * 1024 * 1024, // 30MB > 20MB limit
 operationsCount: 10,
 operationCounts: {},
 recentOperationTimes: [],
);
 expect(perf.isPerformanceAcceptable, false);
 });
 });

 group('ArchiveError', () {
 test('storageError factory', () {
 final err = ArchiveError.storageError('Disk full', {'free': 0});
 expect(err.type, ArchiveErrorType.storage);
 expect(err.code, 'STORAGE_ERROR');
 expect(err.message, 'Disk full');
 expect(err.details, {'free': 0});
 });

 test('compressionError factory', () {
 final err = ArchiveError.compressionError('Out of memory');
 expect(err.type, ArchiveErrorType.compression);
 expect(err.code, 'COMPRESSION_ERROR');
 });

 test('searchError factory', () {
 final err = ArchiveError.searchError('Index corrupt');
 expect(err.type, ArchiveErrorType.search);
 expect(err.code, 'SEARCH_ERROR');
 });
 });
}
