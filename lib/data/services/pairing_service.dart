import 'dart:async';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import '../../core/interfaces/i_pairing_service.dart';
import '../../core/models/pairing_state.dart';
import '../../core/models/protocol_message.dart';
import '../../core/utils/string_extensions.dart';

/// Pairing Service
///
/// Manages PIN code exchange and verification:
/// - Generate random 4-digit PIN codes
/// - Exchange codes between devices
/// - Verify codes match
/// - Compute shared secrets
/// - Emit events for UI and state coordinator
class PairingService implements IPairingService {
  final _logger = Logger('PairingService');

  // ============================================================================
  // PAIRING STATE
  // ============================================================================

  /// Current pairing state machine
  PairingInfo? _currentPairing;

  /// Our code entered by the user
  String? _receivedPairingCode;

  /// Their code received from peer device
  String? _theirReceivedCode;

  /// Flag: whether user has entered the peer's code
  bool _weEnteredCode = false;

  /// Completer for pairing verification result
  Completer<bool>? _pairingCompleter;

  /// Timeout timer for pairing session (60 seconds)
  Timer? _pairingTimeout;

  // ============================================================================
  // CALLBACKS (Events to UI/Coordinator)
  // ============================================================================

  @override
  void Function(String code)? onSendPairingCode;

  @override
  void Function(String verificationHash)? onSendPairingVerification;

  @override
  void Function()? onPairingRequestReceived;

  @override
  void Function()? onPairingCancelled;

  /// Callbacks for signalling protocol messages outward
  void Function(ProtocolMessage message)? onSendPairingRequest;
  void Function(ProtocolMessage message)? onSendPairingAccept;
  void Function(ProtocolMessage message)? onSendPairingCancel;

  void _startRequestTimeout() {
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(Duration(seconds: 30), () {
      if (_currentPairing?.state == PairingState.pairingRequested) {
        _logger.warning('⏰ Pairing request timeout - no response');
        _currentPairing = _currentPairing!.copyWith(state: PairingState.failed);
        onPairingCancelled?.call();
      }
    });
  }

  @override
  void initiatePairingRequest({
    required String myEphemeralId,
    required String displayName,
  }) {
    _currentPairing = PairingInfo(
      myCode: '',
      state: PairingState.pairingRequested,
      theirEphemeralId: null,
      theirDisplayName: null,
    );

    final message = ProtocolMessage.pairingRequest(
      ephemeralId: myEphemeralId,
      displayName: displayName,
    );

    onSendPairingRequest?.call(message);
    _startRequestTimeout();
  }

  @override
  void receivePairingRequest({
    required String theirEphemeralId,
    required String displayName,
  }) {
    _currentPairing = PairingInfo(
      myCode: '',
      state: PairingState.requestReceived,
      theirEphemeralId: theirEphemeralId,
      theirDisplayName: displayName,
    );
    onPairingRequestReceived?.call();
  }

  @override
  void acceptIncomingRequest({
    required String myEphemeralId,
    required String displayName,
  }) {
    if (_currentPairing?.state != PairingState.requestReceived) {
      _logger.warning('❌ No pending pairing request to accept');
      return;
    }

    final message = ProtocolMessage.pairingAccept(
      ephemeralId: myEphemeralId,
      displayName: displayName,
    );
    onSendPairingAccept?.call(message);

    final code = generatePairingCode();
    _logger.info('📱 Generated PIN code after accept: $code');

    _currentPairing = _currentPairing!.copyWith(state: PairingState.displaying);
  }

  @override
  void rejectIncomingRequest() {
    final message = ProtocolMessage.pairingCancel(
      reason: 'User rejected pairing',
    );
    onSendPairingCancel?.call(message);
    clearPairing();
  }

  @override
  void receivePairingAccept({
    required String theirEphemeralId,
    required String displayName,
  }) {
    if (_currentPairing?.state != PairingState.pairingRequested) {
      _logger.warning('⚠️ Received accept but we didn\'t send a request');
      return;
    }

    _pairingTimeout?.cancel();

    final code = generatePairingCode();
    _logger.info('📱 Generated PIN code after receiving accept: $code');

    _currentPairing = _currentPairing!.copyWith(
      state: PairingState.displaying,
      theirEphemeralId: theirEphemeralId,
      theirDisplayName: displayName,
    );
  }

  @override
  void receivePairingCancel({String? reason}) {
    _logger.info(
      '❌ STEP 3: Pairing cancelled by other device${reason != null ? ": $reason" : ""}',
    );

    _pairingTimeout?.cancel();
    _currentPairing = _currentPairing?.copyWith(state: PairingState.cancelled);
    onPairingCancelled?.call();

    Future.delayed(Duration(seconds: 1), clearPairing);
  }

  // ============================================================================
  // DEPENDENCIES (Injected for testability)
  // ============================================================================

  /// Callback to get our persistent ID (injected)
  final Future<String> Function() getMyPersistentId;

  /// Callback to get their session ID (injected)
  final String? Function() getTheirSessionId;

  /// Callback to get their display name (injected)
  final String? Function() getTheirDisplayName;

  /// Callback to handle post-verification steps (injected)
  /// This is called after shared secret is computed
  /// Responsible for: contact upgrading, chat migration, persistent key exchange
  final Future<void> Function(
    String theirId,
    String sharedSecret,
    String? displayName,
  )?
  onVerificationComplete;

  /// Callback when verification fails (hash mismatch or missing data)
  final Future<void> Function(String reason)? onVerificationFailure;

  // ============================================================================
  // CONSTRUCTOR
  // ============================================================================

  PairingService({
    required this.getMyPersistentId,
    required this.getTheirSessionId,
    required this.getTheirDisplayName,
    this.onVerificationComplete,
    this.onVerificationFailure,
  });

  // ============================================================================
  // PAIRING CODE GENERATION
  // ============================================================================

  @override
  String generatePairingCode() {
    // If we already have a pairing code being displayed, return it
    if (_currentPairing != null &&
        _currentPairing!.state == PairingState.displaying) {
      _logger.info(
        'Returning existing pairing code: ${_currentPairing!.myCode}',
      );
      return _currentPairing!.myCode;
    }

    // Generate new random 4-digit code (1000-9999)
    final random = Random();
    final code = (random.nextInt(9000) + 1000).toString();
    _logger.info('Generated new pairing code: $code');

    // Initialize pairing state
    _currentPairing = PairingInfo(myCode: code, state: PairingState.displaying);

    // Reset pairing progress trackers
    _receivedPairingCode = null;
    _theirReceivedCode = null;
    _weEnteredCode = false;
    _pairingCompleter = Completer<bool>();

    // Set 60-second timeout for this pairing session
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(Duration(seconds: 60), () {
      if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
        _pairingCompleter!.complete(false);
        _logger.warning('⏱️ Pairing timeout after 60 seconds');
      }
    });

    return code;
  }

  // ============================================================================
  // PAIRING CODE COMPLETION (User enters peer's code)
  // ============================================================================

  @override
  Future<void> completePairing(String theirCode) async {
    try {
      if (_currentPairing == null) {
        _logger.warning('❌ No pairing in progress');
        return;
      }

      _logger.info('User entered peer code: $theirCode');

      // Mark that we've entered their code
      _weEnteredCode = true;
      _receivedPairingCode = theirCode;

      // Update pairing state to "verifying"
      _currentPairing = _currentPairing!.copyWith(
        theirCode: theirCode,
        state: PairingState.verifying,
      );

      // Send our code to peer (so they know we're ready)
      _logger.info('📤 Sending our code to peer: ${_currentPairing!.myCode}');
      await _sendPairingCode(_currentPairing!.myCode);

      // If peer already sent their code, verify immediately
      if (_theirReceivedCode != null) {
        _logger.info(
          '✅ Peer code already received, proceeding to verification',
        );
        final success = await _performVerification();
        if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
          _pairingCompleter!.complete(success);
        }
      } else {
        _logger.info('⏳ Waiting for peer to send their code...');

        // Reset completer if needed
        if (_pairingCompleter == null || _pairingCompleter!.isCompleted) {
          _pairingCompleter = Completer<bool>();
        }

        // Wait for peer's code (with timeout)
        // Note: handleReceivedPairingCode will complete this when code arrives
      }
    } catch (e) {
      _logger.severe('❌ Pairing completion failed: $e');
      _currentPairing = _currentPairing?.copyWith(state: PairingState.failed);
      if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
        _pairingCompleter!.complete(false);
      }
    }
  }

  // ============================================================================
  // HANDLE RECEIVED CODES (From peer device)
  // ============================================================================

  @override
  void handleReceivedPairingCode(String theirCode) {
    try {
      _logger.info('📥 Received peer code: $theirCode');

      // Store their code
      _theirReceivedCode = theirCode;

      // If we haven't entered our code yet, just store theirs and wait
      if (!_weEnteredCode || _receivedPairingCode == null) {
        _logger.fine('ℹ️ Waiting for user to enter peer code');
        return;
      }

      // Both sides have entered codes - verify they match!
      _logger.info('🔍 Both sides ready, comparing codes...');
      if (theirCode != _receivedPairingCode) {
        _logger.severe(
          '❌ CODE MISMATCH! User entered: $_receivedPairingCode, Peer sent: $theirCode',
        );
        if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
          _pairingCompleter!.complete(false);
        }
        return;
      }

      // Codes match! Proceed to verification
      _logger.info('✅ Codes match! Performing verification...');
      _performVerification()
          .then((success) {
            if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
              _pairingCompleter!.complete(success);
            }
          })
          .catchError((e) {
            _logger.severe('Verification error: $e');
            if (_pairingCompleter != null && !_pairingCompleter!.isCompleted) {
              _pairingCompleter!.complete(false);
            }
          });
    } catch (e) {
      _logger.severe('❌ Error handling received code: $e');
    }
  }

  // ============================================================================
  // VERIFICATION (Compute shared secret)
  // ============================================================================

  Future<bool> _performVerification() async {
    try {
      // Validation: must have all required data
      if (_currentPairing == null ||
          _receivedPairingCode == null ||
          _theirReceivedCode == null) {
        _logger.warning('❌ Missing data for verification');
        return false;
      }

      _logger.info('🔐 Starting verification...');

      // Get IDs for shared secret computation
      final myId = await getMyPersistentId();
      final theirId = getTheirSessionId();

      if (theirId == null) {
        _logger.warning('❌ Missing peer ID for verification');
        return false;
      }

      // Compute shared secret deterministically
      // Both devices sort codes and keys to ensure same result
      final sortedCodes = [_currentPairing!.myCode, _receivedPairingCode!]
        ..sort();
      final sortedIds = [myId, theirId]..sort();

      final combinedData =
          '${sortedCodes[0]}:${sortedCodes[1]}:${sortedIds[0]}:${sortedIds[1]}';
      final sharedSecret = sha256.convert(combinedData.codeUnits).toString();

      _logger.info('✅ Shared secret computed');

      // Update pairing state with shared secret
      _currentPairing = _currentPairing!.copyWith(
        state: PairingState.completed,
        sharedSecret: sharedSecret,
      );

      // Generate verification hash for confirmation
      final secretHash = sha256.convert(sharedSecret.codeUnits).toString();
      _logger.info('📤 Sending verification hash: ${secretHash.shortId(8)}...');

      // Send verification hash to peer
      await _sendPairingVerification(secretHash);

      // Call post-verification handler if provided
      if (onVerificationComplete != null) {
        final displayName = getTheirDisplayName();
        await onVerificationComplete!(theirId, sharedSecret, displayName);
      }

      _logger.info('✅ Pairing verification complete!');
      return true;
    } catch (e) {
      _logger.severe('❌ Verification failed: $e');
      _currentPairing = _currentPairing?.copyWith(state: PairingState.failed);
      return false;
    }
  }

  // ============================================================================
  // HANDLE VERIFICATION HASH (From peer)
  // ============================================================================

  @override
  Future<void> handlePairingVerification(String theirSecretHash) async {
    try {
      _logger.info(
        '📥 Received verification hash from peer: ${theirSecretHash.shortId(8)}...',
      );

      // Verify our hash matches theirs (if we have computed secret)
      if (_currentPairing != null && _currentPairing!.sharedSecret != null) {
        final ourHash = sha256
            .convert(_currentPairing!.sharedSecret!.codeUnits)
            .toString();

        if (ourHash == theirSecretHash) {
          _logger.info('✅ Verification hashes match - pairing confirmed!');
        } else {
          _logger.severe('❌ Hash mismatch - verification failed!');
          await onVerificationFailure?.call('verification hash mismatch');
        }
      } else {
        _logger.warning('⚠️ No shared secret to compare against');
        await onVerificationFailure?.call('missing shared secret');
      }
    } catch (e) {
      _logger.severe('❌ Error handling verification: $e');
      await onVerificationFailure?.call('verification exception');
    }
  }

  // ============================================================================
  // PAIRING STATE CLEANUP
  // ============================================================================

  @override
  void clearPairing() {
    try {
      _logger.info('🧹 Clearing pairing state');
      _currentPairing = null;
      _receivedPairingCode = null;
      _theirReceivedCode = null;
      _weEnteredCode = false;
      _pairingCompleter = null;
      _pairingTimeout?.cancel();
      _pairingTimeout = null;
    } catch (e) {
      _logger.warning('Error clearing pairing: $e');
    }
  }

  // ============================================================================
  // HELPER METHODS (Private wrappers around callbacks)
  // ============================================================================

  /// Send our pairing code to peer via callback
  Future<void> _sendPairingCode(String code) async {
    try {
      onSendPairingCode?.call(code);
    } catch (e) {
      _logger.warning('Failed to send pairing code: $e');
    }
  }

  /// Send verification hash to peer via callback
  Future<void> _sendPairingVerification(String hash) async {
    try {
      onSendPairingVerification?.call(hash);
    } catch (e) {
      _logger.warning('Failed to send verification hash: $e');
    }
  }

  // ============================================================================
  // STATE QUERIES (Getters)
  // ============================================================================

  @override
  PairingInfo? get currentPairing => _currentPairing;

  @override
  String? get theirReceivedCode => _theirReceivedCode;

  @override
  bool get weEnteredCode => _weEnteredCode;

  /// Allows orchestration layers to seed or update the pairing state machine.
  void setCurrentPairing(PairingInfo? pairingInfo) {
    _currentPairing = pairingInfo;
  }

  // ============================================================================
  // CLEANUP (Dispose)
  // ============================================================================

  void dispose() {
    _logger.fine('Disposing PairingService');
    _pairingTimeout?.cancel();
    _pairingCompleter = null;
  }
}
