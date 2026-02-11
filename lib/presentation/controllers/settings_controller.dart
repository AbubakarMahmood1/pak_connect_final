import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import '../../domain/services/ephemeral_key_manager.dart';
import '../../domain/services/hint_cache_manager.dart';
import '../../domain/services/message_security.dart';
import '../../domain/services/battery_optimizer.dart';
import '../../domain/services/simple_crypto.dart';
import '../../domain/config/kill_switches.dart';
import '../../domain/entities/preference_keys.dart';
import '../../domain/interfaces/i_chats_repository.dart';
import '../../domain/interfaces/i_contact_repository.dart';
import '../../domain/interfaces/i_database_provider.dart';
import '../../domain/interfaces/i_preferences_repository.dart';
import '../../domain/interfaces/i_user_preferences.dart';
import '../../domain/services/auto_archive_scheduler.dart';
import '../../domain/services/notification_handler_factory.dart';
import '../../domain/services/notification_service.dart';

class SettingsController extends ChangeNotifier {
  SettingsController({
    IPreferencesRepository? preferencesRepository,
    IContactRepository? contactRepository,
    IChatsRepository? chatsRepository,
    IUserPreferences? userPreferences,
    IDatabaseProvider? databaseProvider,
    Logger? logger,
  }) : _preferencesRepository =
           preferencesRepository ?? _resolvePreferencesRepository(),
       _contactRepository = contactRepository ?? _resolveContactRepository(),
       _chatsRepository = chatsRepository ?? _resolveChatsRepository(),
       _userPreferences = userPreferences ?? _resolveUserPreferences(),
       _databaseProvider = databaseProvider ?? _resolveDatabaseProvider(),
       _logger = logger ?? Logger('SettingsController');

  final IPreferencesRepository _preferencesRepository;
  final IContactRepository _contactRepository;
  final IChatsRepository _chatsRepository;
  final IUserPreferences _userPreferences;
  final IDatabaseProvider _databaseProvider;
  final Logger _logger;

  bool _isDisposed = false;
  bool isLoading = true;

  bool notificationsEnabled = PreferenceDefaults.notificationsEnabled;
  bool backgroundNotifications = PreferenceDefaults.backgroundNotifications;
  bool soundEnabled = PreferenceDefaults.soundEnabled;
  bool vibrationEnabled = PreferenceDefaults.vibrationEnabled;

  bool showReadReceipts = PreferenceDefaults.showReadReceipts;
  bool showOnlineStatus = PreferenceDefaults.showOnlineStatus;
  bool allowNewContacts = PreferenceDefaults.allowNewContacts;
  bool hintBroadcastEnabled = true;
  bool autoConnectKnownContacts = PreferenceDefaults.autoConnectKnownContacts;
  bool disableHealthChecks = PreferenceDefaults.killSwitchHealthChecks;
  bool disableQueueSync = PreferenceDefaults.killSwitchQueueSync;
  bool disableAutoConnect = PreferenceDefaults.killSwitchAutoConnect;
  bool disableDualRole = PreferenceDefaults.killSwitchDualRole;
  bool disableDiscoveryScheduler =
      PreferenceDefaults.killSwitchDiscoveryScheduler;

  bool autoArchiveOldChats = PreferenceDefaults.autoArchiveOldChats;
  int archiveAfterDays = PreferenceDefaults.archiveAfterDays;

  int contactCount = 0;
  int chatCount = 0;
  int messageCount = 0;

  Future<void> initialize() async {
    if (_isDisposed) return;
    isLoading = true;
    _safeNotifyListeners();

    notificationsEnabled = await _preferencesRepository.getBool(
      PreferenceKeys.notificationsEnabled,
    );
    if (_isDisposed) return;
    backgroundNotifications = await _preferencesRepository.getBool(
      PreferenceKeys.backgroundNotifications,
    );
    if (_isDisposed) return;
    soundEnabled = await _preferencesRepository.getBool(
      PreferenceKeys.soundEnabled,
    );
    if (_isDisposed) return;
    vibrationEnabled = await _preferencesRepository.getBool(
      PreferenceKeys.vibrationEnabled,
    );
    if (_isDisposed) return;

    showReadReceipts = await _preferencesRepository.getBool(
      PreferenceKeys.showReadReceipts,
    );
    if (_isDisposed) return;
    showOnlineStatus = await _preferencesRepository.getBool(
      PreferenceKeys.showOnlineStatus,
    );
    if (_isDisposed) return;
    allowNewContacts = await _preferencesRepository.getBool(
      PreferenceKeys.allowNewContacts,
    );
    if (_isDisposed) return;

    hintBroadcastEnabled = await _userPreferences.getHintBroadcastEnabled();
    if (_isDisposed) return;

    try {
      autoConnectKnownContacts = await _preferencesRepository.getBool(
        PreferenceKeys.autoConnectKnownContacts,
        defaultValue: PreferenceDefaults.autoConnectKnownContacts,
      );
    } catch (e) {
      _logger.warning('Failed to load auto-connect preference: $e');
      autoConnectKnownContacts = PreferenceDefaults.autoConnectKnownContacts;
      await _preferencesRepository.setBool(
        PreferenceKeys.autoConnectKnownContacts,
        PreferenceDefaults.autoConnectKnownContacts,
      );
    }

    if (_isDisposed) return;
    autoArchiveOldChats = await _preferencesRepository.getBool(
      PreferenceKeys.autoArchiveOldChats,
    );
    if (_isDisposed) return;
    archiveAfterDays = await _preferencesRepository.getInt(
      PreferenceKeys.archiveAfterDays,
    );

    // Developer kill switches
    disableHealthChecks = await _preferencesRepository.getBool(
      PreferenceKeys.killSwitchHealthChecks,
      defaultValue: PreferenceDefaults.killSwitchHealthChecks,
    );
    disableQueueSync = await _preferencesRepository.getBool(
      PreferenceKeys.killSwitchQueueSync,
      defaultValue: PreferenceDefaults.killSwitchQueueSync,
    );
    disableAutoConnect = await _preferencesRepository.getBool(
      PreferenceKeys.killSwitchAutoConnect,
      defaultValue: PreferenceDefaults.killSwitchAutoConnect,
    );
    disableDualRole = await _preferencesRepository.getBool(
      PreferenceKeys.killSwitchDualRole,
      defaultValue: PreferenceDefaults.killSwitchDualRole,
    );
    disableDiscoveryScheduler = await _preferencesRepository.getBool(
      PreferenceKeys.killSwitchDiscoveryScheduler,
      defaultValue: PreferenceDefaults.killSwitchDiscoveryScheduler,
    );
    await KillSwitches.set(
      setBool: _preferencesRepository.setBool,
      healthChecks: disableHealthChecks,
      queueSync: disableQueueSync,
      autoConnect: disableAutoConnect,
      dualRole: disableDualRole,
      discoveryScheduler: disableDiscoveryScheduler,
    );

    if (_isDisposed) return;
    isLoading = false;
    _safeNotifyListeners();
  }

  Future<void> setNotificationsEnabled(bool value) async {
    if (_isDisposed) return;
    notificationsEnabled = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.notificationsEnabled,
      value,
    );
  }

  Future<void> setBackgroundNotifications(bool value) async {
    if (_isDisposed) return;
    backgroundNotifications = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.backgroundNotifications,
      value,
    );
    final handler = value
        ? NotificationHandlerFactory.createBackgroundHandler()
        : NotificationHandlerFactory.createDefault();
    await NotificationService.swapHandler(handler);
  }

  Future<void> setSoundEnabled(bool value) async {
    if (_isDisposed) return;
    soundEnabled = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(PreferenceKeys.soundEnabled, value);
  }

  Future<void> setVibrationEnabled(bool value) async {
    if (_isDisposed) return;
    vibrationEnabled = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.vibrationEnabled,
      value,
    );
  }

  Future<void> setReadReceipts(bool value) async {
    if (_isDisposed) return;
    showReadReceipts = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.showReadReceipts,
      value,
    );
  }

  Future<void> setOnlineStatus(bool value) async {
    if (_isDisposed) return;
    showOnlineStatus = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.showOnlineStatus,
      value,
    );
  }

  Future<void> setAllowNewContacts(bool value) async {
    if (_isDisposed) return;
    allowNewContacts = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.allowNewContacts,
      value,
    );
  }

  Future<void> setHintBroadcastEnabled(bool value) async {
    if (_isDisposed) return;
    hintBroadcastEnabled = value;
    _safeNotifyListeners();
    await _userPreferences.setHintBroadcastEnabled(value);
  }

  Future<void> setAutoConnectKnownContacts(bool value) async {
    if (_isDisposed) return;
    autoConnectKnownContacts = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.autoConnectKnownContacts,
      value,
    );
  }

  Future<void> setDisableHealthChecks(bool value) async {
    if (_isDisposed) return;
    disableHealthChecks = value;
    _safeNotifyListeners();
    await KillSwitches.set(
      setBool: _preferencesRepository.setBool,
      healthChecks: value,
    );
  }

  Future<void> setDisableQueueSync(bool value) async {
    if (_isDisposed) return;
    disableQueueSync = value;
    _safeNotifyListeners();
    await KillSwitches.set(
      setBool: _preferencesRepository.setBool,
      queueSync: value,
    );
  }

  Future<void> setDisableAutoConnect(bool value) async {
    if (_isDisposed) return;
    disableAutoConnect = value;
    _safeNotifyListeners();
    await KillSwitches.set(
      setBool: _preferencesRepository.setBool,
      autoConnect: value,
    );
  }

  Future<void> setDisableDualRole(bool value) async {
    if (_isDisposed) return;
    disableDualRole = value;
    _safeNotifyListeners();
    await KillSwitches.set(
      setBool: _preferencesRepository.setBool,
      dualRole: value,
    );
  }

  Future<void> setDisableDiscoveryScheduler(bool value) async {
    if (_isDisposed) return;
    disableDiscoveryScheduler = value;
    _safeNotifyListeners();
    await KillSwitches.set(
      setBool: _preferencesRepository.setBool,
      discoveryScheduler: value,
    );
  }

  Future<void> setAutoArchiveOldChats(bool value) async {
    if (_isDisposed) return;
    autoArchiveOldChats = value;
    _safeNotifyListeners();
    await _preferencesRepository.setBool(
      PreferenceKeys.autoArchiveOldChats,
      value,
    );
    await AutoArchiveScheduler.restart();
  }

  Future<void> setArchiveAfterDays(int days) async {
    if (_isDisposed) return;
    archiveAfterDays = days;
    _safeNotifyListeners();
    await _preferencesRepository.setInt(PreferenceKeys.archiveAfterDays, days);
    await AutoArchiveScheduler.restart();
  }

  Future<void> triggerTestNotification() async {
    await NotificationService.showTestNotification(
      playSound: soundEnabled,
      vibrate: vibrationEnabled,
    );
  }

  Future<int> manualAutoArchiveCheck() async {
    if (_isDisposed) return 0;
    return AutoArchiveScheduler.checkNow();
  }

  Future<StorageInfo> getStorageInfo() async {
    if (_isDisposed) {
      return StorageInfo(exists: false, sizeMB: '0.00', sizeKB: '0.00');
    }
    final sizeInfo = await _databaseProvider.getDatabaseSize();
    return StorageInfo(
      exists: sizeInfo['exists'] ?? false,
      sizeMB: sizeInfo['size_mb']?.toString() ?? '0.00',
      sizeKB: sizeInfo['size_kb']?.toString() ?? '0.00',
    );
  }

  Future<DatabaseStats> loadDatabaseStats() async {
    if (_isDisposed) {
      return DatabaseStats(
        sizeMB: '0.00',
        sizeKB: '0.00',
        sizeBytes: '0',
        contacts: 0,
        chats: 0,
        messages: 0,
      );
    }
    contactCount = await _contactRepository.getContactCount();
    chatCount = await _chatsRepository.getChatCount();
    messageCount = await _chatsRepository.getTotalMessageCount();

    final sizeInfo = await _databaseProvider.getDatabaseSize();
    final sizeMB = sizeInfo['size_mb'] ?? '0.00';
    final sizeKB = sizeInfo['size_kb'] ?? '0.00';
    final sizeBytes = sizeInfo['size_bytes'] ?? 0;

    return DatabaseStats(
      sizeMB: sizeMB.toString(),
      sizeKB: sizeKB.toString(),
      sizeBytes: sizeBytes.toString(),
      contacts: contactCount,
      chats: chatCount,
      messages: messageCount,
    );
  }

  Future<bool> clearAllData() async {
    if (_isDisposed) return false;
    final db = await _databaseProvider.database;

    await db.transaction((txn) async {
      await txn.delete('archived_messages');
      await txn.delete('archived_chats');
      await txn.delete('deleted_message_ids');
      await txn.delete('queue_sync_state');
      await txn.delete('offline_message_queue');
      await txn.delete('messages');
      await txn.delete('chats');
      await txn.delete('contact_last_seen');
      await txn.delete('device_mappings');
      await txn.delete('contacts');
      await txn.delete('migration_metadata');
      await txn.delete('app_preferences');
    });

    final allContacts = await _contactRepository.getAllContacts();
    for (final contact in allContacts.values) {
      await _contactRepository.deleteContact(contact.publicKey);
    }

    await _preferencesRepository.clearAll();
    return true;
  }

  Future<void> clearCaches() async {
    if (_isDisposed) return;
    SimpleCrypto.clearAllConversationKeys();
    await MessageSecurity.clearProcessedMessages();
    HintCacheManager.clearCache();
    await EphemeralKeyManager.rotateSession();
  }

  Future<IntegrityResult> checkDatabaseIntegrity() async {
    if (_isDisposed) return IntegrityResult(isOk: false, raw: 'disposed');
    final db = await _databaseProvider.database;
    final result = await db.rawQuery('PRAGMA integrity_check');
    final isOk = result.isNotEmpty && result.first.containsValue('ok');
    return IntegrityResult(isOk: isOk, raw: result.toString());
  }

  Future<String> loadPrivacyPolicyMarkdown() async {
    if (_isDisposed) return '';
    return rootBundle.loadString('assets/privacy_policy.md');
  }

  BatteryInfoWrapper getBatteryInfo() {
    if (_isDisposed) {
      return BatteryInfoWrapper(0, false, '', '', DateTime.now());
    }
    final info = BatteryOptimizer().getCurrentInfo();
    return BatteryInfoWrapper(
      info.level,
      info.isCharging,
      info.powerMode.name,
      info.modeDescription,
      info.lastUpdate,
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _safeNotifyListeners() {
    if (_isDisposed) return;
    notifyListeners();
  }

  static IPreferencesRepository _resolvePreferencesRepository() =>
      _resolveOrThrow<IPreferencesRepository>('IPreferencesRepository');

  static IContactRepository _resolveContactRepository() =>
      _resolveOrThrow<IContactRepository>('IContactRepository');

  static IChatsRepository _resolveChatsRepository() =>
      _resolveOrThrow<IChatsRepository>('IChatsRepository');

  static IUserPreferences _resolveUserPreferences() =>
      _resolveOrThrow<IUserPreferences>('IUserPreferences');

  static IDatabaseProvider _resolveDatabaseProvider() =>
      _resolveOrThrow<IDatabaseProvider>('IDatabaseProvider');

  static T _resolveOrThrow<T extends Object>(String typeName) {
    final serviceLocator = GetIt.instance;
    if (serviceLocator.isRegistered<T>()) {
      return serviceLocator<T>();
    }
    throw StateError('$typeName is not registered in GetIt');
  }
}

class StorageInfo {
  StorageInfo({
    required this.exists,
    required this.sizeMB,
    required this.sizeKB,
  });

  final bool exists;
  final String sizeMB;
  final String sizeKB;
}

class DatabaseStats {
  DatabaseStats({
    required this.sizeMB,
    required this.sizeKB,
    required this.sizeBytes,
    required this.contacts,
    required this.chats,
    required this.messages,
  });

  final String sizeMB;
  final String sizeKB;
  final String sizeBytes;
  final int contacts;
  final int chats;
  final int messages;
}

class IntegrityResult {
  IntegrityResult({required this.isOk, required this.raw});

  final bool isOk;
  final String raw;
}

class BatteryInfoWrapper {
  BatteryInfoWrapper(
    this.level,
    this.isCharging,
    this.powerModeName,
    this.modeDescription,
    this.lastUpdate,
  );

  final int level;
  final bool isCharging;
  final String powerModeName;
  final String modeDescription;
  final DateTime lastUpdate;
}
