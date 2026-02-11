import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';
import 'package:logging/logging.dart';

import '../../domain/interfaces/i_ble_connection_service.dart';
import '../../domain/interfaces/i_ble_discovery_service.dart';
import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/interfaces/i_ble_messaging_service.dart';

final GetIt getIt = GetIt.instance;
final _logger = Logger('BleCoreServiceProviders');

/// Provides the registered BLE connection service and disposes it when no longer used.
final bleConnectionServiceProvider =
    Provider.autoDispose<IBLEConnectionService>((ref) {
      final service = getIt<IBLEConnectionService>();
      _logger.fine('BLEConnectionService provider accessed');
      ref.onDispose(() {
        // Avoid leaking connection-level controllers.
        service.disposeConnection();
      });
      return service;
    });

/// Provides the BLE discovery service and ensures listeners are cleaned up.
final bleDiscoveryServiceProvider = Provider.autoDispose<IBLEDiscoveryService>((
  ref,
) {
  final discovery = getIt<IBLEDiscoveryService>();
  _logger.fine('BLEDiscoveryService provider accessed');
  ref.onDispose(() => unawaited(discovery.dispose()));
  return discovery;
});

/// Provides the BLE handshake service and disposes its coordinator on teardown.
final bleHandshakeServiceProvider = Provider.autoDispose<IConnectionService>((
  ref,
) {
  final handshake = getIt<IConnectionService>();
  _logger.fine('BLEHandshakeService provider accessed');
  ref.onDispose(() {
    try {
      final dynamic maybeHandshake = handshake;
      maybeHandshake.disposeHandshakeCoordinator();
    } catch (_) {}
  });
  return handshake;
});

/// Provides the BLE messaging service. No explicit dispose hook exposed.
final bleMessagingServiceProvider = Provider.autoDispose<IBLEMessagingService>((
  ref,
) {
  final messaging = getIt<IBLEMessagingService>();
  _logger.fine('BLEMessagingService provider accessed');
  return messaging;
});
