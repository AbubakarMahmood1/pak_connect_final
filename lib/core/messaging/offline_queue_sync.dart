import 'package:logging/logging.dart';
import 'package:pak_connect/domain/entities/queued_message.dart';
import 'package:pak_connect/domain/interfaces/i_queue_sync_coordinator.dart';
import 'package:pak_connect/domain/models/mesh_relay_models.dart';
import 'package:pak_connect/domain/values/id_types.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';

class QueueSync {
  QueueSync({
    required IQueueSyncCoordinator coordinator,
    required Set<MessageId> deletedMessageIds,
    required List<QueuedMessage> Function() getAllMessages,
    required Logger logger,
    required void Function() onSyncedMessageAdded,
  }) : _coordinator = coordinator,
       _deletedMessageIds = deletedMessageIds,
       _getAllMessages = getAllMessages,
       _logger = logger,
       _onSyncedMessageAdded = onSyncedMessageAdded;

  final IQueueSyncCoordinator _coordinator;
  final Set<MessageId> _deletedMessageIds;
  final List<QueuedMessage> Function() _getAllMessages;
  final Logger _logger;
  final void Function() _onSyncedMessageAdded;

  Future<void> initialize() async {
    await _coordinator.initialize(
      deletedIds: _deletedMessageIds.map((id) => id.value).toSet(),
    );
  }

  String calculateQueueHash({bool forceRecalculation = false}) {
    return _coordinator.calculateQueueHash(
      forceRecalculation: forceRecalculation,
    );
  }

  QueueSyncMessage createSyncMessage(String nodeId) {
    return _coordinator.createSyncMessage(nodeId);
  }

  bool needsSynchronization(String otherQueueHash) {
    return _coordinator.needsSynchronization(otherQueueHash);
  }

  Future<void> addSyncedMessage(QueuedMessage message) async {
    if (_deletedMessageIds.contains(MessageId(message.id))) {
      _logger.fine(
        'Sync skip - message ${message.id.shortId(8)}... was deleted locally',
      );
      return;
    }

    final exists = _getAllMessages().any((queued) => queued.id == message.id);
    if (exists) {
      _logger.fine(
        'Sync skip - message already exists: ${message.id.shortId(8)}...',
      );
      return;
    }

    final added = await _coordinator.addSyncedMessage(message);
    if (added) {
      _onSyncedMessageAdded();
    }
  }

  List<String> getMissingMessageIds(List<String> otherMessageIds) {
    final normalizedIds = otherMessageIds.map((id) => id.toString()).toList();
    return _coordinator.getMissingMessageIds(normalizedIds);
  }

  List<QueuedMessage> getExcessMessages(List<String> otherMessageIds) {
    final normalizedIds = otherMessageIds.map((id) => id.toString()).toList();
    return _coordinator.getExcessMessages(normalizedIds);
  }

  Future<void> markMessageDeleted(String messageId) async {
    await _coordinator.markMessageDeleted(messageId);
  }

  bool isMessageDeleted(String messageId) {
    return _coordinator.isMessageDeleted(messageId);
  }

  Future<void> cleanupOldDeletedIds() async {
    await _coordinator.cleanupOldDeletedIds();
  }

  void invalidateHashCache() {
    _coordinator.invalidateHashCache();
  }

  SyncCoordinatorStats getSyncStatistics() {
    return _coordinator.getSyncStatistics();
  }
}
