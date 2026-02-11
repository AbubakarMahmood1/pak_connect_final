part of 'ble_messaging_service.dart';

class _BleMessagingReceiveHelper {
  _BleMessagingReceiveHelper(this._owner);

  final BLEMessagingService _owner;

  Future<String> resolveSenderNodeId(
    String deviceId, {
    String? providedNodeId,
  }) async {
    bool isPlaceholder(String value) {
      if (value.isEmpty || value == BLEMessagingService._noHintValue) {
        return true;
      }
      final normalized = value.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
      return normalized.isNotEmpty && RegExp(r'^0+$').hasMatch(normalized);
    }

    if (providedNodeId != null && !isPlaceholder(providedNodeId)) {
      return providedNodeId;
    }

    final dedupDevice = DeviceDeduplicationManager.getDevice(deviceId);
    final contact = dedupDevice?.contactInfo?.contact;

    final sessionId = contact?.currentEphemeralId;
    if (sessionId != null && sessionId.isNotEmpty) {
      return sessionId;
    }

    final contactId = contact?.chatId;
    if (contactId != null && contactId.isNotEmpty) {
      return contactId;
    }

    final hint = dedupDevice?.ephemeralHint;
    if (hint != null &&
        hint.isNotEmpty &&
        hint != BLEMessagingService._noHintValue) {
      final contactFromHint = await _owner._contactRepository.getContactByAnyId(
        hint,
      );
      if (contactFromHint?.currentEphemeralId?.isNotEmpty == true) {
        return contactFromHint!.currentEphemeralId!;
      }
      if (contactFromHint != null) {
        return contactFromHint.chatId;
      }
      return hint;
    }

    // Fallback: use active peer session from state manager when device/hint
    // are placeholders (e.g., 0000... MAC).
    final theirEphemeral = _owner._stateManager.theirEphemeralId;
    if (theirEphemeral != null && theirEphemeral.isNotEmpty) {
      return theirEphemeral;
    }
    final currentSession = _owner._stateManager.currentSessionId;
    if (currentSession != null && currentSession.isNotEmpty) {
      return currentSession;
    }

    return deviceId;
  }

  Future<void> handleInboundTextMessage({
    required String content,
    String? messageId,
    String? senderNodeId,
  }) async {
    try {
      final senderId = await resolveStorageSenderId(senderNodeId);
      final chatId = ChatId(ChatUtils.generateChatId(senderId));
      final resolvedMessageId = (messageId != null && messageId.isNotEmpty)
          ? messageId
          : generateFallbackMessageId(senderId, content);

      _owner.extractedMessageId = resolvedMessageId;

      final existing = await _owner._messageRepository.getMessageById(
        MessageId(resolvedMessageId),
      );
      if (existing != null) {
        return;
      }

      final inbound = Message(
        id: MessageId(resolvedMessageId),
        chatId: chatId,
        content: content,
        timestamp: DateTime.now(),
        isFromMe: false,
        status: MessageStatus.delivered,
      );

      await _owner._messageRepository.saveMessage(inbound);
      _owner._emitReceivedMessage(content);

      final previewId = resolvedMessageId.length > 8
          ? resolvedMessageId.substring(0, 8)
          : resolvedMessageId;
      final previewChat = chatId.value.length > 8
          ? chatId.value.substring(0, 8)
          : chatId.value;
      _owner._logger.info(
        '💾 Stored inbound message $previewId... in chat $previewChat...',
      );
    } catch (e) {
      _owner._logger.warning('⚠️ Failed to persist inbound message: $e');
    }
  }

  Future<String> resolveStorageSenderId(String? senderNodeId) async {
    final fallbackId =
        _owner._stateManager.theirPersistentKey ??
        _owner._stateManager.currentSessionId;
    final candidate = senderNodeId?.isNotEmpty == true
        ? senderNodeId!
        : (fallbackId ?? 'unknown_sender');

    try {
      final contact = await _owner._contactRepository.getContactByAnyId(
        candidate,
      );
      if (contact != null) {
        if (contact.persistentPublicKey?.isNotEmpty == true) {
          return contact.persistentPublicKey!;
        }
        return contact.publicKey;
      }
    } catch (_) {
      // Fallback below
    }

    return candidate;
  }

  String generateFallbackMessageId(String senderId, String content) {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final payload = '$timestamp|$senderId|$content';
    final hash = sha256.convert(utf8.encode(payload)).toString();
    return 'rx_${hash.substring(0, 32)}';
  }
}
