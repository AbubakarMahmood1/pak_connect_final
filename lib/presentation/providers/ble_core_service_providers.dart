import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart';
import 'package:logging/logging.dart';

import '../../domain/interfaces/i_ble_connection_service.dart';
import '../../domain/interfaces/i_ble_discovery_service.dart';
import '../../domain/interfaces/i_connection_service.dart';
import '../../domain/interfaces/i_ble_messaging_service.dart';
import 'ble_providers.dart';

final _logger = Logger('BleCoreServiceProviders');

/// Provides the registered BLE connection service and disposes it when no longer used.
final bleConnectionServiceProvider = Provider<IBLEConnectionService>((ref) {
  final service = ref.watch(connectionServiceProvider);
  if (service is IBLEConnectionService) {
    _logger.fine(
      'BLEConnectionService provider accessed via IConnectionService bridge',
    );
    return service as IBLEConnectionService;
  }
  final fallback = resolveFromServiceLocator<IBLEConnectionService>(
    dependencyName: 'IBLEConnectionService',
  );
  _logger.fine('BLEConnectionService provider accessed');
  return fallback;
});

/// Provides the BLE discovery service singleton.
final bleDiscoveryServiceProvider = Provider<IBLEDiscoveryService>((ref) {
  final service = ref.watch(connectionServiceProvider);
  if (service is IBLEDiscoveryService) {
    _logger.fine(
      'BLEDiscoveryService provider accessed via IConnectionService bridge',
    );
    return service as IBLEDiscoveryService;
  }
  final discovery = resolveFromServiceLocator<IBLEDiscoveryService>(
    dependencyName: 'IBLEDiscoveryService',
  );
  _logger.fine('BLEDiscoveryService provider accessed');
  return discovery;
});

/// Provides the BLE handshake service singleton.
final bleHandshakeServiceProvider = Provider<IConnectionService>((ref) {
  final handshake = ref.watch(connectionServiceProvider);
  _logger.fine('BLEHandshakeService provider accessed');
  return handshake;
});

/// Provides the BLE messaging service. No explicit dispose hook exposed.
final bleMessagingServiceProvider = Provider<IBLEMessagingService>((ref) {
  final service = ref.watch(connectionServiceProvider);
  if (service is IBLEMessagingService) {
    _logger.fine(
      'BLEMessagingService provider accessed via IConnectionService bridge',
    );
    return service as IBLEMessagingService;
  }
  final messaging = resolveFromServiceLocator<IBLEMessagingService>(
    dependencyName: 'IBLEMessagingService',
  );
  _logger.fine('BLEMessagingService provider accessed');
  return messaging;
});
