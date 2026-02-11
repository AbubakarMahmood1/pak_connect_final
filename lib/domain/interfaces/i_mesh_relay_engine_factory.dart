import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart'
    as domain_messaging;
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';

/// Domain contract for creating mesh relay engines.
abstract interface class IMeshRelayEngineFactory {
  domain_messaging.MeshRelayEngine create({
    required OfflineMessageQueueContract messageQueue,
    required SpamPreventionManager spamPrevention,
    ISeenMessageStore? seenMessageStore,
    bool forceFloodMode = false,
  });
}
