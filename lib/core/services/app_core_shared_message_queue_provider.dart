import 'package:pak_connect/core/app_core.dart';
import 'package:pak_connect/domain/interfaces/i_shared_message_queue_provider.dart';
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';

/// AppCore-backed implementation for shared queue access.
class AppCoreSharedMessageQueueProvider implements ISharedMessageQueueProvider {
  @override
  bool get isInitialized => AppCore.instance.isInitialized;

  @override
  bool get isInitializing => AppCore.instance.isInitializing;

  @override
  Future<void> initialize() => AppCore.instance.initialize();

  @override
  OfflineMessageQueueContract get messageQueue => AppCore.instance.messageQueue;
}
