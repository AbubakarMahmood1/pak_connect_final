import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/entities/chat_list_item.dart';
import 'package:pak_connect/domain/entities/preference_keys.dart';
import 'package:pak_connect/domain/interfaces/i_chats_repository.dart';
import 'package:pak_connect/domain/interfaces/i_preferences_repository.dart';
import 'package:pak_connect/domain/models/archive_models.dart';
import 'package:pak_connect/domain/services/archive_management_service.dart';
import 'package:pak_connect/domain/services/auto_archive_scheduler.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

void main() {
  group('AutoArchiveScheduler', () {
    late _MemoryPreferencesRepository preferences;
    late _FakeChatsRepository chatsRepository;
    late _FakeArchiveManagementService archiveService;

    setUp(() {
      AutoArchiveScheduler.stop();
      AutoArchiveScheduler.clearConfiguration();

      preferences = _MemoryPreferencesRepository();
      chatsRepository = _FakeChatsRepository();
      archiveService = _FakeArchiveManagementService();
    });

    tearDown(() {
      AutoArchiveScheduler.stop();
      AutoArchiveScheduler.clearConfiguration();
    });

    test('start is a no-op when dependencies are not configured', () async {
      await AutoArchiveScheduler.start();
      expect(AutoArchiveScheduler.isRunning, isFalse);
    });

    test('start respects disabled setting and does not run checks', () async {
      _configure(
        preferences: preferences,
        chatsRepository: chatsRepository,
        archiveService: archiveService,
      );
      preferences.boolValues[PreferenceKeys.autoArchiveOldChats] = false;

      await AutoArchiveScheduler.start();

      expect(AutoArchiveScheduler.isRunning, isFalse);
      expect(chatsRepository.getAllChatsCalls, 0);
    });

    test('checkNow archives inactive chats and skips recent/null chats', () async {
      _configure(
        preferences: preferences,
        chatsRepository: chatsRepository,
        archiveService: archiveService,
      );
      preferences.boolValues[PreferenceKeys.autoArchiveOldChats] = true;
      preferences.intValues[PreferenceKeys.archiveAfterDays] = 30;
      chatsRepository.chats = <ChatListItem>[
        _chat('old-chat', 'Old', lastMessageDaysAgo: 45),
        _chat('recent-chat', 'Recent', lastMessageDaysAgo: 5),
        _chat('missing-time', 'Missing', includeLastMessageTime: false),
      ];
      archiveService.resultByChatId['old-chat'] = ArchiveOperationResult.success(
        message: 'archived',
        operationType: ArchiveOperationType.archive,
        operationTime: Duration.zero,
      );

      final count = await AutoArchiveScheduler.checkNow();

      expect(count, 1);
      expect(AutoArchiveScheduler.lastCheckTime, isNotNull);
      expect(archiveService.archivedChatIds, <String>['old-chat']);
    });

    test('restart and stop update running state while handling failures', () async {
      _configure(
        preferences: preferences,
        chatsRepository: chatsRepository,
        archiveService: archiveService,
      );
      preferences.boolValues[PreferenceKeys.autoArchiveOldChats] = true;
      preferences.intValues[PreferenceKeys.archiveAfterDays] = 30;
      chatsRepository.chats = <ChatListItem>[
        _chat('old-chat', 'Old', lastMessageDaysAgo: 60),
      ];
      archiveService.resultByChatId['old-chat'] = ArchiveOperationResult.failure(
        message: 'failed',
        operationType: ArchiveOperationType.archive,
        operationTime: Duration.zero,
      );

      await AutoArchiveScheduler.start();
      expect(AutoArchiveScheduler.isRunning, isTrue);
      await AutoArchiveScheduler.checkNow();
      expect(archiveService.archivedChatIds, <String>['old-chat']);

      await AutoArchiveScheduler.restart();
      expect(AutoArchiveScheduler.isRunning, isTrue);
      await AutoArchiveScheduler.checkNow();
      expect(archiveService.archivedChatIds.length, 2);

      AutoArchiveScheduler.stop();
      expect(AutoArchiveScheduler.isRunning, isFalse);
    });

    test('start catches preference exceptions and keeps scheduler stopped', () async {
      _configure(
        preferences: preferences,
        chatsRepository: chatsRepository,
        archiveService: archiveService,
      );
      preferences.throwOnGetBool = true;

      await AutoArchiveScheduler.start();

      expect(AutoArchiveScheduler.isRunning, isFalse);
    });
  });
}

void _configure({
  required IPreferencesRepository preferences,
  required IChatsRepository chatsRepository,
  required ArchiveManagementService archiveService,
}) {
  AutoArchiveScheduler.configure(
    preferencesRepository: preferences,
    chatsRepository: chatsRepository,
    archiveManagementService: archiveService,
  );
}

ChatListItem _chat(
  String chatId,
  String name, {
  int lastMessageDaysAgo = 1,
  bool includeLastMessageTime = true,
}) {
  return ChatListItem(
    chatId: ChatId(chatId),
    contactName: name,
    lastMessage: includeLastMessageTime ? 'hello' : null,
    lastMessageTime: includeLastMessageTime
        ? DateTime.now().subtract(Duration(days: lastMessageDaysAgo))
        : null,
    unreadCount: 0,
    isOnline: false,
    hasUnsentMessages: false,
  );
}

class _MemoryPreferencesRepository implements IPreferencesRepository {
  final Map<String, bool> boolValues = <String, bool>{};
  final Map<String, int> intValues = <String, int>{};
  bool throwOnGetBool = false;

  @override
  Future<void> clearAll() async {
    boolValues.clear();
    intValues.clear();
  }

  @override
  Future<void> delete(String key) async {
    boolValues.remove(key);
    intValues.remove(key);
  }

  @override
  Future<Map<String, dynamic>> getAll() async => <String, dynamic>{
    ...boolValues,
    ...intValues,
  };

  @override
  Future<bool> getBool(String key, {bool? defaultValue}) async {
    if (throwOnGetBool) {
      throw StateError('getBool failed');
    }
    return boolValues[key] ?? (defaultValue ?? false);
  }

  @override
  Future<double> getDouble(String key, {double? defaultValue}) async =>
      defaultValue ?? 0.0;

  @override
  Future<int> getInt(String key, {int? defaultValue}) async =>
      intValues[key] ?? (defaultValue ?? 0);

  @override
  Future<String> getString(String key, {String? defaultValue}) async =>
      defaultValue ?? '';

  @override
  Future<void> setBool(String key, bool value) async {
    boolValues[key] = value;
  }

  @override
  Future<void> setDouble(String key, double value) async {}

  @override
  Future<void> setInt(String key, int value) async {
    intValues[key] = value;
  }

  @override
  Future<void> setString(String key, String value) async {}
}

class _FakeChatsRepository extends Fake implements IChatsRepository {
  List<ChatListItem> chats = <ChatListItem>[];
  int getAllChatsCalls = 0;

  @override
  Future<List<ChatListItem>> getAllChats({
    List<Peripheral>? nearbyDevices,
    Map<String, DiscoveredEventArgs>? discoveryData,
    String? searchQuery,
    int? limit,
    int? offset,
  }) async {
    getAllChatsCalls++;
    return List<ChatListItem>.from(chats);
  }
}

class _FakeArchiveManagementService extends Fake
    implements ArchiveManagementService {
  final Map<String, ArchiveOperationResult> resultByChatId =
      <String, ArchiveOperationResult>{};
  final List<String> archivedChatIds = <String>[];

  @override
  Future<ArchiveOperationResult> archiveChat({
    required String chatId,
    String? reason,
    Map<String, dynamic>? metadata,
    bool force = false,
  }) async {
    archivedChatIds.add(chatId);
    return resultByChatId[chatId] ??
        ArchiveOperationResult.success(
          message: 'archived',
          operationType: ArchiveOperationType.archive,
          operationTime: Duration.zero,
        );
  }
}
