import 'dart:async';
import 'package:logging/logging.dart';
import 'package:pak_connect/core/models/protocol_message.dart';

/// Connection phases for the sequential handshake protocol
/// Response IS the acknowledgment (no separate ACK messages)
enum ConnectionPhase {
  // Initial state - BLE connected but handshake not started
  bleConnected,

  // Phase 0: Ready check - ensure both devices' BLE stacks are ready
  readySent,           // We sent connectionReady
  readyComplete,       // Both devices exchanged ready (response IS ack)

  // Phase 1: Identity exchange - exchange public keys and display names
  identitySent,        // We sent identity
  identityComplete,    // Both devices exchanged identity (response IS ack)

  // Phase 2: Contact status sync - exchange relationship status
  contactStatusSent,   // We sent contact status
  contactStatusComplete,   // Both devices exchanged contact status (response IS ack)

  // Final state - handshake complete
  complete,

  // Error states
  timeout,
  failed,
}

/// Manages the handshake protocol between two BLE devices
/// Ensures no message proceeds without explicit confirmation
class HandshakeCoordinator {
  final Logger _logger = Logger('[HandshakeCoordinator]');

  // State management
  ConnectionPhase _phase = ConnectionPhase.bleConnected;
  final _phaseController = StreamController<ConnectionPhase>.broadcast();
  Stream<ConnectionPhase> get phaseStream => _phaseController.stream;
  ConnectionPhase get currentPhase => _phase;

  // Timeout management
  Timer? _timeoutTimer;
  Duration _phaseTimeout = const Duration(seconds: 10);

  // Message pending confirmation
  final Map<ProtocolMessageType, Completer<void>> _pendingAcks = {};

  // Received data storage
  String? _theirEphemeralId;  // Their ephemeral ID (from handshake)
  String? _theirDisplayName;
  bool? _theyHaveUsAsContact;

  // Our data
  final String _myEphemeralId;  // Our ephemeral ID (sent during handshake)
  final String _myPublicKey;     // Our persistent key (kept private until pairing)
  final String _myDisplayName;

  // Callbacks for sending messages
  final Future<void> Function(ProtocolMessage) _sendMessage;
  final Future<void> Function(String, String) _onHandshakeComplete;

  HandshakeCoordinator({
    required String myEphemeralId,
    required String myPublicKey,
    required String myDisplayName,
    required Future<void> Function(ProtocolMessage) sendMessage,
    required Future<void> Function(String ephemeralId, String displayName) onHandshakeComplete,
    Duration? phaseTimeout,
  }) : _myEphemeralId = myEphemeralId,
       _myPublicKey = myPublicKey,
       _myDisplayName = myDisplayName,
       _sendMessage = sendMessage,
       _onHandshakeComplete = onHandshakeComplete {
    if (phaseTimeout != null) {
      _phaseTimeout = phaseTimeout;
    }
  }

  /// Start the handshake process
  /// This is the entry point - call this after BLE connection is established
  Future<void> startHandshake() async {
    _logger.info('🤝 Starting handshake protocol from phase: $_phase');

    if (_phase != ConnectionPhase.bleConnected) {
      _logger.warning('⚠️ Handshake already in progress or complete');
      return;
    }

    await _advanceToReadySent();
  }

  /// Handle received protocol messages
  /// Routes messages based on current phase and type
  Future<void> handleReceivedMessage(ProtocolMessage message) async {
    _logger.info('📨 Received ${message.type} in phase $_phase');

    // Cancel timeout when we receive expected message
    _timeoutTimer?.cancel();

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

        // Phase 2: Contact status
        case ProtocolMessageType.contactStatus:
          await _handleContactStatus(message);
          break;

        default:
          _logger.warning('⚠️ Unexpected message type ${message.type} in phase $_phase');
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
    _phaseController.add(_phase);

    final message = ProtocolMessage.connectionReady(
      deviceId: _myPublicKey,
      deviceName: _myDisplayName,
    );

    await _sendMessage(message);
    _startPhaseTimeout('connectionReadyAck');
  }

  Future<void> _handleConnectionReady(ProtocolMessage message) async {
    _logger.info('📥 Received connectionReady');

    // Valid in: bleConnected (peripheral), readySent (central)
    if (_phase != ConnectionPhase.bleConnected && _phase != ConnectionPhase.readySent) {
      _logger.warning('⚠️ Unexpected connectionReady in phase $_phase');
      return;
    }

    // PERIPHERAL FLOW: We haven't sent yet, so send now (response IS ack)
    if (_phase == ConnectionPhase.bleConnected) {
      _logger.info('🔄 Peripheral: Received ready, sending our ready (response IS ack)');

      final response = ProtocolMessage.connectionReady(
        deviceId: _myPublicKey,
        deviceName: _myDisplayName,
      );
      await _sendMessage(response);

      // Advance to ready complete
      await _advanceToReadyComplete();
      return;
    }

    // CENTRAL FLOW: We sent first, they responded, advance
    if (_phase == ConnectionPhase.readySent) {
      _logger.info('✅ Central: Received their ready response - advancing');
      await _advanceToReadyComplete();
      return;
    }
  }

  Future<void> _advanceToReadyComplete() async {
    _logger.info('✅ Phase 0 Complete: Both devices ready');
    _phase = ConnectionPhase.readyComplete;
    _phaseController.add(_phase);

    // Proceed to identity exchange
    await _advanceToIdentitySent();
  }

  // ========== PHASE 1: IDENTITY EXCHANGE ==========

  Future<void> _advanceToIdentitySent() async {
    _logger.info('📤 Phase 1: Sending identity (ephemeral ID only - privacy-preserving)');
    _phase = ConnectionPhase.identitySent;
    _phaseController.add(_phase);

    // SECURITY: Send ephemeral ID, NOT persistent public key
    // Persistent keys are only exchanged AFTER pairing succeeds
    final message = ProtocolMessage.identity(
      publicKey: _myEphemeralId,  // ← Ephemeral ID (privacy-preserving)
      displayName: _myDisplayName,
    );

    await _sendMessage(message);
    _startPhaseTimeout('identity');
  }

  Future<void> _handleIdentity(ProtocolMessage message) async {
    _logger.info('📥 Received identity (ephemeral ID)');

    // Valid in: readyComplete (peripheral), identitySent (central)
    if (_phase != ConnectionPhase.readyComplete && _phase != ConnectionPhase.identitySent) {
      _logger.warning('⚠️ Unexpected identity in phase $_phase');
      return;
    }

    // Store their EPHEMERAL identity (not persistent key!)
    _theirEphemeralId = message.identityPublicKey;  // This is their ephemeral ID
    _theirDisplayName = message.identityDisplayName;

    // Log ephemeral ID (it's already short, typically 8 chars)
    _logger.info('  Their ephemeral ID: $_theirEphemeralId');
    _logger.info('  Their display name: $_theirDisplayName');

    // PERIPHERAL FLOW: We haven't sent yet, so send now (response IS ack)
    if (_phase == ConnectionPhase.readyComplete) {
      _logger.info('🔄 Peripheral: Received identity, sending our identity (response IS ack)');

      final response = ProtocolMessage.identity(
        publicKey: _myEphemeralId,  // ← Send ephemeral ID
        displayName: _myDisplayName,
      );
      await _sendMessage(response);

      // Advance to identity complete
      await _advanceToIdentityComplete();
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
    _phaseController.add(_phase);

    // Proceed to contact status exchange
    await _advanceToContactStatusSent();
  }

  // ========== PHASE 2: CONTACT STATUS EXCHANGE ==========

  Future<void> _advanceToContactStatusSent() async {
    _logger.info('📤 Phase 2: Sending contact status');
    _phase = ConnectionPhase.contactStatusSent;
    _phaseController.add(_phase);

    // SECURITY NOTE: We only have their ephemeral ID at this point.
    // Contact status will be determined AFTER pairing when we exchange persistent keys.
    // For now, always send false during handshake phase.
    final weHaveThem = false;  // Will be checked after pairing

    final message = ProtocolMessage.contactStatus(
      hasAsContact: weHaveThem,
      publicKey: _myEphemeralId,  // Send our ephemeral ID
    );

    await _sendMessage(message);
    _startPhaseTimeout('contactStatus');
  }

  Future<void> _handleContactStatus(ProtocolMessage message) async {
    _logger.info('📥 Received contactStatus');

    // Valid in: identityComplete (peripheral), contactStatusSent (central)
    if (_phase != ConnectionPhase.identityComplete && _phase != ConnectionPhase.contactStatusSent) {
      _logger.warning('⚠️ Unexpected contactStatus in phase $_phase');
      return;
    }

    // Store their contact status (will be false during handshake, updated after pairing)
    _theyHaveUsAsContact = message.payload['hasAsContact'] as bool;

    _logger.info('  They have us as contact: $_theyHaveUsAsContact (may change after pairing)');

    // PERIPHERAL FLOW: We haven't sent yet, so send now (response IS ack)
    if (_phase == ConnectionPhase.identityComplete) {
      _logger.info('🔄 Peripheral: Received contactStatus, sending our contactStatus (response IS ack)');

      // SECURITY NOTE: We only have ephemeral IDs, so contact status is unknown
      final weHaveThem = false;  // Will be checked after pairing

      final response = ProtocolMessage.contactStatus(
        hasAsContact: weHaveThem,
        publicKey: _myEphemeralId,  // Send our ephemeral ID
      );
      await _sendMessage(response);

      // Advance to contact status complete, then complete handshake
      await _advanceToContactStatusComplete();
      return;
    }

    // CENTRAL FLOW: We sent first, they responded, advance
    if (_phase == ConnectionPhase.contactStatusSent) {
      _logger.info('✅ Central: Received their contactStatus response - completing handshake');
      await _advanceToContactStatusComplete();
      return;
    }
  }

  Future<void> _advanceToContactStatusComplete() async {
    _logger.info('✅ Phase 2 Complete: Contact status exchange done');
    _phase = ConnectionPhase.contactStatusComplete;
    _phaseController.add(_phase);

    // Complete the handshake
    await _advanceToComplete();
  }

  // ========== HANDSHAKE COMPLETION ==========

  Future<void> _advanceToComplete() async {
    _logger.info('🎉 HANDSHAKE COMPLETE! Session ready for normal communication');
    _logger.info('   Their ephemeral ID: $_theirEphemeralId');
    _logger.info('   (Persistent keys will be exchanged after pairing)');
    _timeoutTimer?.cancel();

    _phase = ConnectionPhase.complete;
    _phaseController.add(_phase);

    // Notify caller with their EPHEMERAL ID
    if (_theirEphemeralId != null && _theirDisplayName != null) {
      await _onHandshakeComplete(_theirEphemeralId!, _theirDisplayName!);
    }
  }

  // ========== TIMEOUT & ERROR HANDLING ==========

  void _startPhaseTimeout(String waitingFor) {
    _timeoutTimer?.cancel();
    _timeoutTimer = Timer(_phaseTimeout, () {
      _logger.warning('⏱️ Phase timeout waiting for: $waitingFor');
      _failHandshake('Timeout waiting for $waitingFor');
    });
  }

  Future<void> _failHandshake(String reason) async {
    _logger.severe('❌ Handshake failed: $reason');
    _timeoutTimer?.cancel();

    _phase = ConnectionPhase.failed;
    _phaseController.add(_phase);
  }

  // ========== CLEANUP ==========

  void dispose() {
    _timeoutTimer?.cancel();
    _phaseController.close();
    _pendingAcks.clear();
  }

  // ========== GETTERS ==========

  String? get theirEphemeralId => _theirEphemeralId;
  String? get theirDisplayName => _theirDisplayName;
  String get myPersistentKey => _myPublicKey;  // Accessor for pairing phase
  bool? get theyHaveUsAsContact => _theyHaveUsAsContact;
  bool get isComplete => _phase == ConnectionPhase.complete;
  bool get hasFailed => _phase == ConnectionPhase.failed || _phase == ConnectionPhase.timeout;
}
