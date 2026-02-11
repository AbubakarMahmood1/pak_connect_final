import 'dart:async';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_ble_advertising_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_discovery_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_handshake_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_messaging_service.dart';
import 'package:pak_connect/domain/interfaces/i_ble_platform_host.dart';
import 'package:pak_connect/domain/models/connection_state.dart'
    show ChatConnectionState;
import 'package:pak_connect/domain/utils/string_extensions.dart';

import '../../domain/services/device_deduplication_manager.dart';
import 'ble_connection_manager.dart';
import 'ble_connection_service.dart';

class BleLifecycleCoordinator {
  BleLifecycleCoordinator({
    required Logger logger,
    required IBLEPlatformHost platformHost,
    required BLEConnectionManager connectionManager,
    required BLEConnectionService Function() getConnectionService,
    required IBLEDiscoveryService Function() getDiscoveryService,
    required IBLEAdvertisingService Function() getAdvertisingService,
    required IBLEMessagingService Function() getMessagingService,
    required IBLEHandshakeService Function() getHandshakeService,
  }) : _logger = logger,
       _platformHost = platformHost,
       _connectionManager = connectionManager,
       _getConnectionService = getConnectionService,
       _getDiscoveryService = getDiscoveryService,
       _getAdvertisingService = getAdvertisingService,
       _getMessagingService = getMessagingService,
       _getHandshakeService = getHandshakeService;

  final Logger _logger;
  final IBLEPlatformHost _platformHost;
  final BLEConnectionManager _connectionManager;
  final BLEConnectionService Function() _getConnectionService;
  final IBLEDiscoveryService Function() _getDiscoveryService;
  final IBLEAdvertisingService Function() _getAdvertisingService;
  final IBLEMessagingService Function() _getMessagingService;
  final IBLEHandshakeService Function() _getHandshakeService;

  Timer? _serverHandshakeTimer;
  StreamSubscription<CentralConnectionStateChangedEventArgs>?
  _peripheralConnectionSub;
  StreamSubscription<CentralMTUChangedEventArgs>? _peripheralMtuSub;
  StreamSubscription<GATTCharacteristicNotifyStateChangedEventArgs>?
  _peripheralNotifyStateSub;
  StreamSubscription<GATTCharacteristicWriteRequestedEventArgs>?
  _peripheralWriteSub;
  StreamSubscription<GATTCharacteristicNotifiedEventArgs>? _centralNotifySub;

  bool _peripheralEventsBound = false;
  bool _connectionSetupComplete = false;
  bool _discoveryInitialized = false;

  void ensureConnectionServicePrepared() {
    if (_connectionSetupComplete) {
      return;
    }

    _getConnectionService().setupConnectionInitialization();
    _bindPeripheralEventHandlers();
    _bindCentralNotificationHandler();

    _connectionManager.setLocalHintProvider(() async {
      try {
        final hint = await _getHandshakeService().buildLocalCollisionHint();
        return hint;
      } catch (_) {
        return null;
      }
    });

    _connectionManager.onConnectionComplete = () =>
        _getHandshakeService().performHandshake(startAsInitiatorOverride: true);

    _connectionSetupComplete = true;
  }

  Future<void> ensureDiscoveryInitialized() async {
    if (_discoveryInitialized) {
      return;
    }

    await _getDiscoveryService().initialize();
    _discoveryInitialized = true;
  }

  Future<void> dispose() async {
    _serverHandshakeTimer?.cancel();
    _serverHandshakeTimer = null;

    await _peripheralConnectionSub?.cancel();
    await _peripheralMtuSub?.cancel();
    await _peripheralNotifyStateSub?.cancel();
    await _peripheralWriteSub?.cancel();
    await _centralNotifySub?.cancel();

    _peripheralConnectionSub = null;
    _peripheralMtuSub = null;
    _peripheralNotifyStateSub = null;
    _peripheralWriteSub = null;
    _centralNotifySub = null;

    _peripheralEventsBound = false;
    _connectionSetupComplete = false;
    _discoveryInitialized = false;
  }

  void _bindPeripheralEventHandlers() {
    if (_peripheralEventsBound) return;

    try {
      final peripheralManager = _platformHost.peripheralManager;

      _peripheralConnectionSub = peripheralManager.connectionStateChanged
          .listen((event) {
            if (event.state == ConnectionState.connected) {
              _connectionManager.handleCentralConnected(event.central);
              final connectionService = _getConnectionService();
              connectionService.connectedCentral = event.central;
              _scheduleResponderHandshakeFallback();
            } else {
              _connectionManager.handleCentralDisconnected(event.central);
              final connectionService = _getConnectionService();
              final advertisingService = _getAdvertisingService();

              final disconnectedId = event.central.uuid.toString();
              final activeId = connectionService.connectedCentral?.uuid
                  .toString();
              final disconnectedWasActive = disconnectedId == activeId;
              final hasOtherServerConnections =
                  _connectionManager.serverConnectionCount > 0;

              if (disconnectedWasActive) {
                _getHandshakeService().disposeHandshakeCoordinator();
                connectionService.connectedCentral = null;
                connectionService.connectedCharacteristic = null;
              }

              if (!hasOtherServerConnections) {
                advertisingService.resetPeripheralSession();
              } else if (disconnectedWasActive) {
                final remainingConnections =
                    _connectionManager.serverConnections;
                if (remainingConnections.isNotEmpty) {
                  final replacement = remainingConnections.last;
                  connectionService.connectedCentral = replacement.central;
                  connectionService.connectedCharacteristic =
                      replacement.subscribedCharacteristic;
                }
                advertisingService.peripheralHandshakeStarted = false;
                _maybeStartResponderHandshake(
                  characteristicOverride:
                      connectionService.connectedCharacteristic,
                );
              }
            }
          });

      _peripheralMtuSub = peripheralManager.mtuChanged.listen((event) {
        final connectionService = _getConnectionService();
        connectionService.connectedCentral = event.central;
        _getAdvertisingService().updatePeripheralMtu(event.mtu);
        _connectionManager.updateServerMtu(
          event.central.uuid.toString(),
          event.mtu,
        );
        _maybeStartResponderHandshake();
      });

      _peripheralNotifyStateSub = peripheralManager
          .characteristicNotifyStateChanged
          .listen((event) {
            if (!event.state) return;
            _connectionManager.handleCharacteristicSubscribed(
              event.central,
              event.characteristic,
            );
            final connectionService = _getConnectionService();
            connectionService.connectedCentral = event.central;
            connectionService.connectedCharacteristic = event.characteristic;
            _maybeStartResponderHandshake(
              characteristicOverride: event.characteristic,
            );
          });

      _peripheralWriteSub = peripheralManager.characteristicWriteRequested.listen((
        event,
      ) async {
        try {
          final data = event.request.value;
          final connectionService = _getConnectionService();
          connectionService.connectedCentral = event.central;
          connectionService.connectedCharacteristic = event.characteristic;

          final handled = await _getHandshakeService()
              .handleIncomingHandshakeMessage(data, isFromPeripheral: true);

          _maybeStartResponderHandshake(
            characteristicOverride: event.characteristic,
          );
          _scheduleResponderHandshakeFallback();

          if (handled) {
            await peripheralManager.respondWriteRequest(event.request);
            return;
          }

          await _getMessagingService().processIncomingPeripheralData(
            data,
            senderDeviceId: event.central.uuid.toString(),
            senderNodeId: DeviceDeduplicationManager.getDevice(
              event.central.uuid.toString(),
            )?.ephemeralHint,
          );

          await peripheralManager.respondWriteRequest(event.request);
        } catch (e, stack) {
          _logger.warning(
            '⚠️ Failed to handle inbound write from ${event.central.uuid}: $e',
            e,
            stack,
          );
          try {
            await peripheralManager.respondWriteRequestWithError(
              event.request,
              error: GATTError.unlikelyError,
            );
          } catch (_) {}
        }
      });

      _peripheralEventsBound = true;
    } on UnsupportedError catch (e, stack) {
      _logger.fine('Peripheral event binding not supported: $e', e, stack);
    }
  }

  void _maybeStartResponderHandshake({
    GATTCharacteristic? characteristicOverride,
  }) {
    final handshakeService = _getHandshakeService();
    if (handshakeService.isHandshakeInProgress ||
        _connectionManager.connectionState == ChatConnectionState.ready) {
      _logger.info(
        '🛑 Skipping fallback responder handshake: already ${handshakeService.isHandshakeInProgress ? "IN_PROGRESS" : "READY"}',
      );
      return;
    }

    if (_serverHandshakeTimer != null) return;

    final advertisingService = _getAdvertisingService();
    final connectionService = _getConnectionService();
    final central = connectionService.connectedCentral;
    final characteristic =
        characteristicOverride ??
        connectionService.connectedCharacteristic ??
        advertisingService.messageCharacteristic;

    if (central == null || characteristic == null) {
      return;
    }

    final address = central.uuid.toString();
    if (_connectionManager.hasClientLinkForPeer(address) ||
        _connectionManager.hasPendingClientForPeer(address)) {
      _logger.fine(
        '🛑 Skipping responder handshake for ${address.shortId(8)} — client link already active/pending',
      );
      return;
    }

    if (_connectionManager.isResponderHandshakeBlocked(address)) {
      _logger.fine(
        '🛑 Skipping responder handshake for ${address.shortId(8)} — inbound link blocked as duplicate',
      );
      return;
    }

    if (_connectionManager.isServerTeardownDeferred(address)) {
      _logger.fine(
        '⏸️ Server teardown deferred for $address — skipping responder handshake.',
      );
      return;
    }
    if (_connectionManager.isCollisionResolving(address)) {
      _logger.fine(
        '⏸️ Collision resolution in progress for $address — deferring responder handshake',
      );
      return;
    }

    if (!_connectionManager.hasServerConnection(address)) {
      _logger.fine(
        '⏸️ Skipping responder handshake start; no server connection for $address (likely yielded to client).',
      );
      return;
    }

    advertisingService.peripheralHandshakeStarted = true;
    _connectionManager.onCharacteristicFound?.call(characteristic);

    unawaited(
      _getHandshakeService().performHandshake(startAsInitiatorOverride: false),
    );
  }

  void _scheduleResponderHandshakeFallback({
    Duration delay = const Duration(milliseconds: 400),
  }) {
    if (_connectionManager.serverConnectionCount == 0) return;

    if (_connectionManager.connectionState == ChatConnectionState.ready ||
        _getHandshakeService().isHandshakeInProgress) {
      return;
    }

    final address =
        _getConnectionService().connectedCentral?.uuid.toString() ?? '';
    if (address.isNotEmpty &&
        (_connectionManager.hasClientLinkForPeer(address) ||
            _connectionManager.hasPendingClientForPeer(address))) {
      _logger.fine(
        '⏸️ Fallback responder handshake suppressed for ${address.shortId(8)} — client link already active/pending',
      );
      return;
    }
    if (address.isNotEmpty &&
        _connectionManager.isCollisionResolving(address)) {
      _logger.fine(
        '⏸️ Skipping responder handshake fallback; collision resolution in progress for $address',
      );
      return;
    }
    if (address.isNotEmpty &&
        _connectionManager.isServerTeardownDeferred(address)) {
      _logger.fine(
        '⏸️ Fallback suppressed; server teardown deferred for $address',
      );
      return;
    }

    _serverHandshakeTimer?.cancel();
    _serverHandshakeTimer = Timer(delay, () {
      _serverHandshakeTimer = null;
      try {
        if (_connectionManager.serverConnectionCount == 0) return;

        if (_connectionManager.connectionState == ChatConnectionState.ready ||
            _getHandshakeService().isHandshakeInProgress) {
          return;
        }

        if (address.isNotEmpty &&
            (_connectionManager.hasClientLinkForPeer(address) ||
                _connectionManager.hasPendingClientForPeer(address))) {
          _logger.fine(
            '⏸️ Fallback suppressed; client link already active/pending for ${address.shortId(8)}',
          );
          return;
        }

        if (address.isNotEmpty &&
            _connectionManager.isCollisionResolving(address)) {
          _logger.fine(
            '⏸️ Fallback suppressed; collision resolution still in progress for $address',
          );
          return;
        }
        if (address.isNotEmpty &&
            _connectionManager.isServerTeardownDeferred(address)) {
          _logger.fine(
            '⏸️ Fallback suppressed; server teardown deferred for $address',
          );
          return;
        }

        final advertisingService = _getAdvertisingService();
        if (advertisingService.peripheralHandshakeStarted) {
          return;
        }
        _logger.fine(
          '⏳ Fallback: starting responder handshake after delay (notify may be slow)',
        );
        _maybeStartResponderHandshake();
      } catch (_) {}
    });
  }

  void _bindCentralNotificationHandler() {
    if (_centralNotifySub != null) return;

    try {
      _centralNotifySub = _platformHost.centralManager.characteristicNotified
          .listen((event) async {
            try {
              final uuid = event.characteristic.uuid;
              final isServiceChanged = uuid == UUID.fromAddress(0x2A05);

              if (isServiceChanged) {
                final deviceId = event.peripheral.uuid.toString();
                _logger.warning(
                  '🧟 Service Changed (0x2A05) received from $deviceId - Remote app likely restarted. Disconnecting to clear zombie state.',
                );
                await _connectionManager.disconnectClient(deviceId);
                return;
              }

              final handled = await _getHandshakeService()
                  .handleIncomingHandshakeMessage(
                    event.value,
                    isFromPeripheral: false,
                  );

              if (handled) return;

              final deviceId = event.peripheral.uuid.toString();
              final nodeId = DeviceDeduplicationManager.getDevice(
                deviceId,
              )?.ephemeralHint;

              await _getMessagingService().processIncomingPeripheralData(
                event.value,
                senderDeviceId: deviceId,
                senderNodeId: nodeId,
              );
            } catch (e, stack) {
              _logger.warning(
                '⚠️ Failed to process central notification: $e',
                e,
                stack,
              );
            }
          });
    } on UnsupportedError catch (e, stack) {
      _logger.fine('Central notify binding not supported: $e', e, stack);
    }
  }
}
