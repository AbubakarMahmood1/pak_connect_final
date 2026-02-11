import 'package:pak_connect/domain/interfaces/i_mesh_relay_engine_factory.dart';
import 'package:pak_connect/domain/interfaces/i_seen_message_store.dart';
import 'package:pak_connect/domain/messaging/mesh_relay_engine.dart'
    as domain_messaging;
import 'package:pak_connect/domain/messaging/offline_message_queue_contract.dart';
import 'package:pak_connect/domain/services/spam_prevention_manager.dart';

import 'mesh_relay_engine.dart';

/// Core adapter that constructs [MeshRelayEngine] through the domain contract.
class CoreMeshRelayEngineFactory implements IMeshRelayEngineFactory {
  const CoreMeshRelayEngineFactory();

  @override
  domain_messaging.MeshRelayEngine create({
    required OfflineMessageQueueContract messageQueue,
    required SpamPreventionManager spamPrevention,
    ISeenMessageStore? seenMessageStore,
    bool forceFloodMode = false,
  }) {
    return MeshRelayEngine(
      messageQueue: messageQueue,
      spamPrevention: spamPrevention,
      seenMessageStore: seenMessageStore,
      forceFloodMode: forceFloodMode,
    );
  }
}
