import 'dart:io' show Platform;

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';

import '../../domain/constants/ble_constants.dart';

class BleConnectionGattController {
  BleConnectionGattController({
    required Logger logger,
    required CentralManager centralManager,
    required bool Function(Object error) isTransientConnectError,
  }) : _logger = logger,
       _centralManager = centralManager,
       _isTransientConnectError = isTransientConnectError;

  final Logger _logger;
  final CentralManager _centralManager;
  final bool Function(Object error) _isTransientConnectError;

  Future<void> connectWithRetry({
    required Peripheral device,
    required String formattedAddress,
  }) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        _logger.info(
          '🔌 Connecting (attempt $attempt/2) to $formattedAddress @${DateTime.now().toIso8601String()}...',
        );
        await _centralManager
            .connect(device)
            .timeout(
              const Duration(seconds: 20),
              onTimeout: () =>
                  throw Exception('Connection timeout after 20 seconds'),
            );
        return;
      } catch (error) {
        _logger.warning('❌ Connect attempt $attempt failed: $error');
        final transient = _isTransientConnectError(error);
        if (attempt < 2 && transient) {
          try {
            await _centralManager.disconnect(device);
          } catch (_) {}
          await Future.delayed(const Duration(milliseconds: 1200));
          continue;
        }
        throw Exception(error.toString());
      }
    }
  }

  Future<int> detectOptimalMtu({
    required Peripheral device,
    required String formattedAddress,
  }) async {
    try {
      _logger.info('📏 Attempting MTU detection for $formattedAddress...');

      int negotiatedMtu = 23;
      if (Platform.isAndroid) {
        try {
          negotiatedMtu = await _centralManager.requestMTU(device, mtu: 517);
          _logger.info(
            '✅ Successfully negotiated larger MTU: $negotiatedMtu bytes',
          );
        } catch (error) {
          _logger.warning(
            '⚠️ MTU negotiation failed, using default 23: $error',
          );
        }
      }

      final maxWriteLength = await _centralManager.getMaximumWriteLength(
        device,
        type: GATTCharacteristicWriteType.withResponse,
      );

      final mtu = maxWriteLength.clamp(20, negotiatedMtu - 3);
      _logger.info('✅ MTU detection successful: $mtu bytes');
      return mtu;
    } catch (error) {
      _logger.warning(
        '❌ MTU detection completely failed for $formattedAddress: $error',
      );
      const fallbackMtu = 20;
      _logger.info('⚠️ Using conservative fallback MTU: $fallbackMtu bytes');
      return fallbackMtu;
    }
  }

  Future<GATTCharacteristic> discoverMessageCharacteristic({
    required Peripheral device,
    required String formattedAddress,
  }) async {
    GATTService? messagingService;

    for (int retry = 0; retry < 3; retry++) {
      try {
        _logger.info(
          'Discovering services for $formattedAddress, attempt ${retry + 1}/3 @${DateTime.now().toIso8601String()}',
        );
        final services = await _centralManager.discoverGATT(device);

        messagingService = services.firstWhere(
          (service) => service.uuid == BLEConstants.serviceUUID,
        );

        _logger.info(
          '✅ Messaging service found on attempt ${retry + 1} @${DateTime.now().toIso8601String()}',
        );
        break;
      } catch (error) {
        _logger.warning(
          '❌ Service discovery failed on attempt ${retry + 1}: $error',
        );
        if (retry < 2) {
          await Future.delayed(const Duration(milliseconds: 1000));
        } else {
          throw Exception('Messaging service not found after 3 attempts');
        }
      }
    }

    if (messagingService == null) {
      throw Exception('Messaging service not found after retries');
    }

    return messagingService.characteristics.firstWhere(
      (characteristic) =>
          characteristic.uuid == BLEConstants.messageCharacteristicUUID,
      orElse: () => throw Exception('Message characteristic not found'),
    );
  }

  Future<void> enableNotifications({
    required Peripheral device,
    required GATTCharacteristic characteristic,
    required String formattedAddress,
  }) async {
    if (!characteristic.properties.contains(
      GATTCharacteristicProperty.notify,
    )) {
      return;
    }

    await _centralManager.setCharacteristicNotifyState(
      device,
      characteristic,
      state: true,
    );

    _logger.info(
      '✅ Notifications enabled successfully for $formattedAddress @${DateTime.now().toIso8601String()}',
    );
    await Future.delayed(const Duration(milliseconds: 200));
  }
}
