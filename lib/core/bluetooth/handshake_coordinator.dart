import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/domain/models/protocol_message.dart';
import 'package:pak_connect/domain/interfaces/i_handshake_coordinator.dart';
import 'package:pak_connect/domain/interfaces/i_repository_provider.dart';
import 'package:pak_connect/domain/models/connection_phase.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/core/security/noise/models/noise_models.dart';
import 'package:pak_connect/core/security/noise/noise_session.dart';
import 'package:pak_connect/domain/routing/topology_manager.dart';
import 'package:pak_connect/domain/utils/string_extensions.dart';
import 'handshake_timeout_manager.dart';
import 'kk_pattern_tracker.dart';
import 'noise_handshake_driver.dart';
import 'handshake_peer_state.dart';
import 'package:pak_connect/domain/models/security_level.dart';

part 'handshake_coordinator_phase2_helper.dart';

/// Manages the handshake protocol between two BLE devices
/// Ensures no message proceeds without explicit confirmation
class HandshakeCoordinator implements IHandshakeCoordinator {
  final Logger _logger;

  // State management
  ConnectionPhase _phase = ConnectionPhase.bleConnected;
  final Set<void Function(ConnectionPhase)> _phaseListeners = {};
  @override
  Stream<ConnectionPhase> get phaseStream =>
      Stream<ConnectionPhase>.multi((controller) {
        controller.add(_phase);

        void listener(ConnectionPhase phase) {
          controller.add(phase);
        }

        _phaseListeners.add(listener);
        controller.onCancel = () {
          _phaseListeners.remove(listener);
        };
      });
  @override
  ConnectionPhase get currentPhase => _phase;
  final HandshakePeerState _peerState = HandshakePeerState();

  // Timeout management
  late final HandshakeTimeoutManager _timeoutManager;

  // Noise handshake state
  late final KKPatternTracker _kkTracker;
  late final NoiseHandshakeDriver _noiseDriver;
  late final _HandshakeCoordinatorPhase2Helper _phase2Helper;

  // Role tracking: true = initiator (central), false = responder (peripheral)
  bool _isInitiator = false;

  // Our data
  final String _myEphemeralId; // Our ephemeral ID (sent during handshake)
  final String _myPublicKey; // Our persistent key (kept private until pairing)
  final String _myDisplayName;

  // Dependencies
  final IRepositoryProvider? _repositoryProvider;

  // Callbacks for sending messages
  final Future<void> Function(ProtocolMessage) _sendMessage;
  final Future<void> Function(
    String ephemeralId,
    String displayName,
    String? noisePublicKey,
  )
  _onHandshakeComplete;

  Future<void> Function(String peerEphemeralId)? onHandshakeSuccess;

  final Function(bool inProgress)? onHandshakeStateChanged;

  final Function(String contactName, String reason)? onSecurityDowngrade;

  final Function(String reason)? onHandshakeFallback;

  HandshakeCoordinator({
    required String myEphemeralId,
    required String myPublicKey,
    required String myDisplayName,
    IRepositoryProvider? repositoryProvider,
    required Future<void> Function(ProtocolMessage) sendMessage,
    required Future<void> Function(
      String ephemeralId,
      String displayName,
      String? noisePublicKey,
    )
    onHandshakeComplete,
    Duration? phaseTimeout,
    this.onHandshakeSuccess,
    this.onHandshakeStateChanged,
    this.onSecurityDowngrade,
    this.onHandshakeFallback,
    bool startAsInitiator = true,
  }) : _logger = Logger('[HandshakeCoordinator]'),
       _myEphemeralId = myEphemeralId,
       _myPublicKey = myPublicKey,
       _myDisplayName = myDisplayName,
       _repositoryProvider =
           repositoryProvider ??
           (GetIt.instance.isRegistered<IRepositoryProvider>()
               ? GetIt.instance<IRepositoryProvider>()
               : null),
       _sendMessage = sendMessage,
       _onHandshakeComplete = onHandshakeComplete {
    _timeoutManager = HandshakeTimeoutManager(
      _logger,
      phaseTimeout: phaseTimeout ?? const Duration(seconds: 10),
    );
    _kkTracker = KKPatternTracker(logger: _logger);
    _noiseDriver = NoiseHandshakeDriver(
      logger: _logger,
      kkPatternTracker: _kkTracker,
      noiseService: SecurityManager.instance.noiseService,
    );
    if (phaseTimeout != null) {
      _timeoutManager.phaseTimeout = phaseTimeout;
    }
    _isInitiator = startAsInitiator;
    _phase2Helper = _HandshakeCoordinatorPhase2Helper(this);
  }

  /// Start the handshake process
  /// This is the entry point - call this after BLE connection is established
  @override
  Future<void> startHandshake() async {
    _logger.info(
      '🤝 Starting handshake @${DateTime.now().toIso8601String()} (phase: $_phase, role: ${_isInitiator ? 'INITIATOR' : 'RESPONDER'})',
    );

    if (_phase != ConnectionPhase.bleConnected) {
      _logger.warning('⚠️ Handshake already in progress or complete');
      return;
    }

    // Notify: Handshake starting (pause health checks)
    onHandshakeStateChanged?.call(true);

    if (_isInitiator) {
      await _advanceToReadySent();
    } else {
      _logger.info('⏸️ Responder mode - waiting for initiator connectionReady');
      _startPhaseTimeout('connectionReady');
    }
  }

  /// Handle received protocol messages
  /// Routes messages based on current phase and type
  @override
  Future<void> handleReceivedMessage(ProtocolMessage message) async {
    _logger.info('📨 Received ${message.type} in phase $_phase');

    // Cancel timeout when we receive expected message
    _timeoutManager.cancelTimeout();

    try {
      switch (message.type) {
        // Phase 0: Ready check
        case ProtocolMessageType.connectionReady:
          await _handleConnectionReady(message);
          break;

        // Phase 1: Identity exchange
        case ProtocolMessageType.identity:
          await _handleIdentity(message);
          break;

        // Phase 1.5: Noise Protocol Handshake (XX or KK)
        case ProtocolMessageType.noiseHandshake1:
          await _handleNoiseHandshake1(message);
          break;

        case ProtocolMessageType.noiseHandshake2:
          await _handleNoiseHandshake2(message);
          break;

        case ProtocolMessageType.noiseHandshake3:
          await _handleNoiseHandshake3(message);
          break;

        // Phase 1.5: Noise handshake rejection (KK pattern coordination)
        case ProtocolMessageType.noiseHandshakeRejected:
          await _handleNoiseHandshakeRejected(message);
          break;

        // Phase 2: Contact status
        case ProtocolMessageType.contactStatus:
          await _handleContactStatus(message);
          break;

        default:
          _logger.warning(
            '⚠️ Unexpected message type ${message.type} in phase $_phase',
          );
      }
    } catch (e, stack) {
      _logger.severe('❌ Error handling message: $e', e, stack);
      await _failHandshake('Error handling message: $e');
    }
  }

  // ========== PHASE 0: CONNECTION READY ==========

  Future<void> _advanceToReadySent() async {
    _logger.info('📤 Phase 0: Sending connectionReady');
    _phase = ConnectionPhase.readySent;
    _emitPhase(_phase);

    final message = ProtocolMessage.connectionReady(
      deviceId: _myPublicKey,
      deviceName: _myDisplayName,
    );

    await _sendWithGuard(message, 'connectionReady');
    _startPhaseTimeout('connectionReadyAck');
  }

  Future<void> _handleConnectionReady(ProtocolMessage message) async {
    _logger.info('📥 Received connectionReady');
    final peerId = message.connectionReadyDeviceId;

    // Valid in: bleConnected (peripheral), readySent (central)
    if (_phase != ConnectionPhase.bleConnected &&
        _phase != ConnectionPhase.readySent) {
      _logger.warning('⚠️ Unexpected connectionReady in phase $_phase');
      return;
    }

    // PERIPHERAL FLOW: We haven't sent yet, so send now (response IS ack)
    if (_phase == ConnectionPhase.bleConnected) {
      _logger.info(
        '🔄 Peripheral: Received ready, sending our ready (response IS ack)',
      );
      _isInitiator = _resolveInitiatorFromReady(peerId);
      _logger.info(
        _isInitiator
            ? '📤 Peripheral: Assuming initiator role after tie-break'
            : '⏸️ Peripheral: Proceeding as responder after tie-break',
      );

      _logger.info('✅ Phase 0 Complete: Both devices ready');
      _phase = ConnectionPhase.readyComplete;
      _emitPhase(_phase);

      // Send response, then continue based on role
      final response = ProtocolMessage.connectionReady(
        deviceId: _myPublicKey,
        deviceName: _myDisplayName,
      );
      await _sendWithGuard(response, 'connectionReady (ack)');

      if (_isInitiator) {
        _logger.info('📤 Role: INITIATOR - proceeding to send identity');
        await _advanceToIdentitySent();
      } else {
        _logger.info('⏸️ Role: RESPONDER - waiting for identity');
        _startPhaseTimeout('identity');
      }
      return;
    }

    // CENTRAL FLOW: We sent first, they responded, advance
    if (_phase == ConnectionPhase.readySent) {
      // Glare handling: if both sides sent ready, tie-break deterministically
      // using public keys so only one side proceeds as initiator.
      _isInitiator = _resolveInitiatorFromReady(peerId);
      _logger.info(
        _isInitiator
            ? '✅ Central: Keeping initiator role after ready glare tie-break'
            : '✅ Central: Yielding initiator role after ready glare tie-break',
      );
      await _advanceToReadyComplete();
      return;
    }
  }

  Future<void> _advanceToReadyComplete() async {
    _logger.info('✅ Phase 0 Complete: Both devices ready');
    _phase = ConnectionPhase.readyComplete;
    _emitPhase(_phase);

    // Only initiator sends identity first, responder waits
    if (_isInitiator) {
      _logger.info('📤 Role: INITIATOR - proceeding to send identity');
      await _advanceToIdentitySent();
    } else {
      _logger.info('⏸️ Role: RESPONDER - waiting for identity');
      _startPhaseTimeout('identity');
    }
  }

  // ========== PHASE 1: IDENTITY EXCHANGE ==========

  Future<void> _advanceToIdentitySent() async {
    _logger.info(
      '📤 Phase 1: Sending identity (ephemeral ID only - privacy-preserving)',
    );
    _phase = ConnectionPhase.identitySent;
    _emitPhase(_phase);

    // SECURITY: Send ephemeral ID, NOT persistent public key
    // Persistent keys are only exchanged AFTER pairing succeeds
    final message = ProtocolMessage.identity(
      publicKey: _myEphemeralId, // ← Ephemeral ID (privacy-preserving)
      displayName: _myDisplayName,
    );

    await _sendWithGuard(message, 'identity');
    _startPhaseTimeout('identity');
  }

  Future<void> _handleIdentity(ProtocolMessage message) async {
    _logger.info('📥 Received identity (ephemeral ID)');

    // Valid in: readyComplete (peripheral), identitySent (central)
    if (_phase != ConnectionPhase.readyComplete &&
        _phase != ConnectionPhase.identitySent) {
      _logger.warning('⚠️ Unexpected identity in phase $_phase');
      return;
    }

    // Store their EPHEMERAL identity (not persistent key!)
    _peerState.setIdentity(
      ephemeralId: message.identityPublicKey!,
      displayName: message.identityDisplayName,
    );

    // Log ephemeral ID (it's already short, typically 8 chars)
    _logger.info('  Their ephemeral ID: ${_peerState.theirEphemeralId}');
    _logger.info('  Their display name: ${_peerState.theirDisplayName}');

    // PERIPHERAL FLOW: We haven't sent yet, so send now (response IS ack)
    if (_phase == ConnectionPhase.readyComplete) {
      _logger.info(
        '🔄 Peripheral: Received identity, sending our identity (response IS ack)',
      );

      // Advance to identity complete FIRST (before sending)
      await _advanceToIdentityComplete();

      // Then send response
      final response = ProtocolMessage.identity(
        publicKey: _myEphemeralId, // ← Send ephemeral ID
        displayName: _myDisplayName,
      );
      await _sendWithGuard(response, 'identity (ack)');
      return;
    }

    // CENTRAL FLOW: We sent first, they responded, advance
    if (_phase == ConnectionPhase.identitySent) {
      _logger.info('✅ Central: Received their identity response - advancing');
      await _advanceToIdentityComplete();
      return;
    }
  }

  Future<void> _advanceToIdentityComplete() async {
    _logger.info('✅ Phase 1 Complete: Identity exchange done');
    _phase = ConnectionPhase.identityComplete;
    _emitPhase(_phase);

    // ✅ FIX: Only initiator (central) sends noiseHandshake1
    // Responder (peripheral) waits to receive it
    if (_isInitiator) {
      _logger.info('📤 Role: INITIATOR - proceeding to send Noise handshake 1');
      await _advanceToNoiseHandshake1Sent();
    } else {
      _logger.info('⏸️ Role: RESPONDER - waiting for Noise handshake 1');
      _startPhaseTimeout('noiseHandshake1');
    }
  }

  // ========== PHASE 1.5: NOISE PROTOCOL HANDSHAKE (XX or KK) ==========

  Future<void> _advanceToNoiseHandshake1Sent() async {
    _logger.info('📤 Phase 1.5: Initiating Noise handshake');
    _phase = ConnectionPhase.noiseHandshake1Sent;
    _emitPhase(_phase);

    try {
      final plan = await _noiseDriver.prepareHandshake1(
        myEphemeralId: _myEphemeralId,
        theirEphemeralId: _peerState.theirEphemeralId!,
        theirNoisePublicKey: _peerState.theirNoisePublicKey,
      );

      _peerState.markAttemptedPattern(plan.pattern);
      _logger.info('  Selected pattern: ${plan.pattern}');

      // Send message 1 (size indicates pattern: 32=XX, 96=KK)
      final message = ProtocolMessage.noiseHandshake1(
        handshakeData: plan.message1,
        peerId: _myEphemeralId,
      );

      await _sendWithGuard(message, 'noiseHandshake1');
      _startPhaseTimeout('noiseHandshake2');
    } catch (e) {
      _logger.severe('❌ Failed to send Noise handshake 1: $e');
      await _failHandshake('Noise handshake 1 failed: $e');
    }
  }

  Future<void> _handleNoiseHandshake1(ProtocolMessage message) async {
    _logger.info('📥 Received Noise handshake 1');

    // Valid in: identityComplete (peripheral/responder)
    if (_phase != ConnectionPhase.identityComplete) {
      _logger.warning('⚠️ Unexpected noiseHandshake1 in phase $_phase');
      return;
    }

    try {
      final data = message.noiseHandshakeData;
      if (data == null) {
        throw Exception('No handshake data in message');
      }

      // PATTERN DETECTION: Check message size to determine pattern
      final isKK = data.length == 96; // KK message 1 is 96 bytes (e, es, ss)
      final isXX = data.length == 32; // XX message 1 is 32 bytes (e)

      _logger.info(
        '  Received ${data.length} bytes (pattern: ${isKK
            ? 'KK'
            : isXX
            ? 'XX'
            : 'UNKNOWN'})',
      );

      // Ensure stale sessions don't block re-key handshakes on responder side,
      // but avoid tearing down healthy established sessions.
      final peerId = message.noiseHandshakePeerId;
      final noiseService = SecurityManager.instance.noiseService;
      if (peerId != null && noiseService != null) {
        final sessionState = noiseService.getSessionState(peerId);
        final needsRekey = noiseService.checkForRekeyNeeded().contains(peerId);

        final isEstablished = sessionState == NoiseSessionState.established;
        final shouldPreserveEstablished =
            isEstablished && !needsRekey && _phase == ConnectionPhase.complete;

        if (shouldPreserveEstablished) {
          _logger.warning(
            '🛡️ Ignoring duplicate handshake1 for $peerId - session already established and handshake complete',
          );
          return;
        }

        if (isEstablished) {
          _logger.info(
            needsRekey
                ? '🔄 Rekey needed for $peerId - clearing session before responder handshake'
                : '♻️ Clearing existing session for $peerId to allow fresh handshake',
          );
        }

        try {
          noiseService.removeSession(peerId);
        } catch (_) {}
      }

      // SCENARIO A: Peer initiated KK but we don't have their key
      if (isKK) {
        _logger.info(
          '🔑 Peer attempting KK - checking if we have their key...',
        );
      }

      // SCENARIO B: Peer initiated XX but we expected KK (pattern mismatch)
      if (isXX) {
        _logger.info('📉 Peer using XX pattern');
      }

      final result = await _noiseDriver.processInboundHandshake1(
        data: data,
        peerId: message.noiseHandshakePeerId!,
      );

      // Send message 2
      _phase = ConnectionPhase.noiseHandshake2Sent;
      _emitPhase(_phase);

      final response = ProtocolMessage.noiseHandshake2(
        handshakeData: result.message2,
        peerId: _myEphemeralId,
      );

      await _sendWithGuard(response, 'noiseHandshake2');

      // KK handshake completes after message 2! (no message 3)
      if (result.isKkPattern) {
        _logger.info('✅ KK handshake complete (2 messages)');
        _startPhaseTimeout('contact status');
        await _advanceToNoiseHandshakeComplete();
      } else {
        // XX handshake continues to message 3
        _startPhaseTimeout('noiseHandshake3');
      }
    } catch (e) {
      _logger.severe('❌ Failed to handle Noise handshake 1: $e');

      // Check if this is a KK rejection scenario
      final data = message.noiseHandshakeData;
      if (data != null && data.length == 96) {
        // This was a KK attempt that failed
        _logger.warning('⚠️ KK handshake failed - sending rejection');

        await _sendRejectionMessage(
          reason: 'missing_key',
          attemptedPattern: 'kk',
          suggestedPattern: 'xx',
          contactStatus: {
            'haveThemAsContact': false, // We don't have their key
            'shouldDowngrade': true, // Peer should downgrade us
          },
        );

        // Wait for peer to retry with XX
        _logger.info('⏳ Waiting for peer to retry with XX pattern');
        _startPhaseTimeout('noiseHandshake1 (retry)');
        return;
      }

      await _failHandshake('Noise handshake 1 processing failed: $e');
    }
  }

  Future<void> _handleNoiseHandshake2(ProtocolMessage message) async {
    _logger.info('📥 Received Noise handshake 2 (<- e, ee, s, es)');

    // Valid in: noiseHandshake1Sent (initiator)
    if (_phase != ConnectionPhase.noiseHandshake1Sent) {
      _logger.warning('⚠️ Unexpected noiseHandshake2 in phase $_phase');
      return;
    }

    try {
      final msg2Data = message.noiseHandshakeData;
      if (msg2Data == null) {
        throw Exception('No handshake data in message');
      }

      _logger.info('  Received ${msg2Data.length} bytes');

      final msg3 = await _noiseDriver.processHandshake2(
        data: msg2Data,
        peerId: message.noiseHandshakePeerId!,
      );

      // Send message 3
      final response = ProtocolMessage.noiseHandshake3(
        handshakeData: msg3,
        peerId: _myEphemeralId,
      );

      await _sendWithGuard(response, 'noiseHandshake3');

      // After sending message 3, handshake is complete on our side
      await _advanceToNoiseHandshakeComplete();
    } catch (e) {
      _logger.severe('❌ Failed to handle Noise handshake 2: $e');
      await _failHandshake('Noise handshake 2 processing failed: $e');
    }
  }

  Future<void> _handleNoiseHandshake3(ProtocolMessage message) async {
    _logger.info('📥 Received Noise handshake 3 (-> s, se)');

    // Valid in: noiseHandshake2Sent (responder)
    if (_phase != ConnectionPhase.noiseHandshake2Sent) {
      _logger.warning('⚠️ Unexpected noiseHandshake3 in phase $_phase');
      return;
    }

    try {
      final msg3Data = message.noiseHandshakeData;
      if (msg3Data == null) {
        throw Exception('No handshake data in message');
      }

      _logger.info('  Received ${msg3Data.length} bytes');

      await _noiseDriver.processHandshake3(
        data: msg3Data,
        peerId: message.noiseHandshakePeerId!,
      );

      // Handshake complete
      await _advanceToNoiseHandshakeComplete();
    } catch (e) {
      _logger.severe('❌ Failed to handle Noise handshake 3: $e');
      await _failHandshake('Noise handshake 3 processing failed: $e');
    }
  }

  Future<void> _advanceToNoiseHandshakeComplete() =>
      _phase2Helper.advanceToNoiseHandshakeComplete();

  /// Wait for peer's Noise public key with exponential backoff
  ///
  /// FIX-008: Ensures Noise session is fully established before Phase 2
  ///
  /// [timeout] Maximum total wait time
  /// [maxRetries] Maximum number of retry attempts
  ///
  /// Throws [TimeoutException] if key not available after retries
  Future<void> _waitForPeerNoiseKey({
    required Duration timeout,
    required int maxRetries,
  }) => _phase2Helper.waitForPeerNoiseKey(
    timeout: timeout,
    maxRetries: maxRetries,
  );

  // ========== PHASE 2: CONTACT STATUS EXCHANGE ==========

  Future<void> _advanceToContactStatusSent() =>
      _phase2Helper.advanceToContactStatusSent();

  Future<void> _handleContactStatus(ProtocolMessage message) =>
      _phase2Helper.handleContactStatus(message);

  Future<void> _advanceToContactStatusComplete() =>
      _phase2Helper.advanceToContactStatusComplete();

  // ========== HANDSHAKE COMPLETION ==========

  Future<void> _advanceToComplete() => _phase2Helper.advanceToComplete();

  // ========== TIMEOUT & ERROR HANDLING ==========

  void _startPhaseTimeout(String waitingFor) =>
      _phase2Helper.startPhaseTimeout(waitingFor);

  Future<void> _failHandshake(String reason) =>
      _phase2Helper.failHandshake(reason);

  Future<void> _sendWithGuard(ProtocolMessage message, String context) =>
      _phase2Helper.sendWithGuard(message, context);

  // ========== KK PATTERN REJECTION HANDLING ==========

  /// Send rejection message when we can't do KK
  Future<void> _sendRejectionMessage({
    required String reason,
    required String attemptedPattern,
    required String suggestedPattern,
    Map<String, dynamic>? contactStatus,
  }) => _phase2Helper.sendRejectionMessage(
    reason: reason,
    attemptedPattern: attemptedPattern,
    suggestedPattern: suggestedPattern,
    contactStatus: contactStatus,
  );

  /// Handle rejection message from peer
  Future<void> _handleNoiseHandshakeRejected(ProtocolMessage message) =>
      _phase2Helper.handleNoiseHandshakeRejected(message);

  // ========== KK FAILURE TRACKING ==========

  // ========== CLEANUP ==========

  @override
  void dispose() {
    _timeoutManager.dispose();
    _phaseListeners.clear();
  }

  // ========== GETTERS ==========

  String? get theirEphemeralId => _peerState.theirEphemeralId;
  String? get theirDisplayName => _peerState.theirDisplayName;
  String? get theirNoisePublicKey =>
      _peerState.theirNoisePublicKey; // Noise static public key (base64)
  String get myPersistentKey => _myPublicKey; // Accessor for pairing phase
  bool? get theyHaveUsAsContact => _peerState.theyHaveUsAsContact;
  @override
  bool get isComplete => _phase == ConnectionPhase.complete;
  bool get hasFailed =>
      _phase == ConnectionPhase.failed || _phase == ConnectionPhase.timeout;

  void _emitPhase(ConnectionPhase phase) {
    for (final listener in List.of(_phaseListeners)) {
      try {
        listener(phase);
      } catch (e, stackTrace) {
        _logger.warning('Error notifying phase listener: $e', e, stackTrace);
      }
    }
  }

  bool _resolveInitiatorFromReady(String? peerId) {
    if (peerId == null || peerId.isEmpty) {
      return _isInitiator;
    }
    return _myPublicKey.compareTo(peerId) >= 0;
  }
}
