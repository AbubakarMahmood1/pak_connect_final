Sealed v1 decrypt accepts unsigned messages (spoofing risk) - 2683eb4934848191bd4ba305b29fa947

Link: https://chatgpt.com/codex/security/findings/2683eb4934848191bd4ba305b29fa947?sev=critical%2Chigh%2Cmedium%2Clow

Criticality: medium (attack path: medium)

Status: new



Summary:

This commit introduces an authentication/integrity gap for sealed\_v1: inbound logic now decrypts sealed messages even when no sender key is available and does not require a signature, allowing unauthenticated message injection/spoofing.

The commit wires sealed\_v1 decryption into inbound handlers and explicitly bypasses the “sender key required” check for sealed messages. The sealed decrypt path then uses senderId/recipientId directly from the untrusted payload to build AAD, and signature verification only occurs if a signature is present. As a result, an attacker who knows the recipient’s static public key (which is typically shareable) can craft a sealed\_v1 ciphertext and set an arbitrary senderId while omitting a signature, causing the app to accept and display a forged message as coming from a victim contact. This breaks peer authentication and message integrity for sealed\_v1 traffic.



Metadata:

Repo: AbubakarMahmood1/pak\_connect\_final

Commit: 8c0545f

Author: f219462@cfd.nu.edu.pk

Created: 07/03/2026, 15:00:02

Assignee: Unassigned

Signals: Security, Validated, Patch generated, Attack-path



Relevant lines:

/workspace/pak\_connect\_final/lib/data/services/inbound\_text\_processor.dart (L251 to 316)

&nbsp; Note: Signature verification is only performed when a signature is present; unsigned messages (including sealed\_v1) are accepted without authentication.

&nbsp;     // Verify signature when present

&nbsp;     if (protocolMessage.signature != null) {

&nbsp;       String verifyingKey;

&nbsp; 

&nbsp;       if (protocolMessage.useEphemeralSigning) {

&nbsp;         if (protocolMessage.ephemeralSigningKey == null) {

&nbsp;           if (protocolMessage.version >= 2) {

&nbsp;             \_logger.severe(

&nbsp;               '❌ v2 ephemeral signature missing signing key for message $messageId',

&nbsp;             );

&nbsp;             return const InboundTextResult(

&nbsp;               content: '\[❌ UNTRUSTED MESSAGE - Missing ephemeral signing key]',

&nbsp;               shouldAck: false,

&nbsp;             );

&nbsp;           }

&nbsp;           \_logger.warning(

&nbsp;             '⚠️ Ephemeral message missing signing key - accepting unsigned (legacy v1)',

&nbsp;           );

&nbsp;           return InboundTextResult(

&nbsp;             content: decryptedContent,

&nbsp;             shouldAck: true,

&nbsp;             resolvedSenderKey:

&nbsp;                 decryptKeyUsed ??

&nbsp;                 resolvedDeclaredSender ??

&nbsp;                 resolvedSender ??

&nbsp;                 resolvedOriginalSender,

&nbsp;           );

&nbsp;         }

&nbsp;         verifyingKey = protocolMessage.ephemeralSigningKey!;

&nbsp;       } else {

&nbsp;         final resolvedForSignature =

&nbsp;             resolvedDeclaredSender ??

&nbsp;             resolvedSender ??

&nbsp;             senderPublicKey ??

&nbsp;             resolvedOriginalSender;

&nbsp;         if (resolvedForSignature == null) {

&nbsp;           \_logger.severe('❌ Trusted message but no sender identity');

&nbsp;           return const InboundTextResult(

&nbsp;             content: '\[❌ Missing sender identity]',

&nbsp;             shouldAck: false,

&nbsp;           );

&nbsp;         }

&nbsp;         verifyingKey = resolvedForSignature;

&nbsp;       }

&nbsp; 

&nbsp;       final isValid = SigningManager.verifySignature(

&nbsp;         decryptedContent,

&nbsp;         protocolMessage.signature!,

&nbsp;         verifyingKey,

&nbsp;         protocolMessage.useEphemeralSigning,

&nbsp;       );

&nbsp; 

&nbsp;       if (!isValid) {

&nbsp;         \_logger.severe('❌ SIGNATURE VERIFICATION FAILED');

&nbsp;         return const InboundTextResult(

&nbsp;           content: '\[❌ UNTRUSTED MESSAGE - Signature Invalid]',

&nbsp;           shouldAck: false,

&nbsp;         );

&nbsp;       }

&nbsp; 

&nbsp;       if (protocolMessage.useEphemeralSigning) {

&nbsp;         \_logger.info('✅ Ephemeral signature verified');

&nbsp;       } else {

&nbsp;         \_logger.info('✅ Real signature verified');

&nbsp;       }

&nbsp;     }



/workspace/pak\_connect\_final/lib/data/services/inbound\_text\_processor.dart (L96 to 135)

&nbsp; Note: Sealed\_v1 messages bypass the sender-key requirement and are decrypted using sender/recipient IDs from the untrusted payload, enabling unauthenticated sealed message acceptance.

&nbsp;     if (protocolMessage.isEncrypted) {

&nbsp;       final cryptoHeader =

&nbsp;           protocolMessage.version >= 2 ? protocolMessage.cryptoHeader : null;

&nbsp;       final isSealedV2 = cryptoHeader?.mode == CryptoMode.sealedV1;

&nbsp; 

&nbsp;       if (decryptKey == null \&\& !isSealedV2) {

&nbsp;         \_logger.warning('🔒 MESSAGE: Encrypted but no sender key available');

&nbsp;         return const InboundTextResult(

&nbsp;           content: '\[❌ Encrypted message but no sender identity]',

&nbsp;           shouldAck: false,

&nbsp;         );

&nbsp;       }

&nbsp; 

&nbsp;       try {

&nbsp;         if (protocolMessage.version >= 2) {

&nbsp;           if (cryptoHeader == null) {

&nbsp;             \_logger.severe(

&nbsp;               '🔒 v2 encrypted message missing crypto header: $messageId',

&nbsp;             );

&nbsp;             return const InboundTextResult(content: null, shouldAck: false);

&nbsp;           }

&nbsp;           if (cryptoHeader.mode == CryptoMode.sealedV1) {

&nbsp;             final sealedSenderId = declaredSenderId ?? senderPublicKey;

&nbsp;             final sealedRecipientId = protocolMessage.recipientId;

&nbsp;             if (sealedSenderId == null ||

&nbsp;                 sealedSenderId.isEmpty ||

&nbsp;                 sealedRecipientId == null ||

&nbsp;                 sealedRecipientId.isEmpty) {

&nbsp;               \_logger.severe(

&nbsp;                 '🔒 v2 sealed message missing sender/recipient binding: $messageId',

&nbsp;               );

&nbsp;               return const InboundTextResult(content: null, shouldAck: false);

&nbsp;             }

&nbsp;             decryptedContent = await \_securityService.decryptSealedMessage(

&nbsp;               encryptedMessage: content,

&nbsp;               cryptoHeader: cryptoHeader,

&nbsp;               messageId: messageId,

&nbsp;               senderId: sealedSenderId,

&nbsp;               recipientId: sealedRecipientId,

&nbsp;             );



/workspace/pak\_connect\_final/lib/data/services/protocol\_message\_handler.dart (L223 to 249)

&nbsp; Note: Protocol handler routes sealed\_v1 messages directly to decryptSealedMessage using declaredSenderId/recipientId without enforcing sender authentication.

&nbsp;       // Decrypt if needed

&nbsp;       String decryptedContent = content;

&nbsp;       if (message.isEncrypted \&\& decryptionPeerId.isNotEmpty) {

&nbsp;         try {

&nbsp;           if (message.version >= 2) {

&nbsp;             final cryptoHeader = message.cryptoHeader;

&nbsp;             if (cryptoHeader == null) {

&nbsp;               \_logger.severe(

&nbsp;                 '🔒 v2 encrypted message missing crypto header: $messageId',

&nbsp;               );

&nbsp;               return null;

&nbsp;             }

&nbsp;             if (cryptoHeader.mode == CryptoMode.sealedV1) {

&nbsp;               final recipientForSealed = message.recipientId ?? intendedRecipient;

&nbsp;               if (recipientForSealed == null || recipientForSealed.isEmpty) {

&nbsp;                 \_logger.severe(

&nbsp;                   '🔒 v2 sealed message missing recipient binding: $messageId',

&nbsp;                 );

&nbsp;                 return null;

&nbsp;               }

&nbsp;               decryptedContent = await \_securityService.decryptSealedMessage(

&nbsp;                 encryptedMessage: content,

&nbsp;                 cryptoHeader: cryptoHeader,

&nbsp;                 messageId: messageId,

&nbsp;                 senderId: declaredSenderId,

&nbsp;                 recipientId: recipientForSealed,

&nbsp;               );





Validation:

Rubric:

\- \[x] Identify sealed\_v1 sender-key bypass in inbound\_text\_processor (lines 96-135)

\- \[x] Confirm sealed\_v1 AAD uses sender/recipient IDs from payload (protocol\_message.dart 464-484; security\_manager.dart 503-549, 906-912)

\- \[x] Verify signature checks are conditional and unsigned messages accepted (inbound\_text\_processor.dart 251-316)

\- \[x] Confirm alternate handler path decrypts sealed\_v1 without sender auth (protocol\_message\_handler.dart 223-249)

\- \[ ] Produce dynamic PoC via runtime/valgrind/debugger (blocked: missing dart/flutter/gdb/valgrind)

Report:

Attempted dynamic validation first: `dart --version` and `flutter --version` both returned “command not found”; `valgrind --version` and `gdb --version` also returned “command not found”, so crash/valgrind/debugger reproduction was not possible in this container. Code review shows the suspected auth gap: InboundTextProcessor allows encrypted messages with no sender key when crypto mode is sealed\_v1 (isSealedV2) and proceeds to decrypt (lib/data/services/inbound\_text\_processor.dart:96-135). In the sealed\_v1 branch it uses declaredSenderId/senderPublicKey and protocolMessage.recipientId from the payload (lines 117-135), which are attacker-controlled because ProtocolMessage.senderId/recipientId are direct payload fields (lib/domain/models/protocol\_message.dart:464-484). decryptSealedMessage builds AAD from messageId/senderId/recipientId without any independent authentication (lib/core/services/security\_manager.dart:503-549, 906-912). Signature verification is only performed if a signature is present; otherwise the decrypted content is accepted (lib/data/services/inbound\_text\_processor.dart:251-316). The older protocol\_message\_handler path similarly decrypts sealed\_v1 with declaredSenderId from payload and no sender authentication (lib/data/services/protocol\_message\_handler.dart:223-249). Together these confirm that a sealed\_v1 message can be injected with an arbitrary senderId and no signature, leading to unauthenticated message acceptance.



Proposed patch:

diff --git a/lib/data/services/inbound\_text\_processor.dart b/lib/data/services/inbound\_text\_processor.dart

index 9e66faaf82294547b9b93c0d394059f854c23161..9449d10b438c7c56788b2d5045c93af0a84dab90 100644

--- a/lib/data/services/inbound\_text\_processor.dart

+++ b/lib/data/services/inbound\_text\_processor.dart

@@ -155,50 +155,57 @@ class InboundTextProcessor {

&nbsp;

&nbsp;    final decryptKey = resolvedDeclaredSenderForDecrypt?.isNotEmpty == true

&nbsp;        ? resolvedDeclaredSenderForDecrypt

&nbsp;        : (resolvedSenderForDecrypt?.isNotEmpty == true

&nbsp;              ? resolvedSenderForDecrypt

&nbsp;              : resolvedOriginalSenderForDecrypt);

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

\+      if (isSealedV2 \&\& protocolMessage.signature == null) {

\+        \_logger.severe(

\+          '🔒 v2 sealed message missing signature: $messageId',

\+        );

\+        return const InboundTextResult(content: null, shouldAck: false);

\+      }

\+

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

&nbsp;            final sealedSenderId = declaredSenderId;

&nbsp;            final sealedRecipientId = protocolMessage.recipientId;

&nbsp;            if (sealedSenderId == null ||

&nbsp;                sealedSenderId.isEmpty ||

&nbsp;                sealedRecipientId == null ||

&nbsp;                sealedRecipientId.isEmpty) {

&nbsp;              \_logger.severe(

&nbsp;                '🔒 v2 sealed message missing sender/recipient binding: $messageId',





diff --git a/lib/data/services/protocol\_message\_handler.dart b/lib/data/services/protocol\_message\_handler.dart

index aa8cafb9b7ac2df4c5f04497d1defd2cdc247762..522b96b9d23d14e98bfb720ef21f6a279a89b744 100644

--- a/lib/data/services/protocol\_message\_handler.dart

+++ b/lib/data/services/protocol\_message\_handler.dart

@@ -280,50 +280,56 @@ class ProtocolMessageHandler implements IProtocolMessageHandler {

&nbsp;

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

\+              if (message.signature == null) {

\+                \_logger.severe(

\+                  '🔒 v2 sealed message missing signature: $messageId',

\+                );

\+                return null;

\+              }

&nbsp;              final sealedSenderId =

&nbsp;                  message.senderId ??

&nbsp;                  (message.payload\['originalSender'] as String?);

&nbsp;              final recipientForSealed = message.recipientId;

&nbsp;              if (sealedSenderId == null || sealedSenderId.isEmpty) {

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





diff --git a/test/data/services/inbound\_text\_processor\_test.dart b/test/data/services/inbound\_text\_processor\_test.dart

index be74dbea70ad0269b8f80c45ce1b2cdbfaf3215e..7d594aa116ccc2f09380451ed00738b5afeee22b 100644

--- a/test/data/services/inbound\_text\_processor\_test.dart

+++ b/test/data/services/inbound\_text\_processor\_test.dart

@@ -139,50 +139,82 @@ void main() {

&nbsp;          'encrypted': true,

&nbsp;          'senderId': 'crypto-sender',

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

&nbsp;        protocolMessage: message,

&nbsp;        senderPublicKey: 'relay-node',

&nbsp;      );

&nbsp;

&nbsp;      expect(result.content, isNull);

&nbsp;      expect(result.shouldAck, isFalse);

&nbsp;      expect(securityService.decryptSealedCalls, equals(0));

&nbsp;      expect(securityService.decryptMessageByTypeCalls, equals(0));

&nbsp;      expect(securityService.decryptMessageCalls, equals(0));

&nbsp;    });

&nbsp;

\+

\+    test('rejects unsigned sealed v2 message', () async {

\+      final message = ProtocolMessage(

\+        type: ProtocolMessageType.textMessage,

\+        version: 2,

\+        payload: {

\+          'messageId': 'msg-v2-sealed-unsigned',

\+          'content': 'ciphertext-base64',

\+          'encrypted': true,

\+          'senderId': 'crypto-sender',

\+          'recipientId': 'recipient-key',

\+          'crypto': {

\+            'mode': 'sealed\_v1',

\+            'modeVersion': 1,

\+            'kid': 'kid-1',

\+            'epk': 'ZWJjZGVmZw==',

\+            'nonce': 'bm9uY2UxMjM=',

\+          },

\+        },

\+        timestamp: DateTime.now(),

\+      );

\+

\+      final result = await processor.process(

\+        protocolMessage: message,

\+        senderPublicKey: 'relay-node',

\+      );

\+

\+      expect(result.content, isNull);

\+      expect(result.shouldAck, isFalse);

\+      expect(securityService.decryptSealedCalls, equals(0));

\+    });

\+

&nbsp;    test(

&nbsp;      'requires signature for v2 encrypted message when policy enabled',

&nbsp;      () async {

&nbsp;        final strictProcessor = InboundTextProcessor(

&nbsp;          contactRepository: contactRepository,

&nbsp;          isMessageForMe: (\_) async => true,

&nbsp;          currentNodeIdProvider: () => 'local-node',

&nbsp;          securityService: securityService,

&nbsp;          requireV2Signature: true,

&nbsp;        );

&nbsp;        final message = ProtocolMessage(

&nbsp;          type: ProtocolMessageType.textMessage,

&nbsp;          version: 2,

&nbsp;          payload: {

&nbsp;            'messageId': 'msg-v2-signature-required',

&nbsp;            'content': 'ciphertext',

&nbsp;            'encrypted': true,

&nbsp;            'senderId': 'crypto-sender',

&nbsp;            'crypto': {'mode': 'noise\_v1', 'modeVersion': 1},

&nbsp;          },

&nbsp;          timestamp: DateTime.now(),

&nbsp;        );

&nbsp;

&nbsp;        final result = await strictProcessor.process(

&nbsp;          protocolMessage: message,





diff --git a/test/data/services/protocol\_message\_handler\_test.dart b/test/data/services/protocol\_message\_handler\_test.dart

index 96c6ccfb8cf0fdd823ab716d73a82acd1ee1d09c..b998a944ce9de86d81050e8745cdf0a1c9f1582e 100644

--- a/test/data/services/protocol\_message\_handler\_test.dart

+++ b/test/data/services/protocol\_message\_handler\_test.dart

@@ -505,50 +505,84 @@ void main() {

&nbsp;            'intendedRecipient': 'recipient-key',

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

&nbsp;        final result = await handler.processProtocolMessage(

&nbsp;          message: message,

&nbsp;          fromDeviceId: 'device-1',

&nbsp;          fromNodeId: 'relay-node',

&nbsp;        );

&nbsp;

&nbsp;        expect(result, isNull);

&nbsp;        expect(securityService.decryptSealedCalls, equals(0));

&nbsp;        expect(securityService.decryptMessageByTypeCalls, equals(0));

&nbsp;        expect(securityService.decryptMessageCalls, equals(0));

&nbsp;      },

&nbsp;    );

&nbsp;

\+

\+    test('rejects unsigned sealed v2 message', () async {

\+      final message = ProtocolMessage(

\+        type: ProtocolMessageType.textMessage,

\+        version: 2,

\+        payload: {

\+          'messageId': 'msg-v2-sealed-unsigned',

\+          'content': 'ciphertext-base64',

\+          'encrypted': true,

\+          'senderId': 'sender-key',

\+          'recipientId': 'recipient-key',

\+          'crypto': {

\+            'mode': 'sealed\_v1',

\+            'modeVersion': 1,

\+            'kid': 'kid-1',

\+            'epk': 'ZWJjZGVmZw==',

\+            'nonce': 'bm9uY2UxMjM=',

\+          },

\+        },

\+        timestamp: DateTime.now(),

\+      );

\+

\+      final result = await handler.processProtocolMessage(

\+        message: message,

\+        fromDeviceId: 'device-1',

\+        fromNodeId: 'relay-node',

\+      );

\+

\+      expect(result, isNull);

\+      expect(securityService.decryptSealedCalls, equals(0));

\+      expect(securityService.decryptMessageByTypeCalls, equals(0));

\+      expect(securityService.decryptMessageCalls, equals(0));

\+    });

\+

&nbsp;    test(

&nbsp;      'blocks v2 legacy\_global\_v1 decrypt mode even when compatibility is enabled',

&nbsp;      () async {

&nbsp;        final message = ProtocolMessage(

&nbsp;          type: ProtocolMessageType.textMessage,

&nbsp;          version: 2,

&nbsp;          payload: {

&nbsp;            'messageId': 'msg-v2-legacy-global-blocked',

&nbsp;            'content': 'PLAINTEXT:spoofed-message',

&nbsp;            'encrypted': true,

&nbsp;            'senderId': 'sender-key',

&nbsp;            'crypto': {'mode': 'legacy\_global\_v1', 'modeVersion': 1},

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

&nbsp;        expect(result, isNull);

&nbsp;        expect(securityService.decryptMessageByTypeCalls, equals(0));

&nbsp;        expect(securityService.decryptMessageCalls, equals(0));



Attack-path analysis:

Final: medium | Decider: model\_decided | Matrix severity: low | Policy adjusted: low

Rationale: The issue is real and reachable from the BLE/mesh boundary, but the attacker must be nearby and the impact is limited to message integrity/spoofing rather than data exfiltration or account takeover. This aligns with a medium severity rather than high/critical.

Likelihood: medium - Requires BLE/mesh proximity and knowledge of the recipient’s public key/identifier, but does not require sender authentication or signature, making exploitation plausible.

Impact: medium - An attacker can spoof messages as another contact, breaking peer authentication and message integrity. Confidentiality is not impacted, but trust in message origin is compromised.

Assumptions:

\- Sealed\_v1 decryption is enabled in production and reachable via BLE/mesh inbound messages.

\- Nearby attackers can send ProtocolMessage payloads over BLE/mesh without prior authentication.

\- Recipients’ static public keys or identifiers are obtainable via normal contact exchange or observation, enabling sealed\_v1 ciphertext construction.

\- BLE/mesh proximity to the target device

\- Recipient public key/identifier to build sealed\_v1 ciphertext

\- Ability to send a ProtocolMessage with sealed\_v1 crypto header and no signature

Path:

BLE attacker -> ProtocolMessage(payload senderId/recipientId) -> sealed\_v1 decrypt (no sender key) -> signature optional -> message accepted/ACKed

Narrative:

InboundTextProcessor allows sealed\_v1 messages to decrypt even when no sender key is known, and it uses senderId/recipientId taken directly from the untrusted payload to build AAD. Signature verification only occurs when a signature is present, so an attacker can send a sealed\_v1 ciphertext without a signature and set an arbitrary senderId. BLEMessageHandler routes inbound text messages to this processor and ACKs/displays them, enabling message spoofing from nearby attackers.

Evidence:

\- \[object Object]

\- \[object Object]

\- \[object Object]

\- \[object Object]

\- \[object Object]

Controls:

\- Crypto header mode check gates sealed\_v1 decrypt path.

\- Sealed\_v1 decryption requires recipient private key (confidentiality only).

\- Signature verification is performed when a signature is present.

\- Message handling only proceeds for messages identified as 'for me'.

Blindspots:

\- Runtime configuration flags could enforce signature requirements not visible in the reviewed code.

\- No dynamic validation of BLE stack or production build settings was possible in this environment.

