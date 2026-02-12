import 'package:pak_connect/core/app_core.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';

/// AppCore-backed implementation for shared queue access.
class AppCoreSharedMessageQueueProvider implements ISharedMessageQueueProvider {
  AppCoreSharedMessageQueueProvider({AppCore? appCore})
    : _appCore = appCore ?? AppCore();

  final AppCore _appCore;

  @override
  bool get isInitialized => _appCore.isInitialized;

  @override
  bool get isInitializing => _appCore.isInitializing;

  @override
  Future<void> initialize() => _appCore.initialize();

  @override
  OfflineMessageQueueContract get messageQueue => _appCore.messageQueue;
}
