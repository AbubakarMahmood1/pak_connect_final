import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pak_connect/domain/entities/archived_chat.dart';
import 'package:pak_connect/domain/entities/archived_message.dart';
import 'package:pak_connect/domain/entities/message.dart';
import 'package:pak_connect/domain/interfaces/i_archive_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_management_models.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/values/id_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArchiveManagementService', () {
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

    test('initialize is idempotent and loads default policies', () async {
      await service.initialize();
      await service.initialize();

      expect(repository.initializeCalls, 1);
      expect(service.archivePolicies.length, greaterThanOrEqualTo(1));
    });

    test('archiveChat throws when service is not initialized', () async {
      expect(
        () => service.archiveChat(chatId: 'chat_uninitialized'),
        throwsA(isA<StateError>()),
      );
    });

    test('archiveChat succeeds, enriches metadata, and emits archived event', () async {
      await service.initialize();
      final eventFuture = service.archiveUpdates.first;

      final result = await service.archiveChat(
        chatId: 'chat_1',
        reason: 'manual',
        metadata: const {'source': 'test'},
      );

      expect(result.success, isTrue);
      expect(repository.lastArchiveRequestChatId, 'chat_1');
      expect(repository.lastArchiveRequestReason, 'manual');
      expect(repository.lastArchiveRequestCustomData, isNotNull);
      expect(
        repository.lastArchiveRequestCustomData!['archiveReason'],
        'manual',
      );
      expect(
        repository.lastArchiveRequestCustomData!.containsKey('businessContext'),
        isTrue,
      );
      expect(
        repository.lastArchiveRequestCustomData!.containsKey(
          'storageOptimization',
        ),
        isTrue,
      );

      final event = await eventFuture.timeout(const Duration(seconds: 1));
      expect(event.type, ArchiveUpdateEventType.archived);
      expect(event.chatId, 'chat_1');
    });

    test('archiveChat rejects duplicate in-flight operations for same chat', () async {
      await service.initialize();
      repository.archiveDelay = const Duration(milliseconds: 120);

      final first = service.archiveChat(chatId: 'chat_busy');
      final second = await service.archiveChat(chatId: 'chat_busy');

      expect(second.success, isFalse);
      expect(second.message, contains('already in progress'));
      expect((await first).success, isTrue);
    });

    test('restoreChat returns failure when archive is missing', () async {
      await service.initialize();

      final result = await service.restoreChat(archiveId: ArchiveId('missing'));

      expect(result.success, isFalse);
      expect(result.message, contains('Archive not found'));
    });

    test('restoreChat succeeds and emits restored event', () async {
      await service.initialize();
      final archiveId = repository.seedArchive('chat_restore');
      final eventFuture = service.archiveUpdates.firstWhere(
        (e) => e.type == ArchiveUpdateEventType.restored,
      );

      final result = await service.restoreChat(archiveId: archiveId);

      expect(result.success, isTrue);
      final event = await eventFuture.timeout(const Duration(seconds: 1));
      expect(event.type, ArchiveUpdateEventType.restored);
      expect(event.chatId, 'chat_restore');
      expect(event.archiveId, archiveId);
    });

    test('updateArchivePolicy and removeArchivePolicy update list and emit events', () async {
      await service.initialize();
      final events = <ArchivePolicyEvent>[];
      final sub = service.policyUpdates.listen(events.add);

      final policy = ArchivePolicy.byContact(
        name: 'Archive Work Contacts',
        contactPattern: 'work_*',
        enabled: true,
      );

      await service.updateArchivePolicy(policy);
      expect(
        service.archivePolicies.any((p) => p.name == 'Archive Work Contacts'),
        isTrue,
      );

      await service.removeArchivePolicy('Archive Work Contacts');
      expect(
        service.archivePolicies.any((p) => p.name == 'Archive Work Contacts'),
        isFalse,
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(events.any((e) => e.type == ArchivePolicyEventType.updated), isTrue);
      expect(events.any((e) => e.type == ArchivePolicyEventType.removed), isTrue);

      await sub.cancel();
    });

    test('getHealthStatus reports critical when storage exceeds limits', () async {
      await service.initialize();
      repository.statistics = ArchiveStatistics(
        totalArchives: 3,
        totalMessages: 100,
        compressedArchives: 1,
        searchableArchives: 2,
        totalSizeBytes: 5 * 1024,
        compressedSizeBytes: 3 * 1024,
        archivesByMonth: const {},
        messagesByContact: const {},
        averageCompressionRatio: 0.7,
        averageArchiveAge: const Duration(days: 3),
        performanceStats: const ArchivePerformanceStats(
          averageArchiveTime: Duration(seconds: 4),
          averageRestoreTime: Duration(seconds: 4),
          averageSearchTime: Duration(milliseconds: 900),
          averageMemoryUsage: 25 * 1024 * 1024,
          operationsCount: 10,
          operationCounts: {},
          recentOperationTimes: [],
        ),
      );

      await service.updateConfiguration(
        const ArchiveManagementConfig(
          enableCompression: true,
          maxStorageSizeBytes: 1024,
          maintenanceIntervalHours: 0,
          policyEvaluationIntervalHours: 0,
          autoCleanupEnabled: true,
          maxArchiveAgeMonths: 12,
        ),
      );

      final health = await service.getHealthStatus();

      expect(health.level, ArchiveHealthLevel.critical);
      expect(
        health.issues.any((issue) => issue.description.contains('over limit')),
        isTrue,
      );
      expect(
        health.issues.any(
          (issue) => issue.description.contains('performance degraded'),
        ),
        isTrue,
      );
    });

    test('performMaintenance emits task lifecycle events', () async {
      await service.initialize();
      final events = <ArchiveMaintenanceEvent>[];
      final sub = service.maintenanceUpdates.listen(events.add);

      final result = await service.performMaintenance(
        tasks: {
          ArchiveMaintenanceTask.cleanupOrphaned,
          ArchiveMaintenanceTask.removeExpired,
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(result.tasksPerformed.length, 2);
      expect(
        events.where((e) => e.type == ArchiveMaintenanceEventType.started).length,
        2,
      );
      expect(
        events.where((e) => e.type == ArchiveMaintenanceEventType.completed).length,
        greaterThanOrEqualTo(2),
      );

      await sub.cancel();
    });

    test('archiveChat requires re-initialization after dispose', () async {
      await service.initialize();
      await service.dispose();

      expect(
        () => service.archiveChat(chatId: 'chat_after_dispose'),
        throwsA(isA<StateError>()),
      );
    });
  });
}

class _FakeArchiveRepository implements IArchiveRepository {
  int initializeCalls = 0;
  int disposeCalls = 0;
  Duration archiveDelay = Duration.zero;

  String? lastArchiveRequestChatId;
  String? lastArchiveRequestReason;
  Map<String, dynamic>? lastArchiveRequestCustomData;
  bool? lastArchiveCompressLargeFlag;

  ArchiveStatistics? statistics = ArchiveStatistics.empty();
  final Map<String, ArchivedChat> _archivesById = {};

  ArchiveId seedArchive(String chatId) {
    final archiveId = ArchiveId('arch_$chatId');
    _archivesById[archiveId.value] = _buildArchivedChat(archiveId, chatId);
    return archiveId;
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
    if (archiveDelay > Duration.zero) {
      await Future<void>.delayed(archiveDelay);
    }

    lastArchiveRequestChatId = chatId;
    lastArchiveRequestReason = archiveReason;
    lastArchiveRequestCustomData = customData;
    lastArchiveCompressLargeFlag = compressLargeArchives;

    final archiveId = ArchiveId('arch_$chatId');
    _archivesById[archiveId.value] = _buildArchivedChat(
      archiveId,
      chatId,
      reason: archiveReason,
      customData: customData,
    );

    return ArchiveOperationResult.success(
      message: 'Archived',
      operationType: ArchiveOperationType.archive,
      archiveId: archiveId,
      operationTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<ArchiveOperationResult> restoreChat(ArchiveId archiveId) async {
    if (!_archivesById.containsKey(archiveId.value)) {
      return ArchiveOperationResult.failure(
        message: 'Missing archive',
        operationType: ArchiveOperationType.restore,
        operationTime: Duration.zero,
      );
    }

    return ArchiveOperationResult.success(
      message: 'Restored',
      operationType: ArchiveOperationType.restore,
      archiveId: archiveId,
      operationTime: const Duration(milliseconds: 5),
    );
  }

  @override
  Future<int> getArchivedChatsCount() async => _archivesById.length;

  @override
  Future<List<ArchivedChatSummary>> getArchivedChats({
    ArchiveSearchFilter? filter,
    int? limit,
    int? offset,
  }) async {
    var summaries = _archivesById.values.map((a) => a.toSummary()).toList();
    if (filter?.contactFilter != null) {
      summaries = summaries
          .where((s) => s.originalChatId.value == filter!.contactFilter)
          .toList();
    }
    return summaries;
  }

  @override
  Future<ArchivedChatSummary?> getArchivedChatByOriginalId(String chatId) async {
    return _archivesById.values
        .map((archive) => archive.toSummary())
        .where((summary) => summary.originalChatId.value == chatId)
        .firstOrNull;
  }

  @override
  Future<ArchivedChat?> getArchivedChat(ArchiveId archiveId) async =>
      _archivesById[archiveId.value];

  @override
  Future<ArchiveSearchResult> searchArchives({
    required String query,
    ArchiveSearchFilter? filter,
    int? limit,
    String? afterCursor,
  }) async => ArchiveSearchResult.empty(query);

  @override
  Future<void> permanentlyDeleteArchive(ArchiveId archivedChatId) async {
    _archivesById.remove(archivedChatId.value);
  }

  @override
  Future<ArchiveStatistics?> getArchiveStatistics() async => statistics;

  @override
  void clearCache() {}

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

ArchivedChat _buildArchivedChat(
  ArchiveId archiveId,
  String chatId, {
  String? reason,
  Map<String, dynamic>? customData,
}) {
  final archivedAt = DateTime(2026, 1, 1, 12);
  final message = Message(
    id: MessageId('msg_$chatId'),
    chatId: ChatId(chatId),
    content: 'Archived content',
    timestamp: DateTime(2025, 12, 31, 23, 55),
    isFromMe: true,
    status: MessageStatus.delivered,
  );

  return ArchivedChat(
    id: archiveId,
    originalChatId: ChatId(chatId),
    contactName: 'Contact $chatId',
    archivedAt: archivedAt,
    lastMessageTime: message.timestamp,
    messageCount: 1,
    metadata: ArchiveMetadata(
      version: '1.0',
      reason: reason ?? 'seed',
      originalUnreadCount: 0,
      wasOnline: false,
      hadUnsentMessages: false,
      estimatedStorageSize: 512,
      archiveSource: 'test',
      tags: const [],
    ),
    messages: [
      ArchivedMessage.fromMessage(
        message,
        archivedAt,
        customArchiveId: archiveId,
      ),
    ],
    customData: customData,
  );
}
