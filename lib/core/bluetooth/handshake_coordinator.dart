import 'dart:async';
import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:get_it/get_it.dart';
import 'package:pak_connect/core/models/protocol_message.dart';
import 'package:pak_connect/core/services/security_manager.dart';
import 'package:pak_connect/core/interfaces/i_repository_provider.dart';
import 'package:pak_connect/core/security/noise/models/noise_models.dart';
import 'package:pak_connect/core/networking/topology_manager.dart';
import 'package:pak_connect/core/utils/string_extensions.dart';
import 'handshake_timeout_manager.dart';
import 'kk_pattern_tracker.dart';
import 'noise_handshake_driver.dart';
import 'handshake_peer_state.dart';

/// Connection phases for the sequential handshake protocol
/// Response IS the acknowledgment (no separate ACK messages)
enum ConnectionPhase {
  // Initial state - BLE connected but handshake not started
  bleConnected,

  // Phase 0: Ready check - ensure both devices' BLE stacks are ready
  readySent, // We sent connectionReady
  readyComplete, // Both devices exchanged ready (response IS ack)
  // Phase 1: Identity exchange - exchange public keys and display names
  identitySent, // We sent identity
  identityComplete, // Both devices exchanged identity (response IS ack)
  // Phase 1.5: Noise Protocol XX Handshake - establish encrypted session
  noiseHandshake1Sent, // We sent Noise message 1 (-> e)
  noiseHandshake2Sent, // We sent Noise message 2 (<- e, ee, s, es)
  noiseHandshakeComplete, // Noise session established
  // Phase 2: Contact status sync - exchange relationship status
  contactStatusSent, // We sent contact status
  contactStatusComplete, // Both devices exchanged contact status (response IS ack)
  // Final state - handshake complete
  complete,

  // Error states
  timeout,
  failed,
}

/// Manages the handshake protocol between two BLE devices
/// Ensures no message proceeds without explicit confirmation
class HandshakeCoordinator {
  final Logger _logger;

  // State management
  ConnectionPhase _phase = ConnectionPhase.bleConnected;
  final Set<void Function(ConnectionPhase)> _phaseListeners = {};
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
  ConnectionPhase get currentPhase => _phase;
  final HandshakePeerState _peerState = HandshakePeerState();

  // Timeout management
  late final HandshakeTimeoutManager _timeoutManager;

  // Noise handshake state
  late final KKPatternTracker _kkTracker;
  late final NoiseHandshakeDriver _noiseDriver;

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
    );
    if (phaseTimeout != null) {
      _timeoutManager.phaseTimeout = phaseTimeout;
    }
    _isInitiator = startAsInitiator;
  }

  /// Start the handshake process
  /// This is the entry point - call this after BLE connection is established
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
      _isInitiator = false; // ← Mark as responder

      // Advance to ready complete FIRST (before sending)
      await _advanceToReadyComplete();

      // Then send response
      final response = ProtocolMessage.connectionReady(
        deviceId: _myPublicKey,
        deviceName: _myDisplayName,
      );
      await _sendWithGuard(response, 'connectionReady (ack)');
      return;
    }

    // CENTRAL FLOW: We sent first, they responded, advance
    if (_phase == ConnectionPhase.readySent) {
      _logger.info('✅ Central: Received their ready response - advancing');
      _isInitiator = true; // ← Mark as initiator
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

  Future<void> _advanceToNoiseHandshakeComplete() async {
    _logger.info('✅ Phase 1.5 Complete: Noise session established');
    _phase = ConnectionPhase.noiseHandshakeComplete;
    _emitPhase(_phase);

    // FIX-008: Wait for peer's static public key with retry logic
    // This prevents Phase 2 from starting before Noise session is fully ready
    try {
      await _waitForPeerNoiseKey(
        timeout: const Duration(seconds: 3),
        maxRetries: 5,
      );

      if (_peerState.theirNoisePublicKey != null) {
        _logger.info(
          '  Peer Noise public key: ${_peerState.theirNoisePublicKey!.shortId()}...',
        );
      } else {
        // Should never happen after successful wait, but handle defensively
        throw Exception('Peer Noise key is null after successful wait');
      }
    } catch (e) {
      _logger.severe('❌ Failed to retrieve peer Noise public key: $e');
      await _failHandshake(
        'Cannot proceed to Phase 2 without peer Noise public key: $e',
      );
      return;
    }

    // ✅ Only initiator (central) sends contactStatus first
    // Responder (peripheral) waits to receive it
    if (_isInitiator) {
      _logger.info('📤 Role: INITIATOR - proceeding to send contact status');
      await _advanceToContactStatusSent();
    } else {
      _logger.info('⏸️ Role: RESPONDER - waiting for contact status');
      _startPhaseTimeout('contactStatus');
    }
  }

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
  }) async {
    final startTime = DateTime.now();
    int attempt = 0;

    while (attempt < maxRetries) {
      attempt++;

      // Check if timeout exceeded
      final elapsed = DateTime.now().difference(startTime);
      if (elapsed > timeout) {
        throw TimeoutException(
          'Peer Noise key not available after ${timeout.inMilliseconds}ms',
          timeout,
        );
      }

      // Try to get peer key
      try {
        final noiseService = SecurityManager.instance.noiseService;
        if (noiseService == null) {
          _logger.warning(
            '⏳ Attempt $attempt/$maxRetries: Noise service not initialized',
          );
        } else {
          final peerKey = noiseService.getPeerPublicKeyData(
            _peerState.theirEphemeralId!,
          );

          if (peerKey != null) {
            // Success! Store key and return
            _peerState.setNoisePublicKey(base64.encode(peerKey));
            _logger.info(
              '✅ Retrieved peer Noise key on attempt $attempt/$maxRetries',
            );
            return;
          } else {
            _logger.fine(
              '⏳ Attempt $attempt/$maxRetries: Peer key not yet available',
            );
          }
        }
      } catch (e) {
        _logger.warning(
          '⏳ Attempt $attempt/$maxRetries: Exception retrieving key: $e',
        );
      }

      // Exponential backoff: 50ms, 100ms, 200ms, 400ms, 800ms
      final delayMs = 50 * (1 << (attempt - 1));
      await Future.delayed(Duration(milliseconds: delayMs));
    }

    // Failed after all retries
    throw TimeoutException(
      'Peer Noise key not available after $maxRetries retries',
      timeout,
    );
  }

  // ========== PHASE 2: CONTACT STATUS EXCHANGE ==========

  Future<void> _advanceToContactStatusSent() async {
    _logger.info('📤 Phase 2: Sending contact status');
    _phase = ConnectionPhase.contactStatusSent;
    _emitPhase(_phase);

    // SECURITY NOTE: We only have their ephemeral ID at this point.
    // Contact status will be determined AFTER pairing when we exchange persistent keys.
    // For now, always send false during handshake phase.
    final weHaveThem = false; // Will be checked after pairing

    final message = ProtocolMessage.contactStatus(
      hasAsContact: weHaveThem,
      publicKey: _myEphemeralId, // Send our ephemeral ID
    );

    await _sendWithGuard(message, 'contactStatus');
    _startPhaseTimeout('contactStatus');
  }

  Future<void> _handleContactStatus(ProtocolMessage message) async {
    _logger.info('📥 Received contactStatus');

    // Valid in: noiseHandshakeComplete (peripheral), contactStatusSent (central)
    if (_phase != ConnectionPhase.noiseHandshakeComplete &&
        _phase != ConnectionPhase.contactStatusSent) {
      _logger.warning('⚠️ Unexpected contactStatus in phase $_phase');
      return;
    }

    // Store their contact status (will be false during handshake, updated after pairing)
    _peerState.setContactStatus(message.payload['hasAsContact'] as bool);

    _logger.info(
      '  They have us as contact: ${_peerState.theyHaveUsAsContact} (may change after pairing)',
    );

    // NEW: Check for pattern mismatch (desync detection)
    if (_peerState.patternMismatchDetected && _repositoryProvider != null) {
      _logger.warning(
        '⚠️ DESYNC DETECTED: Pattern mismatch indicates data loss',
      );

      if (_peerState.theirNoisePublicKey != null) {
        try {
          final contact = await _repositoryProvider!.contactRepository
              .getContact(_peerState.theirNoisePublicKey!);

          if (contact != null && contact.securityLevel != SecurityLevel.low) {
            _logger.warning(
              '   Downgrading peer from ${contact.securityLevel} to LOW',
            );
            _logger.warning('   Peer may have reset device or lost data');

            // Downgrade contact security level
            await _repositoryProvider!.contactRepository
                .downgradeSecurityForDeletedContact(
                  _peerState.theirNoisePublicKey!,
                  'pattern_mismatch',
                );

            // Notify UI about security downgrade
            onSecurityDowngrade?.call(contact.displayName, 'pattern_mismatch');
          }
        } catch (e) {
          _logger.warning('⚠️ Failed to check/downgrade contact: $e');
        }
      }
    }

    // NEW: Check if we should notify about rejection
    if (_peerState.rejectionReason != null) {
      _logger.warning('🚨 Handshake required fallback to XX pattern');
      _logger.warning('   Reason: ${_peerState.rejectionReason}');

      // Notify UI about handshake fallback
      onHandshakeFallback?.call(_peerState.rejectionReason!);
    }

    // PERIPHERAL FLOW: We haven't sent yet, so send now (response IS ack)
    if (_phase == ConnectionPhase.noiseHandshakeComplete) {
      _logger.info(
        '🔄 Peripheral: Received contactStatus, sending our contactStatus (response IS ack)',
      );

      // SECURITY NOTE: We only have ephemeral IDs, so contact status is unknown
      final weHaveThem = false; // Will be checked after pairing

      final response = ProtocolMessage.contactStatus(
        hasAsContact: weHaveThem,
        publicKey: _myEphemeralId, // Send our ephemeral ID
      );
      await _sendWithGuard(response, 'contactStatus (ack)');

      // Advance to contact status complete, then complete handshake
      await _advanceToContactStatusComplete();
      return;
    }

    // CENTRAL FLOW: We sent first, they responded, advance
    if (_phase == ConnectionPhase.contactStatusSent) {
      _logger.info(
        '✅ Central: Received their contactStatus response - completing handshake',
      );
      await _advanceToContactStatusComplete();
      return;
    }
  }

  Future<void> _advanceToContactStatusComplete() async {
    _logger.info('✅ Phase 2 Complete: Contact status exchange done');
    _phase = ConnectionPhase.contactStatusComplete;
    _emitPhase(_phase);

    // Complete the handshake
    await _advanceToComplete();
  }

  // ========== HANDSHAKE COMPLETION ==========

  Future<void> _advanceToComplete() async {
    _logger.info(
      '🎉 HANDSHAKE COMPLETE! Session ready for normal communication',
    );
    _logger.info('   Their ephemeral ID: ${_peerState.theirEphemeralId}');
    _logger.info('   (Persistent keys will be exchanged after pairing)');
    _timeoutManager.cancelTimeout();

    _phase = ConnectionPhase.complete;
    _emitPhase(_phase);

    // Notify: Handshake complete (resume health checks)
    onHandshakeStateChanged?.call(false);

    if (_peerState.theirNoisePublicKey != null) {
      _kkTracker.reset(_peerState.theirNoisePublicKey!);
    }

    // Notify caller with their EPHEMERAL ID and Noise public key
    if (_peerState.theirEphemeralId != null &&
        _peerState.theirDisplayName != null) {
      await _onHandshakeComplete(
        _peerState.theirEphemeralId!,
        _peerState.theirDisplayName!,
        _peerState.theirNoisePublicKey,
      );

      // Record peer in network topology for visualization
      if (_peerState.theirNoisePublicKey != null) {
        try {
          TopologyManager.instance.recordNodeAnnouncement(
            nodeId: _peerState.theirNoisePublicKey!,
            displayName: _peerState.theirDisplayName!,
          );
          _logger.info(
            '📊 Recorded peer in topology: ${_peerState.theirDisplayName}',
          );
        } catch (e) {
          _logger.warning('⚠️ Failed to record topology: $e');
          // Non-critical error, continue with handshake completion
        }
      }

      // Trigger queue flush callback (for offline message delivery)
      if (onHandshakeSuccess != null) {
        _logger.info(
          '📤 Triggering queue flush for peer: ${_peerState.theirEphemeralId}',
        );
        await onHandshakeSuccess!(_peerState.theirEphemeralId!);
      }
    }
  }

  // ========== TIMEOUT & ERROR HANDLING ==========

  void _startPhaseTimeout(String waitingFor) {
    _timeoutManager.startTimeout(
      waitingFor: waitingFor,
      isComplete: () => _phase == ConnectionPhase.complete,
      onTimeout: (reason) => _failHandshake(reason),
    );
  }

  Future<void> _failHandshake(String reason) async {
    _logger.severe('❌ Handshake failed: $reason');
    _timeoutManager.cancelTimeout();

    _phase = ConnectionPhase.failed;
    _emitPhase(_phase);

    // Notify: Handshake failed (resume health checks)
    onHandshakeStateChanged?.call(false);
  }

  Future<void> _sendWithGuard(ProtocolMessage message, String context) async {
    try {
      await _sendMessage(message);
    } catch (e) {
      _logger.severe('❌ Failed to send $context: $e');
      await _failHandshake('Failed to send $context: $e');
      rethrow;
    }
  }

  // ========== KK PATTERN REJECTION HANDLING ==========

  /// Send rejection message when we can't do KK
  Future<void> _sendRejectionMessage({
    required String reason,
    required String attemptedPattern,
    required String suggestedPattern,
    Map<String, dynamic>? contactStatus,
  }) async {
    _logger.warning('📤 Sending handshake rejection: $reason');
    _logger.warning(
      '   Attempted: $attemptedPattern → Suggested: $suggestedPattern',
    );

    final message = ProtocolMessage.noiseHandshakeRejected(
      reason: reason,
      attemptedPattern: attemptedPattern,
      suggestedPattern: suggestedPattern,
      peerEphemeralId: _myEphemeralId,
      contactStatus: contactStatus,
    );

    await _sendWithGuard(message, 'noiseHandshakeRejected');
  }

  /// Handle rejection message from peer
  Future<void> _handleNoiseHandshakeRejected(ProtocolMessage message) async {
    final reason = message.noiseHandshakeRejectReason;
    final attemptedPattern = message.noiseHandshakeRejectAttemptedPattern;
    final suggestedPattern = message.noiseHandshakeRejectSuggestedPattern;
    final contactStatus = message.noiseHandshakeRejectContactStatus;

    _logger.warning('📥 Received handshake rejection');
    _logger.warning('   Reason: $reason');
    _logger.warning(
      '   Attempted: $attemptedPattern → Suggested: $suggestedPattern',
    );
    if (_peerState.attemptedPattern != null) {
      _logger.info(
        '   Local attempted pattern: ${_peerState.attemptedPattern!.name.toUpperCase()}',
      );
    }

    _peerState.markRejection(reason);

    // Track failure for downgrade logic
    if (_peerState.theirNoisePublicKey != null) {
      _kkTracker.recordFailure(
        _peerState.theirNoisePublicKey!,
        reason ?? 'unknown',
      );
    }

    // Check if peer lost data (they don't have us as contact)
    if (contactStatus != null) {
      final peerHasUs = contactStatus['haveThemAsContact'] as bool? ?? false;
      final shouldDowngrade =
          contactStatus['shouldDowngrade'] as bool? ?? false;

      if (!peerHasUs && shouldDowngrade) {
        _logger.warning('⚠️ PEER LOST DATA: They don\'t have us anymore');
        _logger.info(
          '   Will downgrade peer security after handshake completes',
        );
        _peerState.markPatternMismatch();
      }
    }

    // Retry with suggested pattern (XX)
    if (suggestedPattern == 'xx') {
      _logger.info('🔄 Retrying handshake with XX pattern');

      // Reset to identity complete and retry
      _phase = ConnectionPhase.identityComplete;
      _emitPhase(_phase);
      _peerState.markAttemptedPattern(NoisePattern.xx);

      await _advanceToNoiseHandshake1Sent();
    } else {
      _logger.severe('❌ Unknown suggested pattern: $suggestedPattern');
      await _failHandshake('Unsupported suggested pattern: $suggestedPattern');
    }
  }

  // ========== KK FAILURE TRACKING ==========

  // ========== CLEANUP ==========

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
}
