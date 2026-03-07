Unauthenticated v2 messages can poison downgrade guard state - 386b85b5dcc08191a5c1a9a2ec8bd30e
Link: https://chatgpt.com/codex/security/findings/386b85b5dcc08191a5c1a9a2ec8bd30e?sev=critical%2Chigh%2Cmedium%2Clow
Criticality: medium (attack path: medium)
Status: new

Summary:
The commit introduces a downgrade-guard cache keyed off unauthenticated sender identifiers and updates it for any v2 message regardless of signature. This lets attackers poison the guard and trigger rejection of legitimate v1 messages from spoofed peers.
The downgrade guard caches the highest protocol version seen per peer and rejects subsequent v1 traffic. However, the cache key is derived from untrusted fields (declared sender ID or transport ID) before any signature is required, and the floor is updated even when the message is unsigned. A malicious device can broadcast a v2 text message claiming to be a legacy v1 peer, which upgrades that peer’s floor to v2. After that, legitimate v1 messages from the real peer are rejected. This enables a denial‑of‑service against legacy peers and defeats the intent of the guard by allowing spoofed v2 messages to permanently (until restart/flush) block v1 traffic.

Metadata:
Repo: AbubakarMahmood1/pak_connect_final
Commit: ad829c4
Author: f219462@cfd.nu.edu.pk
Created: 07/03/2026, 14:59:46
Assignee: Unassigned
Signals: Security, Validated, Patch generated, Attack-path

Relevant lines:
/workspace/pak_connect_final/lib/data/services/inbound_text_processor.dart (L358 to 432)
  Note: The protocol floor is recorded after optional signature handling, allowing spoofed v2 messages to poison the downgrade guard state.
      _trackPeerVersionFloor(
        peerKey: versionPeerKey,
        messageVersion: protocolMessage.version,
        messageId: messageId,
      );
  
      return InboundTextResult(
        content: decryptedContent,
        shouldAck: true,
        resolvedSenderKey:
            decryptKeyUsed ??
            resolvedDeclaredSenderForDecrypt ??
            resolvedSenderForDecrypt ??
            resolvedOriginalSenderForDecrypt ??
            senderPublicKey ??
            declaredSenderId ??
            originalSender,
      );
    }
  
    String _versionPeerKey({
      required String? signatureSenderKey,
      required String? declaredSenderId,
      required String? transportSenderId,
    }) {
      if (signatureSenderKey != null && signatureSenderKey.isNotEmpty) {
        return signatureSenderKey;
      }
      if (declaredSenderId != null && declaredSenderId.isNotEmpty) {
        return declaredSenderId;
      }
      return transportSenderId ?? '';
    }
  
    bool _shouldRejectLegacyDowngrade({
      required int messageVersion,
      required String peerKey,
      required String messageId,
    }) {
      if (!_enforceV2DowngradeGuard || messageVersion >= 2 || peerKey.isEmpty) {
        return false;
      }
      final floor = _peerProtocolVersionFloor[peerKey] ?? 1;
      if (floor < 2) {
        return false;
      }
      _logger.warning(
        '🔒 Downgrade guard rejected v$messageVersion message from '
        '${_safeTruncate(peerKey)} after observing v$floor '
        '(messageId=${_safeTruncate(messageId)})',
      );
      return true;
    }
  
    void _trackPeerVersionFloor({
      required String peerKey,
      required int messageVersion,
      required String messageId,
    }) {
      if (!_enforceV2DowngradeGuard || messageVersion < 2 || peerKey.isEmpty) {
        return;
      }
      final currentFloor = _peerProtocolVersionFloor[peerKey] ?? 1;
      if (messageVersion > currentFloor) {
        _peerProtocolVersionFloor[peerKey] = messageVersion;
        _logger.fine(
          '🔒 Protocol floor upgraded for ${_safeTruncate(peerKey)} '
          'to v$messageVersion via ${_safeTruncate(messageId)}',
        );
      }
      if (_peerProtocolVersionFloor.length > 4096) {
        _logger.warning(
          '🔒 Protocol floor cache exceeded 4096 entries; clearing state',
        );
        _peerProtocolVersionFloor.clear();

/workspace/pak_connect_final/lib/data/services/inbound_text_processor.dart (L92 to 121)
  Note: Inbound text processing likewise derives the peer key from unverified sender IDs and applies the downgrade guard without authentication.
      String decryptedContent = content;
      final originalSender = protocolMessage.payload['originalSender'] as String?;
      final declaredSenderId = protocolMessage.senderId ?? originalSender;
      final resolvedSenderForDecrypt = await _resolveSenderKeyForDecrypt(
        senderPublicKey,
      );
      final resolvedOriginalSenderForDecrypt = await _resolveSenderKeyForDecrypt(
        originalSender,
      );
      final resolvedDeclaredSenderForDecrypt = await _resolveSenderKeyForDecrypt(
        declaredSenderId,
      );
      final resolvedSenderForSignature = await _resolveSenderKeyForSignature(
        senderPublicKey,
      );
      final resolvedOriginalSenderForSignature =
          await _resolveSenderKeyForSignature(originalSender);
      final resolvedDeclaredSenderForSignature =
          await _resolveSenderKeyForSignature(declaredSenderId);
      final versionPeerKey = _versionPeerKey(
        signatureSenderKey: resolvedDeclaredSenderForSignature,
        declaredSenderId: declaredSenderId,
        transportSenderId: senderPublicKey,
      );
      if (_shouldRejectLegacyDowngrade(
        messageVersion: protocolMessage.version,
        peerKey: versionPeerKey,
        messageId: messageId,
      )) {
        return const InboundTextResult(content: null, shouldAck: false);

/workspace/pak_connect_final/lib/data/services/protocol_message_handler.dart (L214 to 238)
  Note: The downgrade guard key is derived from untrusted declared/transport sender IDs before any authentication, enabling spoofing of peer identities.
        final messageId = message.textMessageId!;
        final content = message.textContent!;
        final intendedRecipient = message.payload['intendedRecipient'] as String?;
        final declaredSenderId =
            message.senderId ??
            (message.payload['originalSender'] as String?) ??
            fromNodeId;
        final resolvedDecryptSenderId = await _resolveSenderKeyForDecrypt(
          declaredSenderId,
        );
        final resolvedSignatureSenderKey = await _resolveSenderKeyForSignature(
          declaredSenderId,
        );
        final decryptionPeerId = (resolvedDecryptSenderId?.isNotEmpty ?? false)
            ? resolvedDecryptSenderId!
            : fromNodeId;
        final versionPeerKey = _versionPeerKey(
          signatureSenderKey: resolvedSignatureSenderKey,
          declaredSenderId: declaredSenderId,
          transportSenderId: fromNodeId,
        );
        if (_shouldRejectLegacyDowngrade(
          messageVersion: message.version,
          peerKey: versionPeerKey,
          messageId: messageId,

/workspace/pak_connect_final/lib/data/services/protocol_message_handler.dart (L315 to 368)
  Note: Signature verification is optional (only if signature present) and the protocol floor is still tracked afterward, so unsigned v2 messages can upgrade the floor.
        // Verify signature
        if (message.signature != null) {
          String verifyingKey;
          if (message.useEphemeralSigning) {
            if (message.ephemeralSigningKey == null ||
                message.ephemeralSigningKey!.isEmpty) {
              if (message.version >= 2) {
                _logger.severe(
                  '❌ v2 ephemeral signature missing signing key for message $messageId',
                );
                return '[❌ UNTRUSTED MESSAGE - Missing ephemeral signing key]';
              }
              verifyingKey = decryptionPeerId;
            } else {
              verifyingKey = message.ephemeralSigningKey!;
            }
          } else {
            final signatureKey = resolvedSignatureSenderKey ?? declaredSenderId;
            if (signatureKey.isEmpty) {
              _logger.severe(
                '❌ v2 trusted signature missing sender verification key for message $messageId',
              );
              return '[❌ UNTRUSTED MESSAGE - Missing sender identity]';
            }
            verifyingKey = signatureKey;
          }
  
          final signaturePayload = SigningManager.signaturePayloadForMessage(
            message,
            fallbackContent: decryptedContent,
          );
          final isValid = SigningManager.verifySignature(
            signaturePayload,
            message.signature!,
            verifyingKey,
            message.useEphemeralSigning,
          );
  
          if (!isValid) {
            _logger.severe('❌ Signature verification failed');
            return '[❌ UNTRUSTED MESSAGE - Invalid signature]';
          }
  
          _logger.fine(
            '✅ Signature verified (${message.useEphemeralSigning ? "ephemeral" : "real"})',
          );
        }
  
        _sendAck(messageId, fromNodeId);
        _trackPeerVersionFloor(
          peerKey: versionPeerKey,
          messageVersion: message.version,
          messageId: messageId,
        );

/workspace/pak_connect_final/lib/data/services/protocol_message_handler.dart (L422 to 433)
  Note: The floor cache is updated for any v2 message, cementing the spoofed version floor and causing later v1 messages to be rejected.
    void _trackPeerVersionFloor({
      required String peerKey,
      required int messageVersion,
      required String messageId,
    }) {
      if (!_enforceV2DowngradeGuard || messageVersion < 2 || peerKey.isEmpty) {
        return;
      }
      final currentFloor = _peerProtocolVersionFloor[peerKey] ?? 1;
      if (messageVersion > currentFloor) {
        _peerProtocolVersionFloor[peerKey] = messageVersion;
        _logger.fine(


Validation:
Rubric:
- [x] Verify downgrade guard derives peer key from untrusted declared/transport sender IDs before authentication (protocol_message_handler.dart:214-235; inbound_text_processor.dart:92-115).
- [x] Confirm signature verification is optional (only when signature present), allowing unsigned v2 messages through (protocol_message_handler.dart:315-360; inbound_text_processor.dart:287-356).
- [x] Confirm `_trackPeerVersionFloor` is invoked regardless of signature status and updates floor for any v2 message (protocol_message_handler.dart:363-368, 422-432; inbound_text_processor.dart:358-362, 412-423).
- [x] Confirm v1 messages are rejected when cached floor >=2 (protocol_message_handler.dart:402-419; inbound_text_processor.dart:392-409).
Report:
Rubric-driven review completed. Dynamic validation attempts failed due to missing tooling: `dart --version` -> command not found, `flutter --version` -> command not found, `valgrind --version` -> command not found, `gdb --version` -> command not found.

Code evidence: In protocol_message_handler.dart, the downgrade guard key is derived from declared/transport sender IDs before any authentication (lines 214-235), and the guard rejection uses the cached floor to reject v1 (lines 402-419). Signature verification only happens if a signature is present (lines 315-360), yet `_trackPeerVersionFloor` is always called afterward (lines 363-368) and updates the floor for any v2 message without checking authentication (lines 422-432). The inbound_text_processor.dart mirrors this: it computes `versionPeerKey` from resolved signature sender key or the declared/transport IDs (lines 92-115), verifies signatures only when present (lines 287-356), then tracks the protocol floor regardless (lines 358-362), and rejects v1 when the cached floor >=2 (lines 392-409). This supports the reported DoS: a spoofed/unsigned v2 message with a claimed legacy sender ID can poison the downgrade-guard cache and cause later legitimate v1 messages to be rejected.

Proposed patch:
diff --git a/lib/data/services/inbound_text_processor.dart b/lib/data/services/inbound_text_processor.dart
index 9e66faaf82294547b9b93c0d394059f854c23161..ba6a0975931bdabeba0e58084185c61061282ba6 100644
--- a/lib/data/services/inbound_text_processor.dart
+++ b/lib/data/services/inbound_text_processor.dart
@@ -120,68 +120,66 @@ class InboundTextProcessor {
         return const InboundTextResult(content: null, shouldAck: false);
       }
     }
 
     String decryptedContent = content;
     final originalSender = protocolMessage.payload['originalSender'] as String?;
     final declaredSenderId = protocolMessage.senderId ?? originalSender;
     final resolvedSenderForDecrypt = await _resolveSenderKeyForDecrypt(
       senderPublicKey,
     );
     final resolvedOriginalSenderForDecrypt = await _resolveSenderKeyForDecrypt(
       originalSender,
     );
     final resolvedDeclaredSenderForDecrypt = await _resolveSenderKeyForDecrypt(
       declaredSenderId,
     );
     final resolvedSenderForSignature = await _resolveSenderKeyForSignature(
       senderPublicKey,
     );
     final resolvedOriginalSenderForSignature =
         await _resolveSenderKeyForSignature(originalSender);
     final resolvedDeclaredSenderForSignature =
         await _resolveSenderKeyForSignature(declaredSenderId);
     final versionPeerKey = _versionPeerKey(
       signatureSenderKey: resolvedDeclaredSenderForSignature,
-      declaredSenderId: declaredSenderId,
-      transportSenderId: senderPublicKey,
     );
     if (_shouldRejectLegacyDowngrade(
       messageVersion: protocolMessage.version,
       peerKey: versionPeerKey,
       messageId: messageId,
     )) {
       return const InboundTextResult(content: null, shouldAck: false);
     }
 
     final decryptKey = resolvedDeclaredSenderForDecrypt?.isNotEmpty == true
         ? resolvedDeclaredSenderForDecrypt
         : (resolvedSenderForDecrypt?.isNotEmpty == true
               ? resolvedSenderForDecrypt
               : resolvedOriginalSenderForDecrypt);
     String? decryptKeyUsed = decryptKey;
-    var isV2Authenticated = protocolMessage.version < 2;
+    var isV2IdentityAuthenticated = protocolMessage.version < 2;
 
     if (protocolMessage.isEncrypted) {
       if (_shouldRequireV2Signature(
             messageVersion: protocolMessage.version,
             peerKey: versionPeerKey,
           ) &&
           protocolMessage.signature == null) {
         _logger.severe(
           '🔒 v2 encrypted message missing signature under strict/upgraded-peer policy: $messageId',
         );
         return const InboundTextResult(content: null, shouldAck: false);
       }
       final cryptoHeader = protocolMessage.version >= 2
           ? protocolMessage.cryptoHeader
           : null;
       final isSealedV2 = cryptoHeader?.mode == CryptoMode.sealedV1;
 
       if (decryptKey == null && !isSealedV2) {
         _logger.warning('🔒 MESSAGE: Encrypted but no sender key available');
         return const InboundTextResult(
           content: '[❌ Encrypted message but no sender identity]',
           shouldAck: false,
         );
       }
 
@@ -396,95 +394,90 @@ class InboundTextProcessor {
 
       final signaturePayload = SigningManager.signaturePayloadForMessage(
         protocolMessage,
         fallbackContent: decryptedContent,
       );
       final isValid = SigningManager.verifySignature(
         signaturePayload,
         protocolMessage.signature!,
         verifyingKey,
         protocolMessage.useEphemeralSigning,
       );
 
       if (!isValid) {
         _logger.severe('❌ SIGNATURE VERIFICATION FAILED');
         return const InboundTextResult(
           content: '[❌ UNTRUSTED MESSAGE - Signature Invalid]',
           shouldAck: false,
         );
       }
 
       if (protocolMessage.useEphemeralSigning) {
         _logger.info('✅ Ephemeral signature verified');
       } else {
         _logger.info('✅ Real signature verified');
       }
-      if (protocolMessage.version >= 2) {
-        isV2Authenticated = true;
+      if (protocolMessage.version >= 2 && !protocolMessage.useEphemeralSigning) {
+        isV2IdentityAuthenticated = true;
       }
     }
 
-    if (protocolMessage.version < 2 || isV2Authenticated) {
+    if (protocolMessage.version < 2 || isV2IdentityAuthenticated) {
       _trackPeerVersionFloor(
         peerKey: versionPeerKey,
         messageVersion: protocolMessage.version,
         messageId: messageId,
       );
     } else {
       _logger.warning(
         '🔒 Skipping protocol-floor upgrade for unauthenticated '
         'v${protocolMessage.version} message from ${_safeTruncate(versionPeerKey)} '
         '(messageId=${_safeTruncate(messageId)})',
       );
     }
 
     return InboundTextResult(
       content: decryptedContent,
       shouldAck: true,
       resolvedSenderKey:
           decryptKeyUsed ??
           resolvedDeclaredSenderForDecrypt ??
           resolvedSenderForDecrypt ??
           resolvedOriginalSenderForDecrypt ??
           senderPublicKey ??
           declaredSenderId ??
           originalSender,
     );
   }
 
   String _versionPeerKey({
     required String? signatureSenderKey,
-    required String? declaredSenderId,
-    required String? transportSenderId,
   }) {
     if (signatureSenderKey != null && signatureSenderKey.isNotEmpty) {
       return signatureSenderKey;
     }
-    if (declaredSenderId != null && declaredSenderId.isNotEmpty) {
-      return declaredSenderId;
-    }
-    return transportSenderId ?? '';
+    return '';
   }
 
   bool _shouldRejectLegacyDowngrade({
     required int messageVersion,
     required String peerKey,
     required String messageId,
   }) {
     final shouldReject = PeerProtocolVersionGuard.shouldRejectLegacyMessage(
       messageVersion: messageVersion,
       peerKey: peerKey,
     );
     if (!shouldReject) {
       return false;
     }
     final floor = PeerProtocolVersionGuard.floorForPeer(peerKey);
     _logger.warning(
       '🔒 Downgrade guard rejected v$messageVersion message from '
       '${_safeTruncate(peerKey)} after observing v$floor '
       '(messageId=${_safeTruncate(messageId)})',
     );
     return true;
   }
 
   void _trackPeerVersionFloor({
     required String peerKey,
@@ -534,78 +527,78 @@ class InboundTextProcessor {
             persistentKey.isNotEmpty &&
             sessionId != null &&
             sessionId.isNotEmpty) {
           _securityService.registerIdentityMapping(
             persistentPublicKey: persistentKey,
             ephemeralID: sessionId,
           );
         }
         if (sessionId != null && sessionId.isNotEmpty) {
           return sessionId;
         }
         if (persistentKey != null && persistentKey.isNotEmpty) {
           return persistentKey;
         }
         return contact.publicKey;
       }
     } catch (e) {
       _logger.fine(
         'Decrypt sender resolution failed for ${_safeTruncate(candidateKey)}: $e',
       );
     }
     return candidateKey;
   }
 
   Future<String?> _resolveSenderKeyForSignature(String? candidateKey) async {
-    if (candidateKey == null || candidateKey.isEmpty) return candidateKey;
+    if (candidateKey == null || candidateKey.isEmpty) return null;
     try {
       final contact = await _contactRepository.getContactByAnyId(candidateKey);
       if (contact != null) {
         final sessionId = contact.currentEphemeralId;
         final persistentKey = contact.persistentPublicKey;
         if (persistentKey != null &&
             persistentKey.isNotEmpty &&
             sessionId != null &&
             sessionId.isNotEmpty) {
           _securityService.registerIdentityMapping(
             persistentPublicKey: persistentKey,
             ephemeralID: sessionId,
           );
         }
         if (persistentKey != null && persistentKey.isNotEmpty) {
           return persistentKey;
         }
         if (contact.publicKey.isNotEmpty) {
           return contact.publicKey;
         }
       }
     } catch (e) {
       _logger.fine(
         'Signature sender resolution failed for ${_safeTruncate(candidateKey)}: $e',
       );
     }
-    return candidateKey;
+    return null;
   }
 
   bool _isLegacyMode(CryptoMode mode) {
     return mode == CryptoMode.legacyEcdhV1 ||
         mode == CryptoMode.legacyPairingV1 ||
         mode == CryptoMode.legacyGlobalV1;
   }
 
   bool _shouldRequireV2Signature({
     required int messageVersion,
     required String peerKey,
   }) {
     if (messageVersion < 2) {
       return false;
     }
     if (_requireV2Signature) {
       return true;
     }
     if (!PeerProtocolVersionGuard.isEnabled || peerKey.isEmpty) {
       return false;
     }
     return PeerProtocolVersionGuard.floorForPeer(peerKey) >= 2;
   }
 
   bool _shouldRejectLegacyV2ModeForUpgradedPeer({


diff --git a/lib/data/services/protocol_message_handler.dart b/lib/data/services/protocol_message_handler.dart
index aa8cafb9b7ac2df4c5f04497d1defd2cdc247762..c6aafaaa2fbebd840a73670b72d285e37a1d6d1f 100644
--- a/lib/data/services/protocol_message_handler.dart
+++ b/lib/data/services/protocol_message_handler.dart
@@ -219,90 +219,88 @@ class ProtocolMessageHandler implements IProtocolMessageHandler {
   /// Handles text message reception with decryption and signature verification
   Future<String?> _handleTextMessage(
     domain_models.ProtocolMessage message,
     String fromNodeId,
     String? transportMessageId,
   ) async {
     try {
       final messageId = message.textMessageId!;
       final content = message.textContent!;
       final intendedRecipient = message.payload['intendedRecipient'] as String?;
       final declaredSenderId =
           message.senderId ??
           (message.payload['originalSender'] as String?) ??
           fromNodeId;
       final resolvedDecryptSenderId = await _resolveSenderKeyForDecrypt(
         declaredSenderId,
       );
       final resolvedSignatureSenderKey = await _resolveSenderKeyForSignature(
         declaredSenderId,
       );
       final decryptionPeerId = (resolvedDecryptSenderId?.isNotEmpty ?? false)
           ? resolvedDecryptSenderId!
           : fromNodeId;
       final versionPeerKey = _versionPeerKey(
         signatureSenderKey: resolvedSignatureSenderKey,
-        declaredSenderId: declaredSenderId,
-        transportSenderId: fromNodeId,
       );
       if (_shouldRejectLegacyDowngrade(
         messageVersion: message.version,
         peerKey: versionPeerKey,
         messageId: messageId,
       )) {
         return null;
       }
 
       // Check if message is for us
       final isForMe = await isMessageForMe(intendedRecipient);
       if (!isForMe) {
         _logger.fine('💬 Message not for us, ignoring');
         return null;
       }
 
       if (message.version >= 2 && !message.isEncrypted) {
         final isBroadcast = _isBroadcastV2TextMessage(
           recipientId: message.recipientId,
           intendedRecipient: intendedRecipient,
         );
         if (!isBroadcast) {
           _logger.severe(
             '🔒 v2 direct plaintext text message rejected: $messageId',
           );
           return null;
         }
         if (message.signature == null) {
           _logger.severe(
             '🔒 v2 plaintext broadcast missing signature: $messageId',
           );
           return null;
         }
       }
 
       // Decrypt if needed
       String decryptedContent = content;
-      var isV2Authenticated = message.version < 2;
+      var isV2IdentityAuthenticated = message.version < 2;
       if (message.isEncrypted && decryptionPeerId.isNotEmpty) {
         if (_shouldRequireV2Signature(
               messageVersion: message.version,
               peerKey: versionPeerKey,
             ) &&
             message.signature == null) {
           _logger.severe(
             '🔒 v2 encrypted message missing signature under strict/upgraded-peer policy: $messageId',
           );
           return null;
         }
         try {
           if (message.version >= 2) {
             final cryptoHeader = message.cryptoHeader;
             if (cryptoHeader == null) {
               _logger.severe(
                 '🔒 v2 encrypted message missing crypto header: $messageId',
               );
               return null;
             }
             if (cryptoHeader.mode == CryptoMode.sealedV1) {
               final sealedSenderId =
                   message.senderId ??
                   (message.payload['originalSender'] as String?);
               final recipientForSealed = message.recipientId;
@@ -408,100 +406,95 @@ class ProtocolMessageHandler implements IProtocolMessageHandler {
             );
             return '[❌ UNTRUSTED MESSAGE - Missing sender identity]';
           }
           verifyingKey = signatureKey;
         }
 
         final signaturePayload = SigningManager.signaturePayloadForMessage(
           message,
           fallbackContent: decryptedContent,
         );
         final isValid = SigningManager.verifySignature(
           signaturePayload,
           message.signature!,
           verifyingKey,
           message.useEphemeralSigning,
         );
 
         if (!isValid) {
           _logger.severe('❌ Signature verification failed');
           return '[❌ UNTRUSTED MESSAGE - Invalid signature]';
         }
 
         _logger.fine(
           '✅ Signature verified (${message.useEphemeralSigning ? "ephemeral" : "real"})',
         );
-        if (message.version >= 2) {
-          isV2Authenticated = true;
+        if (message.version >= 2 && !message.useEphemeralSigning) {
+          isV2IdentityAuthenticated = true;
         }
       }
 
       _sendAck(messageId, fromNodeId);
-      if (message.version < 2 || isV2Authenticated) {
+      if (message.version < 2 || isV2IdentityAuthenticated) {
         _trackPeerVersionFloor(
           peerKey: versionPeerKey,
           messageVersion: message.version,
           messageId: messageId,
         );
       } else {
         _logger.warning(
           '🔒 Skipping protocol-floor upgrade for unauthenticated '
           'v${message.version} message from ${versionPeerKey.shortId(8)}... '
           '(messageId=${messageId.shortId(8)})',
         );
       }
       final textCallback = _onTextMessageReceived;
       if (textCallback != null) {
         try {
           await textCallback(
             decryptedContent,
             messageId,
             decryptionPeerId.isNotEmpty ? decryptionPeerId : null,
           );
         } catch (e, stack) {
           _logger.warning('⚠️ Inbound text callback failed: $e', e, stack);
         }
       }
       return decryptedContent;
     } catch (e) {
       _logger.severe('Failed to handle text message: $e');
       return null;
     }
   }
 
   String _versionPeerKey({
     required String? signatureSenderKey,
-    required String? declaredSenderId,
-    required String transportSenderId,
   }) {
     if (signatureSenderKey != null && signatureSenderKey.isNotEmpty) {
       return signatureSenderKey;
     }
-    if (declaredSenderId != null && declaredSenderId.isNotEmpty) {
-      return declaredSenderId;
-    }
-    return transportSenderId;
+    return '';
   }
 
   bool _shouldRejectLegacyDowngrade({
     required int messageVersion,
     required String peerKey,
     required String messageId,
   }) {
     final shouldReject = PeerProtocolVersionGuard.shouldRejectLegacyMessage(
       messageVersion: messageVersion,
       peerKey: peerKey,
     );
     if (!shouldReject) {
       return false;
     }
     final floor = PeerProtocolVersionGuard.floorForPeer(peerKey);
     _logger.warning(
       '🔒 Downgrade guard rejected v$messageVersion message from '
       '${peerKey.shortId(8)}... after observing v$floor capability '
       '(messageId=${messageId.shortId(8)})',
     );
     return true;
   }
 
   void _trackPeerVersionFloor({
     required String peerKey,
@@ -741,79 +734,79 @@ class ProtocolMessageHandler implements IProtocolMessageHandler {
             sessionId != null &&
             sessionId.isNotEmpty) {
           _securityService.registerIdentityMapping(
             persistentPublicKey: persistentKey,
             ephemeralID: sessionId,
           );
         }
         if (sessionId != null && sessionId.isNotEmpty) {
           return sessionId;
         }
         if (persistentKey != null && persistentKey.isNotEmpty) {
           return persistentKey;
         }
         return contact.publicKey;
       }
     } catch (e) {
       _logger.fine(
         'Decrypt sender resolution failed for ${candidateKey.shortId(8)}: $e',
       );
     }
     return candidateKey;
   }
 
   Future<String?> _resolveSenderKeyForSignature(String? candidateKey) async {
     if (candidateKey == null || candidateKey.isEmpty) {
-      return candidateKey;
+      return null;
     }
     try {
       final contact = await _contactRepository.getContactByAnyId(candidateKey);
       if (contact != null) {
         final sessionId = contact.currentEphemeralId;
         final persistentKey = contact.persistentPublicKey;
         if (persistentKey != null &&
             persistentKey.isNotEmpty &&
             sessionId != null &&
             sessionId.isNotEmpty) {
           _securityService.registerIdentityMapping(
             persistentPublicKey: persistentKey,
             ephemeralID: sessionId,
           );
         }
         if (persistentKey != null && persistentKey.isNotEmpty) {
           return persistentKey;
         }
         if (contact.publicKey.isNotEmpty) {
           return contact.publicKey;
         }
       }
     } catch (e) {
       _logger.fine(
         'Signature sender resolution failed for ${candidateKey.shortId(8)}: $e',
       );
     }
-    return candidateKey;
+    return null;
   }
 
   bool _isLegacyMode(CryptoMode mode) {
     return mode == CryptoMode.legacyEcdhV1 ||
         mode == CryptoMode.legacyPairingV1 ||
         mode == CryptoMode.legacyGlobalV1;
   }
 
   bool _shouldRejectLegacyV2ModeForUpgradedPeer({
     required String peerKey,
     required CryptoMode mode,
     required String messageId,
   }) {
     if (!_isLegacyMode(mode) || peerKey.isEmpty) {
       return false;
     }
 
     final floor = PeerProtocolVersionGuard.floorForPeer(peerKey);
     if (floor < 2) {
       return false;
     }
 
     _logger.warning(
       '🔒 v2 legacy decrypt mode blocked for upgraded peer '
       '${peerKey.shortId(8)}... (floor=v$floor, mode=${mode.wireValue}, '

Attack-path analysis:
Final: medium | Decider: model_decided | Matrix severity: low | Policy adjusted: low
Rationale: The bug is real and reachable via the BLE attack surface, but it causes targeted availability loss for legacy v1 peers without compromising confidentiality or integrity. Proximity and legacy-traffic preconditions keep likelihood and impact in the medium range.
Likelihood: medium - BLE adjacency is required and the target must have legacy v1 peers, but crafting unsigned v2 messages is straightforward and does not require credentials.
Impact: medium - A nearby attacker can force legacy v1 messages from a real peer to be dropped by poisoning the downgrade guard cache; impact is availability only, not confidentiality or integrity.
Assumptions:
- PAKCONNECT_ENFORCE_V2_DOWNGRADE_GUARD is enabled (default true) on deployed builds.
- Targets still accept legacy v1 traffic from some peers.
- An attacker can transmit BLE protocol messages while in proximity to the victim device.
- Attacker can send BLE protocol messages to the victim device
- Victim has legacy v1 peers and downgrade guard enabled
Path:
BLE payload -> processReceivedData -> _handleTextMessage/_trackPeerVersionFloor -> floor>=2 -> _shouldRejectLegacyDowngrade -> drop v1
Narrative:
Inbound BLE protocol messages compute a version cache key from declared/transport sender IDs before authentication and call _trackPeerVersionFloor even when no signature is present. This lets a nearby attacker spoof a v2 message for a legacy peer and poison the downgrade-guard cache so future legitimate v1 messages are rejected, causing availability loss for that peer.
Evidence:
- [object Object]
- [object Object]
- [object Object]
- [object Object]
Controls:
- PAKCONNECT_ENFORCE_V2_DOWNGRADE_GUARD flag (default true)
- Signature verification when a signature is present
- Intended-recipient check before processing inbound text
Blindspots:
- Static analysis only; cannot confirm build-time flags or prevalence of v1 legacy peers in deployments.
- No dynamic testing of BLE message handling or guard behavior in a live mesh.