Payload senderId trusted for attribution enables spoofing - 164b9efa05c8819195ab10854ffd5bbc

Link: https://chatgpt.com/codex/security/findings/164b9efa05c8819195ab10854ffd5bbc?sev=critical%2Chigh%2Cmedium%2Clow

Criticality: medium (attack path: medium)

Status: new



Summary:

Introduced trust of payload senderId for decryption/attribution without binding it to the transport identity or signature, enabling message spoofing/impersonation.

The commit adds a senderId field to v2 payloads and updates inbound processing to prioritize that declared sender over the transport sender. Because senderId is attacker-controlled and not authenticated by the signature (signatures cover only the decrypted content), a malicious BLE node can craft an unsigned or ephemeral‑signed message with senderId set to a victim contact and have it decrypted/attributed as coming from that contact. The inbound path also uses the declared sender for callback routing, so UI and trust logic can be misled. Previously, sender identity was derived from the transport sender, which limited impersonation to the transport layer.



Metadata:

Repo: AbubakarMahmood1/pak\_connect\_final

Commit: e59ef6c

Author: f219462@cfd.nu.edu.pk

Created: 07/03/2026, 15:00:15

Assignee: Unassigned

Signals: Security, Validated, Patch generated, Attack-path



Relevant lines:

/workspace/pak\_connect\_final/lib/data/services/inbound\_text\_processor.dart (L291 to 301)

&nbsp; Note: Resolved sender key for attribution includes the untrusted declared senderId, enabling spoofing if signatures are missing or ephemeral.

&nbsp;     return InboundTextResult(

&nbsp;       content: decryptedContent,

&nbsp;       shouldAck: true,

&nbsp;       resolvedSenderKey:

&nbsp;           decryptKeyUsed ??

&nbsp;           resolvedDeclaredSender ??

&nbsp;           resolvedSender ??

&nbsp;           resolvedOriginalSender ??

&nbsp;           senderPublicKey ??

&nbsp;           declaredSenderId ??

&nbsp;           originalSender,



/workspace/pak\_connect\_final/lib/data/services/inbound\_text\_processor.dart (L83 to 94)

&nbsp; Note: Inbound processing now prioritizes declared senderId from the payload for decrypt key selection.

&nbsp;     final originalSender = protocolMessage.payload\['originalSender'] as String?;

&nbsp;     final declaredSenderId = protocolMessage.senderId ?? originalSender;

&nbsp;     final resolvedSender = await \_resolveSenderKey(senderPublicKey);

&nbsp;     final resolvedOriginalSender = await \_resolveSenderKey(originalSender);

&nbsp;     final resolvedDeclaredSender = await \_resolveSenderKey(declaredSenderId);

&nbsp; 

&nbsp;     final decryptKey = resolvedDeclaredSender?.isNotEmpty == true

&nbsp;         ? resolvedDeclaredSender

&nbsp;         : (resolvedSender?.isNotEmpty == true

&nbsp;               ? resolvedSender

&nbsp;               : resolvedOriginalSender);

&nbsp;     String? decryptKeyUsed = decryptKey;



/workspace/pak\_connect\_final/lib/data/services/outbound\_message\_sender.dart (L190 to 195)

&nbsp; Note: Sender-controlled senderId is added to the payload, introducing an untrusted identity field.

&nbsp;         ...protocolMessage.payload,

&nbsp;         'encryptionMethod': encryptionMethod,

&nbsp;         'intendedRecipient': intendedRecipientPayload,

&nbsp;         'originalSender': finalSenderIf,

&nbsp;         'senderId': finalSenderIf,

&nbsp;         if (cryptoHeader != null) 'crypto': cryptoHeader.toJson(),



/workspace/pak\_connect\_final/lib/data/services/protocol\_message\_handler.dart (L207 to 215)

&nbsp; Note: Protocol handler derives decryption/identity from declared senderId instead of the transport sender.

&nbsp;       final declaredSenderId =

&nbsp;           message.senderId ??

&nbsp;           (message.payload\['originalSender'] as String?) ??

&nbsp;           fromNodeId;

&nbsp;       final resolvedSenderId = await \_resolveSenderKey(declaredSenderId);

&nbsp;       final decryptionPeerId = (resolvedSenderId?.isNotEmpty ?? false)

&nbsp;           ? resolvedSenderId!

&nbsp;           : fromNodeId;



/workspace/pak\_connect\_final/lib/data/services/protocol\_message\_handler.dart (L307 to 315)

&nbsp; Note: Callbacks receive the declared sender-derived identity, so spoofed senderId affects UI attribution.

&nbsp;       \_sendAck(messageId, fromNodeId);

&nbsp;       final textCallback = \_onTextMessageReceived;

&nbsp;       if (textCallback != null) {

&nbsp;         try {

&nbsp;           await textCallback(

&nbsp;             decryptedContent,

&nbsp;             messageId,

&nbsp;             decryptionPeerId.isNotEmpty ? decryptionPeerId : null,

&nbsp;           );





Validation:

Rubric:

\- \[x] Confirm v2 outbound payload includes senderId sourced from the sender (outbound\_message\_sender.dart:189-195).

\- \[x] Verify inbound decrypt/attribution prioritizes declared senderId over transport sender (inbound\_text\_processor.dart:83-94, 291-301).

\- \[x] Confirm protocol handler uses declared senderId for decryptionPeerId and callback routing (protocol\_message\_handler.dart:207-214, 307-315).

\- \[x] Show signature verification covers only message content and is skipped when signature is null, leaving senderId unauthenticated (inbound\_text\_processor.dart:224-275; signing\_manager.dart:11-79).

\- \[x] Assess lack of binding between transport sender and senderId enables impersonation.

Report:

Dynamic reproduction attempts failed due to missing toolchain: `dart --version` and `flutter --version` returned “command not found,” so no build/run for a crash PoC; `valgrind --version` and `gdb --version` were also unavailable. Code review confirms the spoofing path: outbound v2 payloads include attacker-controlled `senderId` sourced from the local sender (lib/data/services/outbound\_message\_sender.dart:189-195). Inbound processing prioritizes the declared sender (`protocolMessage.senderId`) over the transport sender/original sender when selecting the decrypt key (lib/data/services/inbound\_text\_processor.dart:83-94) and when setting `resolvedSenderKey` for attribution (lib/data/services/inbound\_text\_processor.dart:291-301). The protocol handler similarly derives `decryptionPeerId` from the declared sender and passes it to callbacks that drive UI attribution (lib/data/services/protocol\_message\_handler.dart:207-214, 307-315). Signatures cover only decrypted content, and verification is skipped entirely if `signature` is null (lib/data/services/inbound\_text\_processor.dart:224-275; lib/domain/services/signing\_manager.dart:11-79), so `senderId` is not authenticated. This allows a BLE sender to spoof `senderId` in the payload and have the message decrypted/attributed as the victim contact, especially for unsigned or attacker-ephemeral-signed messages.



Proposed patch:

diff --git a/lib/data/services/inbound\_text\_processor.dart b/lib/data/services/inbound\_text\_processor.dart

index 9e66faaf82294547b9b93c0d394059f854c23161..c97cd88ccc3214b59d62ef694b5c0ce4e3bf7ef3 100644

--- a/lib/data/services/inbound\_text\_processor.dart

+++ b/lib/data/services/inbound\_text\_processor.dart

@@ -131,92 +131,96 @@ class InboundTextProcessor {

&nbsp;      originalSender,

&nbsp;    );

&nbsp;    final resolvedDeclaredSenderForDecrypt = await \_resolveSenderKeyForDecrypt(

&nbsp;      declaredSenderId,

&nbsp;    );

&nbsp;    final resolvedSenderForSignature = await \_resolveSenderKeyForSignature(

&nbsp;      senderPublicKey,

&nbsp;    );

&nbsp;    final resolvedOriginalSenderForSignature =

&nbsp;        await \_resolveSenderKeyForSignature(originalSender);

&nbsp;    final resolvedDeclaredSenderForSignature =

&nbsp;        await \_resolveSenderKeyForSignature(declaredSenderId);

&nbsp;    final versionPeerKey = \_versionPeerKey(

&nbsp;      signatureSenderKey: resolvedDeclaredSenderForSignature,

&nbsp;      declaredSenderId: declaredSenderId,

&nbsp;      transportSenderId: senderPublicKey,

&nbsp;    );

&nbsp;    if (\_shouldRejectLegacyDowngrade(

&nbsp;      messageVersion: protocolMessage.version,

&nbsp;      peerKey: versionPeerKey,

&nbsp;      messageId: messageId,

&nbsp;    )) {

&nbsp;      return const InboundTextResult(content: null, shouldAck: false);

&nbsp;    }

&nbsp;

\-    final decryptKey = resolvedDeclaredSenderForDecrypt?.isNotEmpty == true

\-        ? resolvedDeclaredSenderForDecrypt

\-        : (resolvedSenderForDecrypt?.isNotEmpty == true

\-              ? resolvedSenderForDecrypt

\-              : resolvedOriginalSenderForDecrypt);

\+    final decryptKey = resolvedSenderForDecrypt?.isNotEmpty == true

\+        ? resolvedSenderForDecrypt

\+        : (resolvedOriginalSenderForDecrypt?.isNotEmpty == true

\+              ? resolvedOriginalSenderForDecrypt

\+              : resolvedDeclaredSenderForDecrypt);

&nbsp;    String? decryptKeyUsed = decryptKey;

&nbsp;    var isV2Authenticated = protocolMessage.version < 2;

&nbsp;

&nbsp;    if (protocolMessage.isEncrypted) {

&nbsp;      if (\_shouldRequireV2Signature(

&nbsp;            messageVersion: protocolMessage.version,

&nbsp;            peerKey: versionPeerKey,

&nbsp;          ) \&\&

&nbsp;          protocolMessage.signature == null) {

&nbsp;        \_logger.severe(

&nbsp;          '🔒 v2 encrypted message missing signature under strict/upgraded-peer policy: $messageId',

&nbsp;        );

&nbsp;        return const InboundTextResult(content: null, shouldAck: false);

&nbsp;      }

&nbsp;      final cryptoHeader = protocolMessage.version >= 2

&nbsp;          ? protocolMessage.cryptoHeader

&nbsp;          : null;

&nbsp;      final isSealedV2 = cryptoHeader?.mode == CryptoMode.sealedV1;

&nbsp;

&nbsp;      if (decryptKey == null \&\& !isSealedV2) {

&nbsp;        \_logger.warning('🔒 MESSAGE: Encrypted but no sender key available');

&nbsp;        return const InboundTextResult(

&nbsp;          content: '\[❌ Encrypted message but no sender identity]',

&nbsp;          shouldAck: false,

&nbsp;        );

&nbsp;      }

&nbsp;

&nbsp;      try {

&nbsp;        if (protocolMessage.version >= 2) {

&nbsp;          if (cryptoHeader == null) {

&nbsp;            \_logger.severe(

&nbsp;              '🔒 v2 encrypted message missing crypto header: $messageId',

&nbsp;            );

&nbsp;            return const InboundTextResult(content: null, shouldAck: false);

&nbsp;          }

&nbsp;          if (cryptoHeader.mode == CryptoMode.sealedV1) {

\-            final sealedSenderId = declaredSenderId;

\+            final sealedSenderId =

\+                resolvedSenderForDecrypt ??

\+                senderPublicKey ??

\+                resolvedOriginalSenderForDecrypt ??

\+                originalSender;

&nbsp;            final sealedRecipientId = protocolMessage.recipientId;

&nbsp;            if (sealedSenderId == null ||

&nbsp;                sealedSenderId.isEmpty ||

&nbsp;                sealedRecipientId == null ||

&nbsp;                sealedRecipientId.isEmpty) {

&nbsp;              \_logger.severe(

&nbsp;                '🔒 v2 sealed message missing sender/recipient binding: $messageId',

&nbsp;              );

&nbsp;              return const InboundTextResult(content: null, shouldAck: false);

&nbsp;            }

&nbsp;            decryptedContent = await \_securityService.decryptSealedMessage(

&nbsp;              encryptedMessage: content,

&nbsp;              cryptoHeader: cryptoHeader,

&nbsp;              messageId: messageId,

&nbsp;              senderId: sealedSenderId,

&nbsp;              recipientId: sealedRecipientId,

&nbsp;            );

&nbsp;            \_logger.info(

&nbsp;              '🔒 MESSAGE: Decrypted successfully (mode=${cryptoHeader.mode.wireValue})',

&nbsp;            );

&nbsp;          } else {

&nbsp;            if (cryptoHeader.mode == CryptoMode.legacyGlobalV1) {

&nbsp;              \_logger.warning(

&nbsp;                '🔒 v2 legacy global decrypt mode is blocked by policy: '

&nbsp;                '${cryptoHeader.mode.wireValue} '

@@ -358,54 +362,54 @@ class InboundTextProcessor {

&nbsp;          if (protocolMessage.version >= 2) {

&nbsp;            \_logger.severe(

&nbsp;              '❌ v2 ephemeral signature missing signing key for message $messageId',

&nbsp;            );

&nbsp;            return const InboundTextResult(

&nbsp;              content: '\[❌ UNTRUSTED MESSAGE - Missing ephemeral signing key]',

&nbsp;              shouldAck: false,

&nbsp;            );

&nbsp;          }

&nbsp;          \_logger.warning(

&nbsp;            '⚠️ Ephemeral message missing signing key - accepting unsigned (legacy v1)',

&nbsp;          );

&nbsp;          return InboundTextResult(

&nbsp;            content: decryptedContent,

&nbsp;            shouldAck: true,

&nbsp;            resolvedSenderKey:

&nbsp;                decryptKeyUsed ??

&nbsp;                resolvedDeclaredSenderForDecrypt ??

&nbsp;                resolvedSenderForDecrypt ??

&nbsp;                resolvedOriginalSenderForDecrypt,

&nbsp;          );

&nbsp;        }

&nbsp;        verifyingKey = protocolMessage.ephemeralSigningKey!;

&nbsp;      } else {

&nbsp;        final resolvedForSignature =

\-            resolvedDeclaredSenderForSignature ??

&nbsp;            resolvedSenderForSignature ??

&nbsp;            senderPublicKey ??

\-            resolvedOriginalSenderForSignature;

\+            resolvedOriginalSenderForSignature ??

\+            resolvedDeclaredSenderForSignature;

&nbsp;        if (resolvedForSignature == null) {

&nbsp;          \_logger.severe('❌ Trusted message but no sender identity');

&nbsp;          return const InboundTextResult(

&nbsp;            content: '\[❌ Missing sender identity]',

&nbsp;            shouldAck: false,

&nbsp;          );

&nbsp;        }

&nbsp;        verifyingKey = resolvedForSignature;

&nbsp;      }

&nbsp;

&nbsp;      final signaturePayload = SigningManager.signaturePayloadForMessage(

&nbsp;        protocolMessage,

&nbsp;        fallbackContent: decryptedContent,

&nbsp;      );

&nbsp;      final isValid = SigningManager.verifySignature(

&nbsp;        signaturePayload,

&nbsp;        protocolMessage.signature!,

&nbsp;        verifyingKey,

&nbsp;        protocolMessage.useEphemeralSigning,

&nbsp;      );

&nbsp;

&nbsp;      if (!isValid) {

&nbsp;        \_logger.severe('❌ SIGNATURE VERIFICATION FAILED');

&nbsp;        return const InboundTextResult(

&nbsp;          content: '\[❌ UNTRUSTED MESSAGE - Signature Invalid]',

@@ -420,56 +424,56 @@ class InboundTextProcessor {

&nbsp;      }

&nbsp;      if (protocolMessage.version >= 2) {

&nbsp;        isV2Authenticated = true;

&nbsp;      }

&nbsp;    }

&nbsp;

&nbsp;    if (protocolMessage.version < 2 || isV2Authenticated) {

&nbsp;      \_trackPeerVersionFloor(

&nbsp;        peerKey: versionPeerKey,

&nbsp;        messageVersion: protocolMessage.version,

&nbsp;        messageId: messageId,

&nbsp;      );

&nbsp;    } else {

&nbsp;      \_logger.warning(

&nbsp;        '🔒 Skipping protocol-floor upgrade for unauthenticated '

&nbsp;        'v${protocolMessage.version} message from ${\_safeTruncate(versionPeerKey)} '

&nbsp;        '(messageId=${\_safeTruncate(messageId)})',

&nbsp;      );

&nbsp;    }

&nbsp;

&nbsp;    return InboundTextResult(

&nbsp;      content: decryptedContent,

&nbsp;      shouldAck: true,

&nbsp;      resolvedSenderKey:

&nbsp;          decryptKeyUsed ??

\-          resolvedDeclaredSenderForDecrypt ??

&nbsp;          resolvedSenderForDecrypt ??

&nbsp;          resolvedOriginalSenderForDecrypt ??

\+          resolvedDeclaredSenderForDecrypt ??

&nbsp;          senderPublicKey ??

\-          declaredSenderId ??

\-          originalSender,

\+          originalSender ??

\+          declaredSenderId,

&nbsp;    );

&nbsp;  }

&nbsp;

&nbsp;  String \_versionPeerKey({

&nbsp;    required String? signatureSenderKey,

&nbsp;    required String? declaredSenderId,

&nbsp;    required String? transportSenderId,

&nbsp;  }) {

&nbsp;    if (signatureSenderKey != null \&\& signatureSenderKey.isNotEmpty) {

&nbsp;      return signatureSenderKey;

&nbsp;    }

&nbsp;    if (declaredSenderId != null \&\& declaredSenderId.isNotEmpty) {

&nbsp;      return declaredSenderId;

&nbsp;    }

&nbsp;    return transportSenderId ?? '';

&nbsp;  }

&nbsp;

&nbsp;  bool \_shouldRejectLegacyDowngrade({

&nbsp;    required int messageVersion,

&nbsp;    required String peerKey,

&nbsp;    required String messageId,

&nbsp;  }) {

&nbsp;    final shouldReject = PeerProtocolVersionGuard.shouldRejectLegacyMessage(

&nbsp;      messageVersion: messageVersion,

&nbsp;      peerKey: peerKey,





diff --git a/lib/data/services/protocol\_message\_handler.dart b/lib/data/services/protocol\_message\_handler.dart

index aa8cafb9b7ac2df4c5f04497d1defd2cdc247762..7db9325e1e8ef27b7aaff87f11536c9679092cd8 100644

--- a/lib/data/services/protocol\_message\_handler.dart

+++ b/lib/data/services/protocol\_message\_handler.dart

@@ -204,65 +204,72 @@ class ProtocolMessageHandler implements IProtocolMessageHandler {

&nbsp;

&nbsp;      case ProtocolMessageType.ping:

&nbsp;        \_logger.fine('📍 Received protocol ping');

&nbsp;        return null;

&nbsp;

&nbsp;      case ProtocolMessageType.relayAck:

&nbsp;        // Handled by relay coordinator

&nbsp;        return null;

&nbsp;

&nbsp;      default:

&nbsp;        \_logger.warning('Unknown protocol message type: ${message.type}');

&nbsp;        return null;

&nbsp;    }

&nbsp;  }

&nbsp;

&nbsp;  /// Handles text message reception with decryption and signature verification

&nbsp;  Future<String?> \_handleTextMessage(

&nbsp;    domain\_models.ProtocolMessage message,

&nbsp;    String fromNodeId,

&nbsp;    String? transportMessageId,

&nbsp;  ) async {

&nbsp;    try {

&nbsp;      final messageId = message.textMessageId!;

&nbsp;      final content = message.textContent!;

&nbsp;      final intendedRecipient = message.payload\['intendedRecipient'] as String?;

\-      final declaredSenderId =

\-          message.senderId ??

\-          (message.payload\['originalSender'] as String?) ??

\-          fromNodeId;

\-      final resolvedDecryptSenderId = await \_resolveSenderKeyForDecrypt(

\-        declaredSenderId,

\+      final originalSenderId = message.payload\['originalSender'] as String?;

\+      final declaredSenderId = message.senderId ?? originalSenderId;

\+      final resolvedTransportSenderForDecrypt = await \_resolveSenderKeyForDecrypt(

\+        fromNodeId,

&nbsp;      );

\-      final resolvedSignatureSenderKey = await \_resolveSenderKeyForSignature(

\-        declaredSenderId,

\+      final resolvedOriginalSenderForDecrypt = await \_resolveSenderKeyForDecrypt(

\+        originalSenderId,

&nbsp;      );

\-      final decryptionPeerId = (resolvedDecryptSenderId?.isNotEmpty ?? false)

\-          ? resolvedDecryptSenderId!

\-          : fromNodeId;

\+      final resolvedTransportSenderForSignature =

\+          await \_resolveSenderKeyForSignature(fromNodeId);

\+      final resolvedOriginalSenderForSignature =

\+          await \_resolveSenderKeyForSignature(originalSenderId);

\+      final resolvedDeclaredSenderForSignature =

\+          await \_resolveSenderKeyForSignature(declaredSenderId);

\+      final decryptionPeerId =

\+          (resolvedTransportSenderForDecrypt?.isNotEmpty ?? false)

\+          ? resolvedTransportSenderForDecrypt!

\+          : ((resolvedOriginalSenderForDecrypt?.isNotEmpty ?? false)

\+                ? resolvedOriginalSenderForDecrypt!

\+                : fromNodeId);

&nbsp;      final versionPeerKey = \_versionPeerKey(

\-        signatureSenderKey: resolvedSignatureSenderKey,

\+        signatureSenderKey: resolvedTransportSenderForSignature,

&nbsp;        declaredSenderId: declaredSenderId,

&nbsp;        transportSenderId: fromNodeId,

&nbsp;      );

&nbsp;      if (\_shouldRejectLegacyDowngrade(

&nbsp;        messageVersion: message.version,

&nbsp;        peerKey: versionPeerKey,

&nbsp;        messageId: messageId,

&nbsp;      )) {

&nbsp;        return null;

&nbsp;      }

&nbsp;

&nbsp;      // Check if message is for us

&nbsp;      final isForMe = await isMessageForMe(intendedRecipient);

&nbsp;      if (!isForMe) {

&nbsp;        \_logger.fine('💬 Message not for us, ignoring');

&nbsp;        return null;

&nbsp;      }

&nbsp;

&nbsp;      if (message.version >= 2 \&\& !message.isEncrypted) {

&nbsp;        final isBroadcast = \_isBroadcastV2TextMessage(

&nbsp;          recipientId: message.recipientId,

&nbsp;          intendedRecipient: intendedRecipient,

&nbsp;        );

&nbsp;        if (!isBroadcast) {

&nbsp;          \_logger.severe(

@@ -281,54 +288,54 @@ class ProtocolMessageHandler implements IProtocolMessageHandler {

&nbsp;      // Decrypt if needed

&nbsp;      String decryptedContent = content;

&nbsp;      var isV2Authenticated = message.version < 2;

&nbsp;      if (message.isEncrypted \&\& decryptionPeerId.isNotEmpty) {

&nbsp;        if (\_shouldRequireV2Signature(

&nbsp;              messageVersion: message.version,

&nbsp;              peerKey: versionPeerKey,

&nbsp;            ) \&\&

&nbsp;            message.signature == null) {

&nbsp;          \_logger.severe(

&nbsp;            '🔒 v2 encrypted message missing signature under strict/upgraded-peer policy: $messageId',

&nbsp;          );

&nbsp;          return null;

&nbsp;        }

&nbsp;        try {

&nbsp;          if (message.version >= 2) {

&nbsp;            final cryptoHeader = message.cryptoHeader;

&nbsp;            if (cryptoHeader == null) {

&nbsp;              \_logger.severe(

&nbsp;                '🔒 v2 encrypted message missing crypto header: $messageId',

&nbsp;              );

&nbsp;              return null;

&nbsp;            }

&nbsp;            if (cryptoHeader.mode == CryptoMode.sealedV1) {

&nbsp;              final sealedSenderId =

\-                  message.senderId ??

\-                  (message.payload\['originalSender'] as String?);

\+                  resolvedTransportSenderForDecrypt ??

\+                  fromNodeId;

&nbsp;              final recipientForSealed = message.recipientId;

\-              if (sealedSenderId == null || sealedSenderId.isEmpty) {

\+              if (sealedSenderId.isEmpty) {

&nbsp;                \_logger.severe(

&nbsp;                  '🔒 v2 sealed message missing sender binding: $messageId',

&nbsp;                );

&nbsp;                return null;

&nbsp;              }

&nbsp;              if (recipientForSealed == null || recipientForSealed.isEmpty) {

&nbsp;                \_logger.severe(

&nbsp;                  '🔒 v2 sealed message missing recipient binding: $messageId',

&nbsp;                );

&nbsp;                return null;

&nbsp;              }

&nbsp;              decryptedContent = await \_securityService.decryptSealedMessage(

&nbsp;                encryptedMessage: content,

&nbsp;                cryptoHeader: cryptoHeader,

&nbsp;                messageId: messageId,

&nbsp;                senderId: sealedSenderId,

&nbsp;                recipientId: recipientForSealed,

&nbsp;              );

&nbsp;            } else {

&nbsp;              if (cryptoHeader.mode == CryptoMode.legacyGlobalV1) {

&nbsp;                \_logger.warning(

&nbsp;                  '🔒 v2 legacy global decrypt mode is blocked by policy: '

&nbsp;                  '${cryptoHeader.mode.wireValue} '

&nbsp;                  '(messageId=${messageId.shortId(8)})',

&nbsp;                );

@@ -379,51 +386,55 @@ class ProtocolMessageHandler implements IProtocolMessageHandler {

&nbsp;        } catch (e) {

&nbsp;          \_logger.warning(

&nbsp;            '🔒 Decryption failed for ${decryptionPeerId.shortId(8)} (v${message.version}): $e',

&nbsp;          );

&nbsp;          return null;

&nbsp;        }

&nbsp;      }

&nbsp;

&nbsp;      // Verify signature

&nbsp;      if (message.signature != null) {

&nbsp;        String verifyingKey;

&nbsp;        if (message.useEphemeralSigning) {

&nbsp;          if (message.ephemeralSigningKey == null ||

&nbsp;              message.ephemeralSigningKey!.isEmpty) {

&nbsp;            if (message.version >= 2) {

&nbsp;              \_logger.severe(

&nbsp;                '❌ v2 ephemeral signature missing signing key for message $messageId',

&nbsp;              );

&nbsp;              return '\[❌ UNTRUSTED MESSAGE - Missing ephemeral signing key]';

&nbsp;            }

&nbsp;            verifyingKey = decryptionPeerId;

&nbsp;          } else {

&nbsp;            verifyingKey = message.ephemeralSigningKey!;

&nbsp;          }

&nbsp;        } else {

\-          final signatureKey = resolvedSignatureSenderKey ?? declaredSenderId;

\+          final signatureKey =

\+              resolvedTransportSenderForSignature ??

\+              resolvedOriginalSenderForSignature ??

\+              resolvedDeclaredSenderForSignature ??

\+              fromNodeId;

&nbsp;          if (signatureKey.isEmpty) {

&nbsp;            \_logger.severe(

&nbsp;              '❌ v2 trusted signature missing sender verification key for message $messageId',

&nbsp;            );

&nbsp;            return '\[❌ UNTRUSTED MESSAGE - Missing sender identity]';

&nbsp;          }

&nbsp;          verifyingKey = signatureKey;

&nbsp;        }

&nbsp;

&nbsp;        final signaturePayload = SigningManager.signaturePayloadForMessage(

&nbsp;          message,

&nbsp;          fallbackContent: decryptedContent,

&nbsp;        );

&nbsp;        final isValid = SigningManager.verifySignature(

&nbsp;          signaturePayload,

&nbsp;          message.signature!,

&nbsp;          verifyingKey,

&nbsp;          message.useEphemeralSigning,

&nbsp;        );

&nbsp;

&nbsp;        if (!isValid) {

&nbsp;          \_logger.severe('❌ Signature verification failed');

&nbsp;          return '\[❌ UNTRUSTED MESSAGE - Invalid signature]';

&nbsp;        }

&nbsp;





diff --git a/test/data/services/inbound\_text\_processor\_test.dart b/test/data/services/inbound\_text\_processor\_test.dart

index be74dbea70ad0269b8f80c45ce1b2cdbfaf3215e..2a71568d0a142494c1db87529ccfa76a3530630b 100644

--- a/test/data/services/inbound\_text\_processor\_test.dart

+++ b/test/data/services/inbound\_text\_processor\_test.dart

@@ -12,109 +12,109 @@ import 'package:pak\_connect/domain/interfaces/i\_security\_service.dart';

&nbsp;import 'package:pak\_connect/domain/models/crypto\_header.dart';

&nbsp;import 'package:pak\_connect/domain/models/encryption\_method.dart';

&nbsp;import 'package:pak\_connect/domain/models/protocol\_message.dart';

&nbsp;import 'package:pak\_connect/domain/models/security\_level.dart';

&nbsp;import 'package:pak\_connect/domain/services/signing\_manager.dart';

&nbsp;

&nbsp;void main() {

&nbsp;  group('InboundTextProcessor', () {

&nbsp;    late \_FakeSecurityService securityService;

&nbsp;    late \_FakeContactRepository contactRepository;

&nbsp;    late InboundTextProcessor processor;

&nbsp;

&nbsp;    setUp(() {

&nbsp;      InboundTextProcessor.clearPeerProtocolVersionFloorForTest();

&nbsp;      securityService = \_FakeSecurityService();

&nbsp;      contactRepository = \_FakeContactRepository();

&nbsp;      processor = InboundTextProcessor(

&nbsp;        contactRepository: contactRepository,

&nbsp;        isMessageForMe: (\_) async => true,

&nbsp;        currentNodeIdProvider: () => 'local-node',

&nbsp;        securityService: securityService,

&nbsp;      );

&nbsp;    });

&nbsp;

&nbsp;    test(

\-      'uses declared sender identity for v2 decrypt when transport sender is relay',

\+      'uses transport sender identity for v2 decrypt when senderId differs',

&nbsp;      () async {

&nbsp;        final message = ProtocolMessage(

&nbsp;          type: ProtocolMessageType.textMessage,

&nbsp;          version: 2,

&nbsp;          payload: {

&nbsp;            'messageId': 'msg-v2-relay-decrypt',

&nbsp;            'content': 'ciphertext',

&nbsp;            'encrypted': true,

&nbsp;            'senderId': 'crypto-sender',

&nbsp;            'crypto': {'mode': 'noise\_v1', 'modeVersion': 1},

&nbsp;          },

&nbsp;          timestamp: DateTime.now(),

&nbsp;        );

&nbsp;

&nbsp;        final result = await processor.process(

&nbsp;          protocolMessage: message,

&nbsp;          senderPublicKey: 'relay-node',

&nbsp;        );

&nbsp;

&nbsp;        expect(result.content, equals('typed:ciphertext'));

&nbsp;        expect(result.shouldAck, isTrue);

&nbsp;        expect(securityService.decryptMessageByTypeCalls, equals(1));

\-        expect(securityService.lastDecryptPublicKey, equals('crypto-sender'));

\+        expect(securityService.lastDecryptPublicKey, equals('relay-node'));

&nbsp;      },

&nbsp;    );

&nbsp;

&nbsp;    test(

\-      'uses sealed sender and recipient bindings from envelope over transport sender',

\+      'uses transport sender binding for sealed v2 decrypt attribution',

&nbsp;      () async {

&nbsp;        final message = ProtocolMessage(

&nbsp;          type: ProtocolMessageType.textMessage,

&nbsp;          version: 2,

&nbsp;          payload: {

&nbsp;            'messageId': 'msg-v2-sealed-relay',

&nbsp;            'content': 'ciphertext-base64',

&nbsp;            'encrypted': true,

&nbsp;            'senderId': 'crypto-sender',

&nbsp;            'recipientId': 'recipient-key',

&nbsp;            'crypto': {

&nbsp;              'mode': 'sealed\_v1',

&nbsp;              'modeVersion': 1,

&nbsp;              'kid': 'kid-1',

&nbsp;              'epk': 'ZWJjZGVmZw==',

&nbsp;              'nonce': 'bm9uY2UxMjM=',

&nbsp;            },

&nbsp;          },

&nbsp;          timestamp: DateTime.now(),

&nbsp;        );

&nbsp;

&nbsp;        final result = await processor.process(

&nbsp;          protocolMessage: message,

&nbsp;          senderPublicKey: 'relay-node',

&nbsp;        );

&nbsp;

&nbsp;        expect(result.content, equals('sealed:ciphertext-base64'));

&nbsp;        expect(result.shouldAck, isTrue);

&nbsp;        expect(securityService.decryptSealedCalls, equals(1));

\-        expect(securityService.lastSealedSenderId, equals('crypto-sender'));

\+        expect(securityService.lastSealedSenderId, equals('relay-node'));

&nbsp;        expect(securityService.lastSealedRecipientId, equals('recipient-key'));

&nbsp;      },

&nbsp;    );

&nbsp;

&nbsp;    test('rejects sealed v2 payload missing sender binding', () async {

&nbsp;      final message = ProtocolMessage(

&nbsp;        type: ProtocolMessageType.textMessage,

&nbsp;        version: 2,

&nbsp;        payload: {

&nbsp;          'messageId': 'msg-v2-sealed-missing-sender',

&nbsp;          'content': 'ciphertext-base64',

&nbsp;          'encrypted': true,

&nbsp;          'recipientId': 'recipient-key',

&nbsp;          'crypto': {

&nbsp;            'mode': 'sealed\_v1',

&nbsp;            'modeVersion': 1,

&nbsp;            'kid': 'kid-1',

&nbsp;            'epk': 'ZWJjZGVmZw==',

&nbsp;            'nonce': 'bm9uY2UxMjM=',

&nbsp;          },

&nbsp;        },

&nbsp;        timestamp: DateTime.now(),

&nbsp;      );

&nbsp;

&nbsp;      final result = await processor.process(





diff --git a/test/data/services/protocol\_message\_handler\_test.dart b/test/data/services/protocol\_message\_handler\_test.dart

index 96c6ccfb8cf0fdd823ab716d73a82acd1ee1d09c..37f8f9ef57df69497f7f0663290b235d87e62f31 100644

--- a/test/data/services/protocol\_message\_handler\_test.dart

+++ b/test/data/services/protocol\_message\_handler\_test.dart

@@ -371,110 +371,110 @@ void main() {

&nbsp;      allowedSevere.add('v2 plaintext broadcast missing signature');

&nbsp;      final message = ProtocolMessage(

&nbsp;        type: ProtocolMessageType.textMessage,

&nbsp;        version: 2,

&nbsp;        payload: {

&nbsp;          'messageId': 'msg-v2-broadcast-plaintext',

&nbsp;          'content': 'spoof-broadcast',

&nbsp;          'encrypted': false,

&nbsp;          'senderId': 'sender-key',

&nbsp;        },

&nbsp;        timestamp: DateTime.now(),

&nbsp;      );

&nbsp;

&nbsp;      final result = await handler.processProtocolMessage(

&nbsp;        message: message,

&nbsp;        fromDeviceId: 'device-1',

&nbsp;        fromNodeId: 'relay-node',

&nbsp;      );

&nbsp;

&nbsp;      expect(result, isNull);

&nbsp;      expect(securityService.decryptMessageByTypeCalls, equals(0));

&nbsp;      expect(securityService.decryptMessageCalls, equals(0));

&nbsp;    });

&nbsp;

&nbsp;    test(

\-      'routes v2 decrypt by declared mode without fallback guessing',

\+      'routes v2 decrypt by declared mode using transport sender identity',

&nbsp;      () async {

&nbsp;        final message = ProtocolMessage(

&nbsp;          type: ProtocolMessageType.textMessage,

&nbsp;          version: 2,

&nbsp;          payload: {

&nbsp;            'messageId': 'msg-v2-mode',

&nbsp;            'content': 'ciphertext',

&nbsp;            'encrypted': true,

&nbsp;            'senderId': 'sender-key',

&nbsp;            'crypto': {'mode': 'noise\_v1', 'modeVersion': 1},

&nbsp;          },

&nbsp;          timestamp: DateTime.now(),

&nbsp;        );

&nbsp;

&nbsp;        final result = await handler.processProtocolMessage(

&nbsp;          message: message,

&nbsp;          fromDeviceId: 'device-1',

&nbsp;          fromNodeId: 'relay-node',

&nbsp;        );

&nbsp;

&nbsp;        expect(result, equals('typed:ciphertext'));

&nbsp;        expect(securityService.decryptMessageByTypeCalls, equals(1));

&nbsp;        expect(securityService.decryptMessageCalls, equals(0));

&nbsp;        expect(securityService.lastDecryptType, equals(EncryptionType.noise));

\-        expect(securityService.lastDecryptPublicKey, equals('sender-key'));

\+        expect(securityService.lastDecryptPublicKey, equals('relay-node'));

&nbsp;      },

&nbsp;    );

&nbsp;

&nbsp;    test('routes v2 sealed decrypt via dedicated sealed path', () async {

&nbsp;      final message = ProtocolMessage(

&nbsp;        type: ProtocolMessageType.textMessage,

&nbsp;        version: 2,

&nbsp;        payload: {

&nbsp;          'messageId': 'msg-v2-sealed',

&nbsp;          'content': 'ciphertext-base64',

&nbsp;          'encrypted': true,

&nbsp;          'senderId': 'sender-key',

&nbsp;          'recipientId': 'recipient-key',

&nbsp;          'crypto': {

&nbsp;            'mode': 'sealed\_v1',

&nbsp;            'modeVersion': 1,

&nbsp;            'kid': 'kid-1',

&nbsp;            'epk': 'ZWJjZGVmZw==',

&nbsp;            'nonce': 'bm9uY2UxMjM=',

&nbsp;          },

&nbsp;        },

&nbsp;        timestamp: DateTime.now(),

&nbsp;      );

&nbsp;

&nbsp;      final result = await handler.processProtocolMessage(

&nbsp;        message: message,

&nbsp;        fromDeviceId: 'device-1',

&nbsp;        fromNodeId: 'relay-node',

&nbsp;      );

&nbsp;

&nbsp;      expect(result, equals('sealed:ciphertext-base64'));

&nbsp;      expect(securityService.decryptSealedCalls, equals(1));

&nbsp;      expect(securityService.decryptMessageByTypeCalls, equals(0));

\-      expect(securityService.lastSealedSenderId, equals('sender-key'));

\+      expect(securityService.lastSealedSenderId, equals('relay-node'));

&nbsp;      expect(securityService.lastSealedRecipientId, equals('recipient-key'));

&nbsp;    });

&nbsp;

&nbsp;    test('rejects v2 sealed message missing sender binding', () async {

&nbsp;      allowedSevere.add('v2 sealed message missing sender binding');

&nbsp;      final message = ProtocolMessage(

&nbsp;        type: ProtocolMessageType.textMessage,

&nbsp;        version: 2,

&nbsp;        payload: {

&nbsp;          'messageId': 'msg-v2-sealed-missing-sender',

&nbsp;          'content': 'ciphertext-base64',

&nbsp;          'encrypted': true,

&nbsp;          'recipientId': 'recipient-key',

&nbsp;          'crypto': {

&nbsp;            'mode': 'sealed\_v1',

&nbsp;            'modeVersion': 1,

&nbsp;            'kid': 'kid-1',

&nbsp;            'epk': 'ZWJjZGVmZw==',

&nbsp;            'nonce': 'bm9uY2UxMjM=',

&nbsp;          },

&nbsp;        },

&nbsp;        timestamp: DateTime.now(),

&nbsp;      );

&nbsp;

&nbsp;      final result = await handler.processProtocolMessage(



Attack-path analysis:

Final: medium | Decider: model\_decided | Matrix severity: low | Policy adjusted: low

Rationale: Impact is integrity/identity spoofing in a local BLE threat model without confidentiality breach or code execution; attack is plausible but adjacency-limited, so medium remains appropriate.

Likelihood: medium - Adjacent BLE attacker can craft payloads; requires proximity and knowledge of a victim identifier but no authentication. Practical for local adversaries.

Impact: medium - Allows impersonation of another contact within the app, undermining message integrity and trust. Does not directly expose confidentiality or execute code.

Assumptions:

\- An attacker can send crafted ProtocolMessage payloads over BLE within range of a target device.

\- Targets accept v2 messages that are unencrypted or unsigned in low/legacy security modes.

\- Attacker knows or can guess a victim contact identifier used by the app (persistent or ephemeral) to place in senderId.

\- BLE proximity to target device

\- Crafted ProtocolMessage with senderId set to victim

\- Signature absent or ephemeral (no binding to sender identity)

Path:

BLE attacker -> payload.senderId -> InboundTextProcessor (declared sender) -> ProtocolMessageHandler (decryptionPeerId) -> UI attribution

Narrative:

Outbound v2 messages include a senderId field in the payload, and inbound processing prioritizes protocolMessage.senderId for decrypt-key selection and resolved sender attribution. Signature verification is only performed when a signature is present, and signatures are computed over message content only. As a result, a BLE-adjacent attacker can craft an unencrypted/unsigned (or ephemeral-signed) v2 message with senderId set to a victim contact, causing the target to attribute the message to that contact and route callbacks/UI accordingly.

Evidence:

\- \[object Object]

\- \[object Object]

\- \[object Object]

\- \[object Object]

\- \[object Object]

\- \[object Object]

\- \[object Object]

Controls:

\- Intended recipient filtering (\_isMessageForMe)

\- Signature verification when present

\- Crypto header checks for v2 encrypted messages

Blindspots:

\- Static review only; no runtime testing of enforcement flags or production configuration that might require signatures.

\- No evidence of additional transport-layer identity checks outside the reviewed files.

