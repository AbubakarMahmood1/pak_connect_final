import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/models/connection_status.dart';
import '../../core/services/chat_connection_manager.dart';
import 'ble_providers.dart';

final _logger = Logger('ChatConnectionProvider');

/// ✅ Phase 6D: Riverpod provider for ChatConnectionManager
/// Manages lifecycle and provides dependency injection for the service
final chatConnectionManagerProvider =
    Provider.autoDispose<ChatConnectionManager>((ref) {
      final manager = ChatConnectionManager(
        bleService: ref.watch(connectionServiceProvider),
      );
      ref.onDispose(manager.dispose);
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
