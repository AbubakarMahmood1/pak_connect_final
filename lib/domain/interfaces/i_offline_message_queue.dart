import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';

export 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart'
    show
        OfflineMessageQueueContract,
        QueuedMessageStatus,
        QueueStatistics,
        QueuedMessage;
export 'package:pak_connect/domain/models/mesh_relay_models.dart'
    show QueueSyncMessage;

/// Backward-compatible alias for the canonical offline queue contract.
///
/// Prefer using [OfflineMessageQueueContract] directly in new code.
typedef IOfflineMessageQueue = OfflineMessageQueueContract;
