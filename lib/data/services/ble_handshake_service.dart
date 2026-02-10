import 'dart:async';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../../core/bluetooth/handshake_coordinator.dart';
import '../../core/interfaces/i_ble_handshake_service.dart';
import '../../core/interfaces/i_ble_state_manager_facade.dart';
import '../../core/models/protocol_message.dart';
import '../../core/models/spy_mode_info.dart';
import '../../core/security/ephemeral_key_manager.dart';
import '../../core/services/hint_advertisement_service.dart';
import '../../data/repositories/intro_hint_repository.dart';
import 'ble_messaging_service.dart' show HandshakeSendException;

class _BufferedMessage {
  final Uint8List data;
  final bool isFromPeripheral;
  final DateTime timestamp;

  _BufferedMessage({
    required this.data,
    required this.isFromPeripheral,
    required this.timestamp,
  });
}

/// Manages BLE handshake protocol execution and identity resolution.
///
/// Extracted from BLEService in Phase 2A.2.2e
///
/// Responsibility: Handle all handshake and identity-related operations
/// - 4-phase handshake coordination (CONNECTION_READY → IDENTITY_EXCHANGE → NOISE_HANDSHAKE → CONTACT_STATUS_SYNC)
/// - Noise session establishment (XX/KK pattern selection)
/// - Identity collision detection and resolution
/// - Spy mode and identity exposure detection
/// - Processing of buffered messages after handshake completion
class BLEHandshakeService implements IBLEHandshakeService {
  final _logger = Logger('BLEHandshakeService');

  // ===== Dependencies =====
  final IBLEStateManagerFacade _stateManager;
  final void Function(String, String) _onIdentityExchangeSent;
  final void Function({
    bool? isConnected,
    bool? isReady,
    String? otherUserName,
    String? statusMessage,
  })
  _updateConnectionInfo;
  final void Function(bool) _setHandshakeInProgress;
  final void Function(SpyModeInfo) _handleSpyModeDetected;
  final void Function(String) _handleIdentityRevealed;
  final Future<void> Function(ProtocolMessage) _sendProtocolMessage;
  final Future<void> Function() _processPendingMessages;
  final Future<void> Function() _startGossipSync;
  final Future<void> Function(
    String ephemeralId,
    String displayName,
    String? noiseKey,
  )
  _onHandshakeCompleteCallback;
  final Set<void Function(SpyModeInfo)> _spyModeListeners = {};
  final Set<void Function(String)> _identityRevealedListeners = {};
  final IntroHintRepository _introHintRepo;
  final List<dynamic> _messageBuffer; // List<_BufferedMessage> from facade
  final bool Function()? _connectionStatusProvider;

  // ===== Handshake State =====
  HandshakeCoordinator? _handshakeCoordinator;
  StreamSubscription<ConnectionPhase>? _handshakePhaseSubscription;
  final Set<void Function(ConnectionPhase)> _handshakePhaseListeners = {};

  @override
  Stream<ConnectionPhase> get handshakePhaseStream =>
      Stream<ConnectionPhase>.multi((controller) {
        final phase = _handshakeCoordinator?.currentPhase;
        if (phase != null) controller.add(phase);

        void listener(ConnectionPhase newPhase) {
          controller.add(newPhase);
        }

        _handshakePhaseListeners.add(listener);
        controller.onCancel = () {
          _handshakePhaseListeners.remove(listener);
        };
      });

  BLEHandshakeService({
    required IBLEStateManagerFacade stateManager,
    required void Function(String, String) onIdentityExchangeSent,
    required void Function({
      bool? isConnected,
      bool? isReady,
      String? otherUserName,
      String? statusMessage,
    })
    updateConnectionInfo,
    required void Function(bool) setHandshakeInProgress,
    required void Function(SpyModeInfo) handleSpyModeDetected,
    required void Function(String) handleIdentityRevealed,
    required Future<void> Function(ProtocolMessage) sendProtocolMessage,
    required Future<void> Function() processPendingMessages,
    required Future<void> Function() startGossipSync,
    required Future<void> Function(
      String ephemeralId,
      String displayName,
      String? noiseKey,
    )
    onHandshakeCompleteCallback,
    required IntroHintRepository introHintRepo,
    required List<dynamic> messageBuffer,
    bool Function()? connectionStatusProvider,
  }) : _stateManager = stateManager,
       _onIdentityExchangeSent = onIdentityExchangeSent,
       _updateConnectionInfo = updateConnectionInfo,
       _setHandshakeInProgress = setHandshakeInProgress,
       _handleSpyModeDetected = handleSpyModeDetected,
       _handleIdentityRevealed = handleIdentityRevealed,
       _sendProtocolMessage = sendProtocolMessage,
       _processPendingMessages = processPendingMessages,
       _startGossipSync = startGossipSync,
       _onHandshakeCompleteCallback = onHandshakeCompleteCallback,
       _introHintRepo = introHintRepo,
       _messageBuffer = messageBuffer,
       _connectionStatusProvider = connectionStatusProvider;

  bool get _isBleConnected {
    if (_connectionStatusProvider != null) {
      try {
        return _connectionStatusProvider();
      } catch (_) {}
    }
    try {
      return _stateManager.isConnected;
    } catch (_) {
      return true;
    }
  }

  @override
  Future<void> performHandshake({bool? startAsInitiatorOverride}) async {
    _logger.info(
      '🤝 Starting handshake protocol @${DateTime.now().toIso8601String()}...',
    );

    try {
      if (_handshakeCoordinator != null && !_handshakeCoordinator!.isComplete) {
        _logger.warning(
          '⚠️ Handshake already in progress '
          '(phase: ${_handshakeCoordinator!.currentPhase}) - ignoring duplicate performHandshake call',
        );
        return;
      }

      // Clean up old handshake coordinator if it exists
      disposeHandshakeCoordinator();

      // 🔧 CRITICAL: Get ephemeral ID from EphemeralKeyManager (NOT BLEStateManager)
      // BLEStateManager._myEphemeralId is for pairing messages only
      // HandshakeCoordinator uses EphemeralKeyManager for actual handshake
      final myEphemeralId = EphemeralKeyManager.generateMyEphemeralKey();
      final myPublicKey = await _stateManager.getMyPersistentId();
      final myDisplayName = _stateManager.myUserName ?? 'User';

      _logger.info('🔧 INVESTIGATION: Handshake using EphemeralKeyManager');
      _logger.info(
        '📱 My ephemeral ID (from EphemeralKeyManager): ${myEphemeralId.length > 16 ? '${myEphemeralId.substring(0, 8)}...' : myEphemeralId}',
      );
      _logger.info(
        '🔒 My persistent key (not sent during handshake): ${myPublicKey.length > 16 ? '${myPublicKey.substring(0, 8)}...' : myPublicKey}',
      );
      _logger.info('📝 My display name: $myDisplayName');

      // For comparison, log BLEStateManager ephemeral ID (NOT used here)
      final stateManagerEphemeralId = _stateManager.myEphemeralId;
      if (stateManagerEphemeralId != null) {
        _logger.info(
          '⚠️ BLEStateManager ephemeral ID (NOT used in handshake): ${stateManagerEphemeralId.substring(0, 8)}...',
        );
        if (myEphemeralId != stateManagerEphemeralId) {
          _logger.warning(
            '⚠️ DIFFERENT ephemeral IDs! HandshakeCoordinator uses EphemeralKeyManager, NOT BLEStateManager!',
          );
        }
      }

      // Create handshake coordinator
      final bool isInboundPeripheralConnection =
          startAsInitiatorOverride == null;
      final bool startAsInitiator =
          startAsInitiatorOverride ?? !isInboundPeripheralConnection;

      _logger.info(
        '🤝 Handshake role: ${startAsInitiator ? 'INITIATOR (central/client)' : 'RESPONDER (peripheral/server)'}${startAsInitiatorOverride != null ? ' (forced)' : ''}',
      );

      _handshakeCoordinator = HandshakeCoordinator(
        myEphemeralId: myEphemeralId,
        myPublicKey: myPublicKey,
        myDisplayName: myDisplayName,
        sendMessage: _sendHandshakeMessage,
        onHandshakeComplete: _onHandshakeCompleteCallback,
        phaseTimeout: Duration(seconds: 10),
        onHandshakeStateChanged: (inProgress) {
          _setHandshakeInProgress(inProgress);
        },
        startAsInitiator: startAsInitiator,
      );

      // Listen to phase changes for UI feedback
      _handshakePhaseSubscription = _handshakeCoordinator!.phaseStream.listen((
        phase,
      ) async {
        for (final listener in List.of(_handshakePhaseListeners)) {
          try {
            listener(phase);
          } catch (e, stackTrace) {
            _logger.warning(
              'Error notifying handshake phase listener: $e',
              e,
              stackTrace,
            );
          }
        }
        _logger.info('🤝 Handshake phase: $phase');
        _updateConnectionInfo(statusMessage: _getPhaseMessage(phase));

        // 🔧 FIX: Update connection state when handshake completes
        if (phase == ConnectionPhase.complete) {
          _updateConnectionInfo(isConnected: true, statusMessage: 'Connected');
        }

        // 🔧 FIX: Disconnect on handshake failure
        if (phase == ConnectionPhase.failed ||
            phase == ConnectionPhase.timeout) {
          _logger.warning(
            '⚠️ Handshake failed/timeout - disconnecting BLE connection',
          );

          // 🚨 CRITICAL: Set isReady=false IMMEDIATELY to prevent reconnection loop
          _updateConnectionInfo(
            isReady: false,
            statusMessage: 'Connection failed - handshake timeout',
          );
        }
      });

      // ✅ FIX: Process any buffered protocol messages that arrived before coordinator was created
      final bufferedProtocolMessages = <_BufferedMessage>[];
      final bufferedSnapshot = List<dynamic>.from(_messageBuffer);
      for (final buffered in bufferedSnapshot) {
        try {
          final protocolMessage = ProtocolMessage.fromBytes(buffered.data);
          if (_isHandshakeMessage(protocolMessage.type)) {
            bufferedProtocolMessages.add(buffered);
            _logger.info(
              '📦 Processing buffered ${protocolMessage.type} from before coordinator creation',
            );
            await _handshakeCoordinator!.handleReceivedMessage(protocolMessage);
          }
        } catch (e) {
          // Not a protocol message, leave it in buffer for later processing
        }
      }
      // Remove processed protocol messages from buffer
      for (final processed in bufferedProtocolMessages) {
        _messageBuffer.remove(processed);
      }
      if (bufferedProtocolMessages.isNotEmpty) {
        _logger.info(
          '✅ Processed ${bufferedProtocolMessages.length} buffered protocol message(s)',
        );
      }

      // Start the handshake
      await _handshakeCoordinator!.startHandshake();
    } catch (e, stack) {
      _logger.severe('🚨 Handshake failed: $e', e, stack);
      _updateConnectionInfo(
        isConnected: false,
        isReady: false,
        statusMessage: 'Connection failed',
      );
    }
  }

  @override
  Future<void> onHandshakeComplete() async {
    _logger.info(
      '🎉 [INTERFACE] onHandshakeComplete() - running completion hooks',
    );
    await _processPendingMessages();
    await _startGossipSync();
  }

  @override
  void disposeHandshakeCoordinator() {
    if (_handshakeCoordinator != null) {
      _logger.info(
        '🧹 Disposing old handshake coordinator (phase: ${_handshakeCoordinator!.currentPhase})',
      );
      _handshakePhaseSubscription?.cancel();
      _handshakePhaseSubscription = null;
      _handshakeCoordinator!.dispose();
      _handshakeCoordinator = null;
    }

    // Clear listeners to avoid leaks between sessions
    _handshakePhaseListeners.clear();
    _spyModeListeners.clear();
    _identityRevealedListeners.clear();
  }

  @override
  Future<void> requestIdentityExchange() async {
    if (!_isBleConnected) {
      _logger.warning('Cannot request identity - not connected');
      return;
    }

    _logger.info('Manually requesting identity exchange');
    await _sendIdentityExchange();
  }

  @override
  Future<void> triggerIdentityReExchange() async {
    _logger.info(
      '🔄 USERNAME PROPAGATION: Triggering identity re-exchange for updated username',
    );

    try {
      // Force reload username from storage to ensure we have the latest
      await _stateManager.loadUserName();

      // Re-send identity with updated username
      if (_stateManager.isPeripheralMode) {
        await _sendPeripheralIdentityExchange();
      } else {
        await _sendIdentityExchange();
      }

      _logger.info(
        '✅ USERNAME PROPAGATION: Identity re-exchange completed successfully',
      );
    } catch (e) {
      _logger.warning(
        '❌ USERNAME PROPAGATION: Identity re-exchange failed: $e',
      );
    }
  }

  @override
  Future<String?> buildLocalCollisionHint() async {
    try {
      final sessionKey = EphemeralKeyManager.currentSessionKey;
      if (sessionKey == null) {
        _logger.fine('⚖️ Collision hint unavailable - no session key');
        return null;
      }

      final nonce = HintAdvertisementService.deriveNonce(sessionKey);
      final introHint = await _introHintRepo.getMostRecentActiveHint();
      final useIntro = introHint != null && introHint.isUsable;
      final identifier = useIntro
          ? introHint.hintHex
          : await _stateManager.getMyPersistentId();

      if (identifier.isEmpty) {
        _logger.fine('⚖️ Collision hint unavailable - identifier missing');
        return null;
      }

      final hintBytes = HintAdvertisementService.computeHintBytes(
        identifier: identifier,
        nonce: nonce,
      );

      final token =
          '${HintAdvertisementService.bytesToHex(nonce)}:${HintAdvertisementService.bytesToHex(hintBytes)}';
      return token;
    } catch (e) {
      _logger.warning('⚖️ Failed to compute local collision hint: $e');
      return null;
    }
  }

  @override
  Future<void> handleMutualConsentRequired() async {
    _logger.info('[STUB] handleMutualConsentRequired()');
    // TODO: Extract actual implementation if needed
  }

  @override
  Future<void> handleAsymmetricContact(String contactKey) async {
    _logger.info('[STUB] handleAsymmetricContact()');
    // TODO: Extract actual implementation if needed
  }

  @override
  Stream<SpyModeInfo> get spyModeDetectedStream {
    return Stream<SpyModeInfo>.multi((controller) {
      void listener(SpyModeInfo info) {
        controller.add(info);
      }

      _spyModeListeners.add(listener);
      controller.onCancel = () {
        _spyModeListeners.remove(listener);
      };
    });
  }

  @override
  Stream<String> get identityRevealedStream {
    return Stream<String>.multi((controller) {
      void listener(String identity) {
        controller.add(identity);
      }

      _identityRevealedListeners.add(listener);
      controller.onCancel = () {
        _identityRevealedListeners.remove(listener);
      };
    });
  }

  @override
  void emitSpyModeDetected(SpyModeInfo info) {
    _emitSpyMode(info);
  }

  @override
  void emitIdentityRevealed(String contactId) {
    _emitIdentity(contactId);
  }

  void _emitSpyMode(SpyModeInfo info) {
    try {
      _handleSpyModeDetected(info);
    } catch (e, stackTrace) {
      _logger.warning('Error invoking spy mode callback: $e', e, stackTrace);
    }
    for (final listener in List.of(_spyModeListeners)) {
      try {
        listener(info);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying spy mode listener: $e', e, stackTrace);
      }
    }
  }

  void _emitIdentity(String identity) {
    try {
      _handleIdentityRevealed(identity);
    } catch (e, stackTrace) {
      _logger.warning('Error invoking identity callback: $e', e, stackTrace);
    }
    for (final listener in List.of(_identityRevealedListeners)) {
      try {
        listener(identity);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying identity listener: $e', e, stackTrace);
      }
    }
  }

  @override
  String getPhaseMessage(String phase) {
    return _getPhaseMessage(phase as ConnectionPhase);
  }

  @override
  bool isHandshakeMessage(String messageType) {
    // Parse the string as ProtocolMessageType
    try {
      final type = ProtocolMessageType.values.firstWhere(
        (e) => e.toString().split('.').last == messageType,
        orElse: () => ProtocolMessageType.connectionReady,
      );
      return _isHandshakeMessage(type);
    } catch (e) {
      return false;
    }
  }

  @override
  List<dynamic> getBufferedMessages() {
    return _messageBuffer.toList();
  }

  @override
  bool get isHandshakeInProgress {
    return _handshakeCoordinator != null && !_handshakeCoordinator!.isComplete;
  }

  @override
  bool get hasHandshakeCompleted {
    return _handshakeCoordinator != null && _handshakeCoordinator!.isComplete;
  }

  @override
  String? get currentHandshakePhase {
    return _handshakeCoordinator?.currentPhase.toString();
  }

  @override
  Future<bool> handleIncomingHandshakeMessage(
    Uint8List data, {
    bool isFromPeripheral = false,
  }) async {
    ProtocolMessage? protocolMessage;
    try {
      protocolMessage = ProtocolMessage.fromBytes(data);
    } catch (_) {
      // Not a protocol message
      return false;
    }

    if (!_isHandshakeMessage(protocolMessage.type)) {
      return false;
    }

    if (_handshakeCoordinator != null) {
      _logger.fine(
        '🤝 Routing inbound ${protocolMessage.type} to handshake coordinator '
        '(fromPeripheral=$isFromPeripheral)',
      );
      await _handshakeCoordinator!.handleReceivedMessage(protocolMessage);
      return true;
    }

    // No coordinator yet: buffer for when handshake starts.
    _messageBuffer.add(
      _BufferedMessage(
        data: data,
        isFromPeripheral: isFromPeripheral,
        timestamp: DateTime.now(),
      ),
    );
    _logger.fine(
      '📦 Buffered handshake message (${protocolMessage.type}) '
      '(fromPeripheral=$isFromPeripheral)',
    );

    return true;
  }

  // ===== PRIVATE HELPERS =====

  Future<void> _sendHandshakeMessage(ProtocolMessage message) async {
    try {
      // Use the existing queued write system to prevent concurrent writes
      await _sendProtocolMessage(message);
      _logger.fine('✅ Sent handshake message: ${message.type}');
    } on HandshakeSendException catch (e) {
      _logger.severe('❌ Failed to send handshake message ${message.type}: $e');
      rethrow;
    } catch (e) {
      _logger.severe('❌ Failed to send handshake message ${message.type}: $e');
      // Rethrow so handshake coordinator knows it failed
      rethrow;
    }
  }

  Future<void> _sendIdentityExchange() async {
    if (!_isBleConnected) {
      _logger.warning('Cannot send identity - not connected');
      return;
    }

    try {
      final myPublicKey = await _stateManager.getMyPersistentId();
      final displayName = _stateManager.myUserName ?? 'User';

      _logger.info('Sending central identity exchange:');
      _logger.info('  Public key: ${myPublicKey.substring(0, 8)}...');
      _logger.info('  Display name: $displayName');

      final protocolMessage = ProtocolMessage.identity(
        publicKey: myPublicKey,
        displayName: displayName,
      );

      await _sendProtocolMessage(protocolMessage);
      _onIdentityExchangeSent(myPublicKey, displayName);

      _logger.info('✅ Central identity exchange sent successfully');
    } catch (e) {
      _logger.severe('❌ Central identity exchange failed: $e');
      rethrow;
    }
  }

  Future<void> _sendPeripheralIdentityExchange() async {
    if (!_stateManager.isPeripheralMode) {
      _logger.warning(
        'Cannot send peripheral identity - not in peripheral mode',
      );
      return;
    }

    try {
      // CRITICAL: Ensure username is loaded before sending
      if (_stateManager.myUserName == null ||
          _stateManager.myUserName!.isEmpty) {
        await _stateManager.loadUserName();
      }

      final myPublicKey = await _stateManager.getMyPersistentId();
      final displayName = _stateManager.myUserName ?? 'User';

      _logger.info('Sending peripheral identity re-exchange:');
      _logger.info('  Public key: ${myPublicKey.substring(0, 8)}...');
      _logger.info('  Display name: $displayName');

      final protocolMessage = ProtocolMessage.identity(
        publicKey: myPublicKey,
        displayName: displayName,
      );

      await _sendProtocolMessage(protocolMessage);

      _logger.info('✅ Peripheral identity re-exchange sent successfully');
    } catch (e) {
      _logger.severe('❌ Peripheral identity re-exchange failed: $e');
      rethrow;
    }
  }

  String _getPhaseMessage(ConnectionPhase phase) {
    switch (phase) {
      case ConnectionPhase.bleConnected:
        return 'Connected...';
      case ConnectionPhase.readySent:
        return 'Synchronizing...';
      case ConnectionPhase.readyComplete:
        return 'Ready check complete...';
      case ConnectionPhase.identitySent:
        return 'Exchanging identities...';
      case ConnectionPhase.identityComplete:
        return 'Identity verified...';
      case ConnectionPhase.noiseHandshake1Sent:
        return 'Establishing secure session...';
      case ConnectionPhase.noiseHandshake2Sent:
        return 'Finalizing encryption...';
      case ConnectionPhase.noiseHandshakeComplete:
        return 'Secure session established...';
      case ConnectionPhase.contactStatusSent:
        return 'Syncing contact status...';
      case ConnectionPhase.contactStatusComplete:
        return 'Contact status synced...';
      case ConnectionPhase.complete:
        return 'Ready to chat';
      case ConnectionPhase.timeout:
        return 'Connection timeout';
      case ConnectionPhase.failed:
        return 'Connection failed';
    }
  }

  bool _isHandshakeMessage(ProtocolMessageType type) {
    return type == ProtocolMessageType.connectionReady ||
        type == ProtocolMessageType.identity ||
        type == ProtocolMessageType.noiseHandshake1 ||
        type == ProtocolMessageType.noiseHandshake2 ||
        type == ProtocolMessageType.noiseHandshake3 ||
        type == ProtocolMessageType.noiseHandshakeRejected ||
        type == ProtocolMessageType.contactStatus;
  }
}
