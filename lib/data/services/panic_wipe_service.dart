import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/data/database/database_encryption.dart';
import 'package:pak_connect/data/database/database_helper.dart';
import 'package:pak_connect/domain/interfaces/i_panic_wipe_service.dart';
import 'package:pak_connect/domain/services/conversation_crypto_service.dart';
import 'package:pak_connect/domain/services/hint_cache_manager.dart';
import 'package:pak_connect/domain/services/message_security.dart';
import 'package:pak_connect/domain/services/panic_wipe_runtime_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PanicWipeService implements IPanicWipeService {
  PanicWipeService({
    Future<void> Function()? disposeAppCore,
    Future<void> Function()? shutdownSecurityManager,
    Future<void> Function()? clearConversationKeys,
    Future<void> Function()? clearReplayProtectionState,
    Future<void> Function()? clearHintCache,
    Future<void> Function()? closeDatabase,
    Future<void> Function()? deleteDatabase,
    Future<bool> Function()? databaseExists,
    Future<void> Function()? deleteEncryptionKey,
    Future<bool> Function()? hasEncryptionKey,
    Future<void> Function()? deleteSecureStorage,
    Future<void> Function()? clearSharedPreferences,
    Future<void> Function()? resetAppCoreSingleton,
    Future<void> Function()? initializeAppCore,
    Logger? logger,
  }) : _disposeAppCore =
           disposeAppCore ?? (() => PanicWipeRuntimeBridge.disposeAppCore()),
       _shutdownSecurityManager =
           shutdownSecurityManager ??
           (() => PanicWipeRuntimeBridge.shutdownSecurityManager()),
       _clearConversationKeys =
           clearConversationKeys ??
           (() async => ConversationCryptoService.clearAllConversationKeys()),
       _clearReplayProtectionState =
           clearReplayProtectionState ??
           (() async => MessageSecurity.clearReplayProtectionState()),
       _clearHintCache =
           clearHintCache ?? (() async => HintCacheManager.clearCache()),
       _closeDatabase = closeDatabase ?? (() => DatabaseHelper.close()),
       _deleteDatabase =
           deleteDatabase ?? (() => DatabaseHelper.deleteDatabase()),
       _databaseExists = databaseExists ?? (() => DatabaseHelper.exists()),
       _deleteEncryptionKey =
           deleteEncryptionKey ??
           (() => DatabaseEncryption.deleteEncryptionKey()),
       _hasEncryptionKey =
           hasEncryptionKey ?? (() => DatabaseEncryption.hasEncryptionKey()),
       _deleteSecureStorage =
           deleteSecureStorage ??
           (() => const FlutterSecureStorage().deleteAll()),
       _clearSharedPreferences =
           clearSharedPreferences ??
           (() async {
             final prefs = await SharedPreferences.getInstance();
             await prefs.clear();
           }),
       _resetAppCoreSingleton =
           resetAppCoreSingleton ??
           (() => PanicWipeRuntimeBridge.resetAppCoreSingleton()),
       _initializeAppCore =
           initializeAppCore ??
           (() => PanicWipeRuntimeBridge.initializeAppCore()),
       _logger = logger ?? Logger('PanicWipeService');

  final Future<void> Function() _disposeAppCore;
  final Future<void> Function() _shutdownSecurityManager;
  final Future<void> Function() _clearConversationKeys;
  final Future<void> Function() _clearReplayProtectionState;
  final Future<void> Function() _clearHintCache;
  final Future<void> Function() _closeDatabase;
  final Future<void> Function() _deleteDatabase;
  final Future<bool> Function() _databaseExists;
  final Future<void> Function() _deleteEncryptionKey;
  final Future<bool> Function() _hasEncryptionKey;
  final Future<void> Function() _deleteSecureStorage;
  final Future<void> Function() _clearSharedPreferences;
  final Future<void> Function() _resetAppCoreSingleton;
  final Future<void> Function() _initializeAppCore;
  final Logger _logger;

  bool _inProgress = false;

  @override
  Future<PanicWipeResult> execute({required PanicWipeOrigin origin}) async {
    if (_inProgress) {
      return PanicWipeResult.failure('panic wipe already in progress');
    }

    _inProgress = true;
    final failures = <String>[];
    _logger.warning('Panic wipe started from ${origin.name}');

    try {
      await _runStep('dispose app core', _disposeAppCore, failures);
      await _runStep(
        'shutdown security manager',
        _shutdownSecurityManager,
        failures,
      );
      await _runStep(
        'clear conversation keys',
        _clearConversationKeys,
        failures,
      );
      await _runStep(
        'clear replay protection state',
        _clearReplayProtectionState,
        failures,
      );
      await _runStep('clear hint cache', _clearHintCache, failures);
      await _runStep('close database', _closeDatabase, failures);
      await _runStep('delete database file', () async {
        await _deleteDatabase();
        if (await _databaseExists()) {
          throw StateError('database file still exists after delete');
        }
      }, failures);
      await _runStep('delete database encryption key', () async {
        await _deleteEncryptionKey();
        if (await _hasEncryptionKey()) {
          throw StateError('database encryption key still exists after delete');
        }
      }, failures);
      await _runStep('clear secure storage', _deleteSecureStorage, failures);
      await _runStep(
        'clear shared preferences',
        _clearSharedPreferences,
        failures,
      );
      await _runStep(
        'reset app core singleton',
        _resetAppCoreSingleton,
        failures,
      );
      await _runStep('initialize app core', _initializeAppCore, failures);
    } finally {
      _inProgress = false;
    }

    final result = PanicWipeResult(
      success: failures.isEmpty,
      failures: failures,
    );
    if (result.success) {
      _logger.warning('Panic wipe completed successfully');
    } else {
      _logger.severe(
        'Panic wipe completed with failures: ${failures.join('; ')}',
      );
    }
    return result;
  }

  Future<void> _runStep(
    String label,
    Future<void> Function() action,
    List<String> failures,
  ) async {
    try {
      await action();
    } catch (error, stackTrace) {
      failures.add('$label failed: $error');
      _logger.severe('Panic wipe step failed: $label', error, stackTrace);
    }
  }
}
