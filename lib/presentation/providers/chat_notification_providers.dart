import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../domain/services/chat_management_service.dart';
import '../../domain/routing/network_topology_analyzer.dart';
import '../../domain/routing/routing_models.dart';
import 'di_providers.dart';
import 'pinning_service_provider.dart' as pinning;

/// Shared logger for chat notification bridging.
final _logger = Logger('ChatNotificationProviders');

/// Provides the shared ChatManagementService singleton.
/// Initialization is triggered lazily to ensure streams are ready when listened to.
final chatManagementServiceProvider = Provider<ChatManagementService>((ref) {
  final service = resolveFromAppServicesOrServiceLocator<ChatManagementService>(
    fromServices: (services) => services.chatManagementService,
    dependencyName: 'ChatManagementService',
  );

  // Fire-and-forget initialization; errors are logged but not rethrown to avoid
  // breaking provider resolution in UI layers.
  unawaited(
    service.initialize().catchError((error, stack) {
      _logger.severe(
        'Failed to initialize ChatManagementService',
        error,
        stack,
      );
    }),
  );

  return service;
});

/// StreamProvider bridge for chat-level updates (archive/unarchive/pin/delete).
final chatUpdatesStreamProvider = StreamProvider<ChatUpdateEvent>((ref) {
  final service = ref.watch(chatManagementServiceProvider);
  return service.chatUpdates;
});

/// StreamProvider bridge for message-level updates (star/unstar/etc).
final messageUpdatesStreamProvider = StreamProvider<MessageUpdateEvent>((ref) {
  final service = ref.watch(chatManagementServiceProvider);
  return service.messageUpdates;
});

// Phase 6D: NetworkTopologyAnalyzer provider wrapper (M3)
/// Provides access to network topology analyzer stream for Riverpod lifecycle management
final networkTopologyAnalyzerUpdatesProvider =
    StreamProvider.autoDispose<NetworkTopology>((ref) {
      final analyzer = NetworkTopologyAnalyzer();
      ref.onDispose(analyzer.dispose);
      return analyzer.topologyUpdates;
    });

// Phase 6D: PinningService provider wrapper (M4)
/// Provides access to pinning service message updates for Riverpod lifecycle management
final pinningServiceUpdatesProvider =
    StreamProvider.autoDispose<MessageUpdateEvent>((ref) {
      final service = ref.watch(pinning.pinningServiceProvider);
      return service.messageUpdates;
    });
