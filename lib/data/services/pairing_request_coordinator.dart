import 'dart:async';
import 'package:logging/logging.dart';
import '../../domain/models/identity_session_state.dart';
import 'package:pak_connect/domain/models/pairing_state.dart';
import '../../domain/models/protocol_message.dart';
import 'package:pak_connect/domain/services/security_service_locator.dart';
import '../../domain/services/ephemeral_key_manager.dart';
import 'pairing_service.dart';

/// Orchestrates pairing request/accept/cancel flows and timeout handling.
///
/// Keeps the timer/backoff and ProtocolMessage construction out of
/// PairingFlowController to reduce its surface area.
class PairingRequestCoordinator {
  PairingRequestCoordinator({
    required Logger logger,
    required PairingService pairingService,
    required IdentitySessionState identityState,
    required String? Function() myUserName,
    required String? Function() otherUserName,
    required PairingInfo? Function() getPairingState,
    required void Function(PairingInfo?) setPairingState,
    void Function(String ephemeralId, String displayName)? onRequestReceived,
    void Function(ProtocolMessage message)? onSendPairingRequest,
    void Function(ProtocolMessage message)? onSendPairingAccept,
    void Function(ProtocolMessage message)? onSendPairingCancel,
    void Function()? onPairingCancelled,
    void Function(String)? unregisterIdentityMapping,
  }) : _logger = logger,
       _pairingService = pairingService,
       _identityState = identityState,
       _myUserName = myUserName,
       _otherUserName = otherUserName,
       _getPairingState = getPairingState,
       _setPairingState = setPairingState,
       _onRequestReceived = onRequestReceived,
       _onSendPairingRequest = onSendPairingRequest,
       _onSendPairingAccept = onSendPairingAccept,
       _onSendPairingCancel = onSendPairingCancel,
       _onPairingCancelled = onPairingCancelled,
       _unregisterIdentityMapping = unregisterIdentityMapping;

  final Logger _logger;
  final PairingService _pairingService;
  final IdentitySessionState _identityState;
  final String? Function() _myUserName;
  final String? Function() _otherUserName;
  final PairingInfo? Function() _getPairingState;
  final void Function(PairingInfo?) _setPairingState;
  final void Function(String ephemeralId, String displayName)?
  _onRequestReceived;
  final void Function(ProtocolMessage message)? _onSendPairingRequest;
  final void Function(ProtocolMessage message)? _onSendPairingAccept;
  final void Function(ProtocolMessage message)? _onSendPairingCancel;
  final void Function()? _onPairingCancelled;
  final void Function(String)? _unregisterIdentityMapping;

  Timer? _pairingTimeout;

  void dispose() {
    _pairingTimeout?.cancel();
  }

  Future<void> sendPairingRequest({required String theirEphemeralId}) async {
    if (theirEphemeralId.isEmpty) {
      _logger.warning(
        '❌ Cannot send pairing request - no ephemeral ID (handshake incomplete)',
      );
      return;
    }

    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    if (myEphId.isEmpty) {
      _logger.warning(
        '❌ Cannot send pairing request - my ephemeral ID not set',
      );
      return;
    }

    _logger.info(
      '📤 STEP 3: Sending pairing request to ${_otherUserName() ?? "Unknown"}',
    );

    _pairingService.initiatePairingRequest(
      myEphemeralId: myEphId,
      displayName: _myUserName() ?? 'User',
    );

    _onSendPairingRequest?.call(
      ProtocolMessage.pairingRequest(
        ephemeralId: myEphId,
        displayName: _myUserName() ?? 'User',
      ),
    );

    _startTimeoutIfPending(PairingState.pairingRequested);
  }

  void handlePairingRequest(ProtocolMessage message) {
    final theirEphemeralId = message.payload['ephemeralId'] as String;
    final displayName = message.payload['displayName'] as String;

    _logger.info('📥 STEP 3: Received pairing request from $displayName');
    _logger.info('   Their ephemeral ID: $theirEphemeralId');

    _identityState.theirEphemeralId ??= theirEphemeralId;

    if (_identityState.theirEphemeralId != theirEphemeralId) {
      _logger.warning(
        '⚠️ Ephemeral ID mismatch! Handshake: ${_identityState.theirEphemeralId}, Request: $theirEphemeralId',
      );
      _identityState.theirEphemeralId = theirEphemeralId;
    }

    _pairingService.receivePairingRequest(
      theirEphemeralId: theirEphemeralId,
      displayName: displayName,
    );

    _logger.info('🔔 Triggering pairing request popup for user');
    _onRequestReceived?.call(theirEphemeralId, displayName);
  }

  Future<void> acceptPairingRequest() async {
    if (_getPairingState()?.state != PairingState.requestReceived) {
      _logger.warning('❌ No pending pairing request to accept');
      return;
    }

    final myEphId = EphemeralKeyManager.generateMyEphemeralKey();
    if (myEphId.isEmpty) {
      _logger.warning('❌ Cannot accept - my ephemeral ID not set');
      return;
    }

    _logger.info('✅ STEP 3: User accepted pairing request');

    _pairingService.acceptIncomingRequest(
      myEphemeralId: myEphId,
      displayName: _myUserName() ?? 'User',
    );

    _onSendPairingAccept?.call(
      ProtocolMessage.pairingAccept(
        ephemeralId: myEphId,
        displayName: _myUserName() ?? 'User',
      ),
    );
  }

  Future<void> rejectPairingRequest() async {
    _logger.info('❌ STEP 3: User rejected pairing request');
    _pairingService.rejectIncomingRequest();

    _onSendPairingCancel?.call(
      ProtocolMessage.pairingCancel(reason: 'User rejected pairing'),
    );
    _setPairingState(null);
    _pairingTimeout?.cancel();
  }

  void handlePairingAccept(ProtocolMessage message) {
    final theirEphemeralId = message.payload['ephemeralId'] as String;
    final displayName = message.payload['displayName'] as String;

    _logger.info('📥 STEP 3: Received pairing accept from $displayName');

    _pairingService.receivePairingAccept(
      theirEphemeralId: theirEphemeralId,
      displayName: displayName,
    );

    _pairingTimeout?.cancel();
    _setPairingState(
      _getPairingState()?.copyWith(
        state: PairingState.displaying,
        theirEphemeralId: theirEphemeralId,
        theirDisplayName: displayName,
      ),
    );

    _logger.info('✅ Pairing accepted, showing PIN dialog');
  }

  void handlePairingCancel(ProtocolMessage message) {
    final reason = message.payload['reason'] as String?;
    _logger.info(
      '❌ STEP 3: Pairing cancelled by other device${reason != null ? ": $reason" : ""}',
    );

    _pairingService.receivePairingCancel(reason: reason);
    final theirPersistent = _identityState.theirPersistentKey;
    if (theirPersistent != null) {
      SecurityServiceLocator.instance.unregisterIdentityMapping(
        theirPersistent,
      );
      _unregisterIdentityMapping?.call(theirPersistent);
      _logger.info(
        '🔐 Unregistered identity mapping due to pairing cancellation',
      );
    }

    _setPairingState(
      _getPairingState()?.copyWith(state: PairingState.cancelled),
    );
    _pairingTimeout?.cancel();

    _onPairingCancelled?.call();

    Future.delayed(Duration(seconds: 1), () {
      _setPairingState(null);
    });
  }

  Future<void> cancelPairing({String? reason}) async {
    if (_getPairingState() == null) {
      _logger.info('No active pairing to cancel');
      return;
    }

    _logger.info(
      '🚫 STEP 3: Cancelling pairing${reason != null ? ": $reason" : ""}',
    );

    final theirPersistent = _identityState.theirPersistentKey;
    if (theirPersistent != null) {
      SecurityServiceLocator.instance.unregisterIdentityMapping(
        theirPersistent,
      );
      _unregisterIdentityMapping?.call(theirPersistent);
      _logger.info('🔐 Unregistered identity mapping due to user cancellation');
    }

    final message = ProtocolMessage.pairingCancel(
      reason: reason ?? 'User cancelled',
    );
    _onSendPairingCancel?.call(message);

    _setPairingState(
      _getPairingState()?.copyWith(state: PairingState.cancelled),
    );
    _pairingTimeout?.cancel();

    Future.delayed(Duration(seconds: 1), () {
      _setPairingState(null);
    });
  }

  void _startTimeoutIfPending(PairingState expectedState) {
    _pairingTimeout?.cancel();
    _pairingTimeout = Timer(Duration(seconds: 30), () {
      if (_getPairingState()?.state == expectedState) {
        _logger.warning('⏰ Pairing request timeout - no response');
        _setPairingState(
          _getPairingState()?.copyWith(state: PairingState.failed),
        );
        _onPairingCancelled?.call();
      }
    });
  }
}
