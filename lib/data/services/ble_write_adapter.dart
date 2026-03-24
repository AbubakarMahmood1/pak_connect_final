import 'dart:async';
import 'dart:typed_data';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/messaging/message_ack_tracker.dart';
import 'package:pak_connect/domain/interfaces/i_ble_write_client.dart';
import '../../domain/messaging/message_chunk_sender.dart';
import '../../data/repositories/contact_repository.dart';
import 'ble_write_client.dart';
import 'ble_state_manager.dart';
import 'outbound_message_sender.dart';

/// Thin adapter to send BLE messages without depending on the monolithic handler.
class BleWriteAdapter {
  BleWriteAdapter({
    required ContactRepository contactRepository,
    required BLEStateManager Function() stateManagerProvider,
    Function(bool)? onMessageOperationChanged,
    Logger? logger,
    IBleWriteClient? writeClient,
  }) : _contactRepository = contactRepository,
       _stateManagerProvider = stateManagerProvider,
       _onMessageOperationChanged = onMessageOperationChanged,
       _logger = logger ?? Logger('BleWriteAdapter'),
       _writeClient = writeClient ?? BleWriteClient() {
    _ackTracker = MessageAckTracker(timeout: Duration(seconds: 5));
    _chunkSender = MessageChunkSender(logger: _logger);
    _outboundSender = OutboundMessageSender(
      logger: _logger,
      ackTracker: _ackTracker,
      chunkSender: _chunkSender,
      centralWrite:
          ({
            required CentralManager centralManager,
            required Peripheral peripheral,
            required GATTCharacteristic characteristic,
            required Uint8List value,
          }) async => _writeClient.writeCentral(
            centralManager: centralManager,
            device: peripheral,
            characteristic: characteristic,
            value: value,
          ),
      peripheralWrite:
          ({
            required PeripheralManager peripheralManager,
            required Central central,
            required GATTCharacteristic characteristic,
            required Uint8List value,
            bool withoutResponse = true,
          }) async => _writeClient.writePeripheral(
            peripheralManager: peripheralManager,
            central: central,
            characteristic: characteristic,
            value: value,
            withoutResponse: withoutResponse,
          ),
    );
  }

  final Logger _logger;
  final ContactRepository _contactRepository;
  final BLEStateManager Function() _stateManagerProvider;
  final Function(bool)? _onMessageOperationChanged;
  final IBleWriteClient _writeClient;

  late final MessageAckTracker _ackTracker;
  late final MessageChunkSender _chunkSender;
  late final OutboundMessageSender _outboundSender;

  void setCurrentNodeId(String nodeId) {
    _outboundSender.setCurrentNodeId(nodeId);
  }

  Future<bool> sendCentralMessage({
    required CentralManager centralManager,
    required Peripheral connectedDevice,
    required GATTCharacteristic messageCharacteristic,
    required String recipientKey,
    required String content,
    required int mtuSize,
    String? messageId,
    String? originalIntendedRecipient,
  }) async {
    try {
      final stateManager = _stateManagerProvider();
      final isPaired = stateManager.isPaired;
      final idType = stateManager.getIdType();

      final truncatedId = recipientKey.length > 16
          ? recipientKey.substring(0, 16)
          : recipientKey;
      _logger.fine(
        '📤 Sending message via adapter using $idType ID: $truncatedId...',
      );

      return await _outboundSender.sendCentralMessage(
        centralManager: centralManager,
        connectedDevice: connectedDevice,
        messageCharacteristic: messageCharacteristic,
        message: content,
        mtuSize: mtuSize,
        messageId: messageId,
        contactPublicKey: isPaired ? recipientKey : null,
        recipientId: recipientKey,
        useEphemeralAddressing: !isPaired,
        originalIntendedRecipient: originalIntendedRecipient,
        contactRepository: _contactRepository,
        stateManager: stateManager,
        onMessageOperationChanged: _onMessageOperationChanged,
        onMessageSent: stateManager.onMessageSent,
        onMessageSentIds: stateManager.onMessageSentIds,
      );
    } catch (e) {
      _logger.warning('⚠️ sendCentralMessage failed via adapter: $e');
      return false;
    }
  }

  Future<bool> sendPeripheralMessage({
    required PeripheralManager peripheralManager,
    required Central connectedCentral,
    required GATTCharacteristic messageCharacteristic,
    required String senderKey,
    required String content,
    required int mtuSize,
    String? messageId,
  }) async {
    try {
      final stateManager = _stateManagerProvider();
      if (!stateManager.isPeripheralMode) {
        _logger.warning('⚠️ Peripheral send skipped - not in peripheral mode');
        return false;
      }

      final isPaired = stateManager.isPaired;
      final idType = stateManager.getIdType();
      final truncatedId = senderKey.length > 16
          ? senderKey.substring(0, 16)
          : senderKey;
      _logger.fine(
        '📤 Peripheral sending via adapter using $idType ID: $truncatedId...',
      );

      return await _outboundSender.sendPeripheralMessage(
        peripheralManager: peripheralManager,
        connectedCentral: connectedCentral,
        messageCharacteristic: messageCharacteristic,
        message: content,
        mtuSize: mtuSize,
        messageId: messageId,
        contactPublicKey: isPaired ? senderKey : null,
        recipientId: senderKey,
        useEphemeralAddressing: !isPaired,
        contactRepository: _contactRepository,
        stateManager: stateManager,
        onMessageSent: stateManager.onMessageSent,
        onMessageSentIds: stateManager.onMessageSentIds,
      );
    } catch (e) {
      _logger.warning('⚠️ sendPeripheralMessage failed via adapter: $e');
      return false;
    }
  }
}
