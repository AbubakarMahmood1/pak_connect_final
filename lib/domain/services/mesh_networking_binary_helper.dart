part of 'mesh_networking_service.dart';

class _MeshNetworkingBinaryHelper {
  _MeshNetworkingBinaryHelper(this._owner);

  final MeshNetworkingService _owner;

  Future<String> sendOrQueueBinaryMedia({
    required Uint8List data,
    required String recipientId,
    required int originalType,
    Map<String, dynamic>? metadata,
  }) async {
    final record = await _owner._mediaStore.persist(
      data: data,
      metadata: {
        'recipientId': recipientId,
        'originalType': originalType,
        if (metadata != null) ...metadata,
      },
    );

    await _owner._storeBinaryMessage(
      transferId: record.transferId,
      filePath: record.filePath,
      size: (record.bytes ?? data).length,
      originalType: originalType,
      isFromMe: true,
      status: MessageStatus.sending,
      peerNodeId: recipientId,
      recipientId: recipientId,
    );

    if (!_owner._bleService.isConnected ||
        !_owner._bleService.canSendMessages) {
      MeshNetworkingService._logger.fine(
        '⚠️ Offline for binary send; queued transfer ${record.transferId} for $recipientId',
      );
      try {
        await _owner._bleService.sendBinaryMedia(
          data: record.bytes ?? data,
          recipientId: recipientId,
          originalType: originalType,
          metadata: metadata,
          persistOnly: true,
        );
      } catch (e) {
        MeshNetworkingService._logger.fine(
          '⚠️ Priming BLE media store for ${record.transferId} failed: $e',
        );
      }

      _owner._pendingBinarySends.add(
        _PendingBinarySend(
          transferId: record.transferId,
          recipientId: recipientId,
          originalType: originalType,
        ),
      );
      await _owner._persistPendingBinarySends();
      return record.transferId;
    }

    try {
      await _owner._bleService.sendBinaryMedia(
        data: record.bytes ?? data,
        recipientId: recipientId,
        originalType: originalType,
        metadata: metadata,
      );
      await _owner._updateBinaryMessageStatus(
        record.transferId,
        MessageStatus.sent,
      );
    } catch (e) {
      MeshNetworkingService._logger.fine(
        '⚠️ Binary send failed, queued for retry: ${record.transferId} ($e)',
      );
      _owner._pendingBinarySends.add(
        _PendingBinarySend(
          transferId: record.transferId,
          recipientId: recipientId,
          originalType: originalType,
        ),
      );
      await _owner._persistPendingBinarySends();
    }

    return record.transferId;
  }

  Future<void> loadPendingBinarySends() async {
    try {
      final docs = await _owner._getDocsDir();
      final file = File('${docs.path}/pending_binary_sends.json');
      if (!await file.exists()) {
        return;
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is List) {
        _owner._pendingBinarySends
          ..clear()
          ..addAll(
            decoded.whereType<Map<String, dynamic>>().map(
              (m) => _PendingBinarySend(
                transferId: m['transferId'] as String,
                recipientId: m['recipientId'] as String,
                originalType: m['originalType'] as int,
              ),
            ),
          );
        MeshNetworkingService._logger.fine(
          '📂 Loaded ${_owner._pendingBinarySends.length} pending binary sends from disk',
        );
      }
    } catch (e) {
      MeshNetworkingService._logger.fine(
        '⚠️ Failed to load pending binary sends: $e',
      );
    }
  }

  Future<void> persistPendingBinarySends() async {
    try {
      final docs = await _owner._getDocsDir();
      final file = File('${docs.path}/pending_binary_sends.json');
      final payload = _owner._pendingBinarySends
          .map(
            (p) => {
              'transferId': p.transferId,
              'recipientId': p.recipientId,
              'originalType': p.originalType,
            },
          )
          .toList();
      await file.writeAsString(jsonEncode(payload), flush: true);
    } catch (e) {
      MeshNetworkingService._logger.fine(
        '⚠️ Failed to persist pending binary sends: $e',
      );
    }
  }

  Future<void> handleBinaryPayload(BinaryPayload payload) async {
    try {
      final record = await _owner._mediaStore.persist(
        data: payload.data,
        metadata: {
          'fragmentId': payload.fragmentId,
          'originalType': payload.originalType,
          'recipient': payload.recipient,
          'ttl': payload.ttl,
          if (payload.senderNodeId != null)
            'senderNodeId': payload.senderNodeId,
        },
      );
      final event = ReceivedBinaryEvent(
        fragmentId: payload.fragmentId,
        originalType: payload.originalType,
        filePath: record.filePath,
        transferId: record.transferId,
        size: payload.data.length,
        ttl: payload.ttl,
        recipient: payload.recipient,
        senderNodeId: payload.senderNodeId,
      );
      _owner._binaryController.add(event);
      _owner._binaryEventHandler?.call(event);
      MeshNetworkingService._logger.info(
        '💾 Stored binary payload ${payload.fragmentId.shortId(8)}... (${payload.data.length}B) at ${record.filePath}',
      );
      await _owner._storeBinaryMessage(
        transferId: record.transferId,
        filePath: record.filePath,
        size: payload.data.length,
        originalType: payload.originalType,
        isFromMe: false,
        peerNodeId:
            payload.senderNodeId ??
            _owner._bleService.currentSessionId ??
            payload.recipient,
        recipientId: payload.recipient,
        status: MessageStatus.delivered,
      );
    } catch (e) {
      MeshNetworkingService._logger.warning(
        'Failed to persist binary payload ${payload.fragmentId}: $e',
      );
    }
  }

  Future<void> flushPendingBinarySends() async {
    if (_owner._pendingBinarySends.isEmpty) return;
    if (!_owner._bleService.isConnected ||
        !_owner._bleService.canSendMessages) {
      return;
    }

    final pending = List<_PendingBinarySend>.from(_owner._pendingBinarySends);
    _owner._pendingBinarySends.clear();

    for (final pendingSend in pending) {
      final success = await _owner.retryBinaryMedia(
        transferId: pendingSend.transferId,
        recipientId: pendingSend.recipientId,
        originalType: pendingSend.originalType,
      );
      if (!success) {
        _owner._pendingBinarySends.add(pendingSend);
        MeshNetworkingService._logger.fine(
          '⚠️ Re-queued binary transfer ${pendingSend.transferId} for ${pendingSend.recipientId}',
        );
      } else {
        MeshNetworkingService._logger.fine(
          '✅ Retried binary transfer ${pendingSend.transferId} for ${pendingSend.recipientId}',
        );
        await _owner._updateBinaryMessageStatus(
          pendingSend.transferId,
          MessageStatus.sent,
        );
      }
    }
    await _owner._persistPendingBinarySends();
  }

  Future<void> storeBinaryMessage({
    required String transferId,
    required String filePath,
    required int size,
    required int originalType,
    required bool isFromMe,
    required MessageStatus status,
    String? peerNodeId,
    String? recipientId,
  }) async {
    final peerId = (peerNodeId ?? '').isNotEmpty ? peerNodeId! : null;
    if (peerId == null) {
      MeshNetworkingService._logger.fine(
        '⚠️ Skipping binary message persistence for $transferId (no peer id)',
      );
      return;
    }

    final messageId = MessageId(transferId);
    final existing = await _owner._messageRepository.getMessageById(messageId);
    if (existing != null) return;

    final chatId = ChatId(ChatUtils.generateChatId(peerId));
    final name = filePath.split('/').last;
    final attachment = MessageAttachment(
      id: transferId,
      type: originalType == BinaryPayloadType.media ? 'media' : 'binary',
      name: name,
      size: size,
      localPath: filePath,
      metadata: {
        'transferId': transferId,
        'originalType': originalType,
        'peerNodeId': peerId,
        'recipientId': ?recipientId,
        'direction': isFromMe ? 'outbound' : 'inbound',
      },
    );

    final message = EnhancedMessage(
      id: messageId,
      chatId: chatId,
      content: name,
      timestamp: DateTime.now(),
      isFromMe: isFromMe,
      status: status,
      attachments: [attachment],
      metadata: {
        'transferId': transferId,
        'filePath': filePath,
        'size': size,
        'originalType': originalType,
        'peerNodeId': peerId,
        'recipientId': ?recipientId,
      },
    );

    await _owner._messageRepository.saveMessage(message);
    MeshNetworkingService._logger.fine(
      '💾 Stored binary message ${transferId.shortId(8)}... in chat ${chatId.value.shortId(8)}...',
    );
  }

  Future<void> updateBinaryMessageStatus(
    String transferId,
    MessageStatus status,
  ) async {
    final existing = await _owner._messageRepository.getMessageById(
      MessageId(transferId),
    );
    if (existing == null || existing.status == status) return;

    final updated = existing.copyWith(status: status);
    await _owner._messageRepository.updateMessage(updated);
  }
}
