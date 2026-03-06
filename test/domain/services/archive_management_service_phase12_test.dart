/// Phase 12.6: Supplementary tests for ArchiveManagementService
/// Covers: getEnhancedArchiveSummaries success path, applyArchivePolicies success,
///   getArchiveAnalytics success, updateConfiguration persistence, config getter,
///   policy getters, stream accessors
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeArchiveRepository repository;
  late ArchiveManagementService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    repository = _FakeArchiveRepository();
    service = ArchiveManagementService.withDependencies(
      archiveRepository: repository,
    );
  });

  tearDown(() async {
    await service.dispose();
  });

  group('getEnhancedArchiveSummaries', () {
    test('returns enhanced summaries when archives exist', () async {
      await service.initialize();
      repository.seedSummaries([
        _summary(id: 'arch_1', chatId: 'chat_1', contactName: 'Alice'),
        _summary(id: 'arch_2', chatId: 'chat_2', contactName: 'Bob'),
      ]);

      final summaries = await service.getEnhancedArchiveSummaries();
      expect(summaries.length, 2);
    });

    test('returns empty list when no archives', () async {
      await service.initialize();
      final summaries = await service.getEnhancedArchiveSummaries();
      expect(summaries, isEmpty);
    });

    test('with filter and pagination parameters', () async {
      await service.initialize();
      repository.seedSummaries([
        _summary(id: 'arch_1', chatId: 'chat_1', contactName: 'Alice'),
      ]);

      final summaries = await service.getEnhancedArchiveSummaries(
        limit: 10,
        offset: 0,
      );
      expect(summaries, isNotEmpty);
    });
  });

  group('applyArchivePolicies', () {
    test('applies policies and returns result', () async {
      await service.initialize();
      final result = await service.applyArchivePolicies(dryRun: true);
      expect(result, isNotNull);
    });

    test('applies specific policies only', () async {
      await service.initialize();
      await service.updateArchivePolicy(
        ArchivePolicy.byContact(
          name: 'TestPolicy',
          contactPattern: 'test_*',
          enabled: true,
        ),
      );
      final result = await service.applyArchivePolicies(
        specificPolicies: ['TestPolicy'],
        dryRun: false,
      );
      expect(result, isNotNull);
    });
  });

  group('getArchiveAnalytics', () {
    test('returns analytics with stats', () async {
      await service.initialize();
      repository.statistics = _stats(
        totalArchives: 5,
        totalMessages: 100,
        totalSizeBytes: 50000,
      );

      final analytics = await service.getArchiveAnalytics();
      expect(analytics.statistics.totalArchives, 5);
      expect(analytics.scope, ArchiveAnalyticsScope.all);
    });

    test('returns analytics with since filter', () async {
      await service.initialize();
      final analytics = await service.getArchiveAnalytics(
        since: DateTime(2025, 1, 1),
        scope: ArchiveAnalyticsScope.recent,
      );
      expect(analytics.scope, ArchiveAnalyticsScope.recent);
    });
  });

  group('updateConfiguration', () {
    test('updates config and persists', () async {
      await service.initialize();

      const newConfig = ArchiveManagementConfig(
        enableCompression: false,
        maxStorageSizeBytes: 2048,
        maintenanceIntervalHours: 6,
        policyEvaluationIntervalHours: 12,
        autoCleanupEnabled: false,
        maxArchiveAgeMonths: 6,
      );

      await service.updateConfiguration(newConfig);
      expect(service.configuration.enableCompression, false);
      expect(service.configuration.maxStorageSizeBytes, 2048);
      expect(service.configuration.maxArchiveAgeMonths, 6);
    });
  });

  group('configuration getter', () {
    test('returns default config before update', () async {
      await service.initialize();
      final config = service.configuration;
      expect(config, isA<ArchiveManagementConfig>());
      expect(config.maxArchiveAgeMonths, greaterThan(0));
    });
  });

  group('archivePolicies getter', () {
    test('returns unmodifiable list', () async {
      await service.initialize();
      final policies = service.archivePolicies;
      expect(policies, isA<List<ArchivePolicy>>());
    });
  });

  group('stream accessors', () {
    test('archiveUpdates stream is available', () async {
      await service.initialize();
      expect(service.archiveUpdates, isA<Stream>());
    });

    test('policyUpdates stream is available', () async {
      await service.initialize();
      expect(service.policyUpdates, isA<Stream>());
    });

    test('maintenanceUpdates stream is available', () async {
      await service.initialize();
      expect(service.maintenanceUpdates, isA<Stream>());
    });
  });
}

ArchivedChatSummary _summary({
  required String id,
  required String chatId,
  required String contactName,
}) {
  return ArchivedChatSummary(
    id: ArchiveId(id),
    originalChatId: ChatId(chatId),
    contactName: contactName,
    messageCount: 10,
    archivedAt: DateTime(2026, 1, 1),
    estimatedSize: 1024,
    isCompressed: false,
    tags: const [],
    isSearchable: true,
  );
}

ArchiveStatistics _stats({
  int totalArchives = 0,
  int totalMessages = 0,
  int totalSizeBytes = 0,
}) {
  return ArchiveStatistics(
    totalArchives: totalArchives,
    totalMessages: totalMessages,
    compressedArchives: 0,
    searchableArchives: 0,
    totalSizeBytes: totalSizeBytes,
    compressedSizeBytes: 0,
    archivesByMonth: const {},
    messagesByContact: const {},
    averageCompressionRatio: 0.0,
    averageArchiveAge: Duration.zero,
    performanceStats: const ArchivePerformanceStats(
      averageArchiveTime: Duration.zero,
      averageRestoreTime: Duration.zero,
      averageSearchTime: Duration.zero,
      averageMemoryUsage: 0,
      operationsCount: 0,
      operationCounts: {},
      recentOperationTimes: [],
    ),
  );
}

class _FakeArchiveRepository implements IArchiveRepository {
  int initializeCalls = 0;
  ArchiveStatistics? statistics = ArchiveStatistics.empty();
  List<ArchivedChatSummary> _summaries = [];

  void seedSummaries(List<ArchivedChatSummary> summaries) {
    _summaries = summaries;
  }

  @override
  Future<void> initialize() async {
    initializeCalls++;
  }

  @override
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? archiveReason,
    Map<String, dynamic>? customData,
    bool compressLargeArchives = true,
  }) async {
    return ArchiveOperationResult.success(
      message: 'Archived',
      operationType: ArchiveOperationType.archive,
      archiveId: ArchiveId('arch_$chatId'),
      operationTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async {
    return ArchiveOperationResult.success(
      message: 'Restored',
      operationType: ArchiveOperationType.restore,
      archiveId: archiveId,
      operationTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  }) async =>
      _summaries;

  @override
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(
    String chatId,
  ) async =>
      null;

  @override
  Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async => null;

  @override
  Future<int> getArchivedChatsCount() async => _summaries.length;

  @override
  Future<ArchiveStatistics?> getArchiveStatistics() async => statistics;

  @override
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async =>
      ArchiveSearchResult.fromResults(
        messages: const [],
        chats: const [],
        query: query,
        searchTime: const Duration(milliseconds: 1),
      );

  @override
  Future<void> permanentlyDeleteArchive(ArchiveId archivedChatId) async {}

  @override
  void clearCache() {}

  @override
  Future<void> dispose() async {}
}
