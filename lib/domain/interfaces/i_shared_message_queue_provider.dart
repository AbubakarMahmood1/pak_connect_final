import '../messaging/offline_message_queue_contract.dart';

/// Abstraction for retrieving the app-wide shared offline queue instance.
///
/// This lets domain services depend on queue availability without importing
/// `core/app_core.dart` directly.
abstract interface class ISharedMessageQueueProvider {
  bool get isInitialized;
  bool get isInitializing;
  Future<void> initialize();
  Future<OfflineMessageQueueContract> waitForMessageQueue();
  OfflineMessageQueueContract get messageQueue;
}

mixin SharedMessageQueueProviderWaitMixin
    implements ISharedMessageQueueProvider {
  @override
  Future<OfflineMessageQueueContract> waitForMessageQueue() async {
    if (!isInitialized) {
      await initialize();
    }
    return messageQueue;
  }
}
