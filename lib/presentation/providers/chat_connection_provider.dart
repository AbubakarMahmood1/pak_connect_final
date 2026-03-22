import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart';
import 'package:logging/logging.dart';

import '../../domain/interfaces/i_chat_connection_manager.dart';
import '../../domain/interfaces/i_chat_connection_manager_factory.dart';
import '../../domain/models/connection_status.dart';
import 'ble_providers.dart';

final _logger = Logger('ChatConnectionProvider');

/// ✅ Phase 6D: Riverpod provider for ChatConnectionManager
/// Manages lifecycle and provides dependency injection for the service
final chatConnectionManagerProvider =
    Provider.autoDispose<IChatConnectionManager>((ref) {
      final manager =
          resolveFromAppServicesOrServiceLocator<IChatConnectionManagerFactory>(
            fromServices: (services) =>
                services.chatConnectionManagerFactory ??
                resolveFromServiceLocator<IChatConnectionManagerFactory>(
                  dependencyName: 'IChatConnectionManagerFactory',
                ),
            dependencyName: 'IChatConnectionManagerFactory',
          ).create(bleService: ref.watch(connectionServiceProvider));
      ref.onDispose(() {
        manager.dispose();
      });
      _logger.fine('✅ ChatConnectionManager provider created');
      return manager;
    });

/// ✅ Phase 6D: StreamProvider for connection status events
/// Wraps ChatConnectionManager's connectionStatusStream for Riverpod consumers
/// Emits current state immediately for late subscribers
final chatConnectionStatusStreamProvider =
    StreamProvider.autoDispose<ConnectionStatus>((ref) async* {
      final manager = ref.watch(chatConnectionManagerProvider);
      yield ConnectionStatus.offline; // Initial state for late subscribers
      yield* manager.connectionStatusStream;
    });
