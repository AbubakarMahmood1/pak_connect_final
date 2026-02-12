part of 'handshake_coordinator.dart';

class _HandshakeCoordinatorPhase2Helper {
  _HandshakeCoordinatorPhase2Helper(this._owner);

  final HandshakeCoordinator _owner;

  Future<void> advanceToNoiseHandshakeComplete() async {
    _owner._logger.info('✅ Phase 1.5 Complete: Noise session established');
    _owner._phase = ConnectionPhase.noiseHandshakeComplete;
    _owner._emitPhase(_owner._phase);

    // FIX-008: Wait for peer's static public key with retry logic.
    try {
      await _owner._waitForPeerNoiseKey(
        timeout: const Duration(seconds: 3),
        maxRetries: 5,
      );

      if (_owner._peerState.theirNoisePublicKey != null) {
        _owner._logger.info(
          '  Peer Noise public key: ${_owner._peerState.theirNoisePublicKey!.shortId()}...',
        );
      } else {
        throw Exception('Peer Noise key is null after successful wait');
      }
    } catch (e) {
      _owner._logger.severe('❌ Failed to retrieve peer Noise public key: $e');
      await failHandshake(
        'Cannot proceed to Phase 2 without peer Noise public key: $e',
      );
      return;
    }

    if (_owner._isInitiator) {
      _owner._logger.info(
        '📤 Role: INITIATOR - proceeding to send contact status',
      );
      await _owner._advanceToContactStatusSent();
    } else {
      _owner._logger.info('⏸️ Role: RESPONDER - waiting for contact status');
      startPhaseTimeout('contactStatus');
    }
  }

  Future<void> waitForPeerNoiseKey({
    required Duration timeout,
    required int maxRetries,
  }) async {
    final startTime = DateTime.now();
    var attempt = 0;

    while (attempt < maxRetries) {
      attempt++;

      final elapsed = DateTime.now().difference(startTime);
      if (elapsed > timeout) {
        throw TimeoutException(
          'Peer Noise key not available after ${timeout.inMilliseconds}ms',
          timeout,
        );
      }

      try {
        final noiseService = SecurityManager.instance.noiseService;
        if (noiseService == null) {
          _owner._logger.warning(
            '⏳ Attempt $attempt/$maxRetries: Noise service not initialized',
          );
        } else {
          final peerKey = noiseService.getPeerPublicKeyData(
            _owner._peerState.theirEphemeralId!,
          );

          if (peerKey != null) {
            _owner._peerState.setNoisePublicKey(base64.encode(peerKey));
            _owner._logger.info(
              '✅ Retrieved peer Noise key on attempt $attempt/$maxRetries',
            );
            return;
          }
          _owner._logger.fine(
            '⏳ Attempt $attempt/$maxRetries: Peer key not yet available',
          );
        }
      } catch (e) {
        _owner._logger.warning(
          '⏳ Attempt $attempt/$maxRetries: Exception retrieving key: $e',
        );
      }

      final delayMs = 50 * (1 << (attempt - 1));
      await Future.delayed(Duration(milliseconds: delayMs));
    }

    throw TimeoutException(
      'Peer Noise key not available after $maxRetries retries',
      timeout,
    );
  }

  Future<void> advanceToContactStatusSent() async {
    _owner._logger.info('📤 Phase 2: Sending contact status');
    _owner._phase = ConnectionPhase.contactStatusSent;
    _owner._emitPhase(_owner._phase);

    // During handshake we only have ephemeral IDs, so status stays false.
    final message = ProtocolMessage.contactStatus(
      hasAsContact: false,
      publicKey: _owner._myEphemeralId,
    );

    await sendWithGuard(message, 'contactStatus');
    startPhaseTimeout('contactStatus');
  }

  Future<void> handleContactStatus(ProtocolMessage message) async {
    _owner._logger.info('📥 Received contactStatus');

    if (_owner._phase != ConnectionPhase.noiseHandshakeComplete &&
        _owner._phase != ConnectionPhase.contactStatusSent) {
      _owner._logger.warning(
        '⚠️ Unexpected contactStatus in phase ${_owner._phase}',
      );
      return;
    }

    _owner._peerState.setContactStatus(message.payload['hasAsContact'] as bool);

    _owner._logger.info(
      '  They have us as contact: ${_owner._peerState.theyHaveUsAsContact} (may change after pairing)',
    );

    if (_owner._peerState.patternMismatchDetected &&
        _owner._repositoryProvider != null) {
      _owner._logger.warning(
        '⚠️ DESYNC DETECTED: Pattern mismatch indicates data loss',
      );

      if (_owner._peerState.theirNoisePublicKey != null) {
        try {
          final contact = await _owner._repositoryProvider.contactRepository
              .getContact(_owner._peerState.theirNoisePublicKey!);

          if (contact != null && contact.securityLevel != SecurityLevel.low) {
            _owner._logger.warning(
              '   Downgrading peer from ${contact.securityLevel} to LOW',
            );
            _owner._logger.warning(
              '   Peer may have reset device or lost data',
            );

            await _owner._repositoryProvider.contactRepository
                .downgradeSecurityForDeletedContact(
                  _owner._peerState.theirNoisePublicKey!,
                  'pattern_mismatch',
                );
            _owner.onSecurityDowngrade?.call(
              contact.displayName,
              'pattern_mismatch',
            );
          }
        } catch (e) {
          _owner._logger.warning('⚠️ Failed to check/downgrade contact: $e');
        }
      }
    }

    if (_owner._peerState.rejectionReason != null) {
      _owner._logger.warning('🚨 Handshake required fallback to XX pattern');
      _owner._logger.warning('   Reason: ${_owner._peerState.rejectionReason}');
      _owner.onHandshakeFallback?.call(_owner._peerState.rejectionReason!);
    }

    if (_owner._phase == ConnectionPhase.noiseHandshakeComplete) {
      _owner._logger.info(
        '🔄 Peripheral: Received contactStatus, sending our contactStatus (response IS ack)',
      );
      final response = ProtocolMessage.contactStatus(
        hasAsContact: false,
        publicKey: _owner._myEphemeralId,
      );
      await sendWithGuard(response, 'contactStatus (ack)');
      await _owner._advanceToContactStatusComplete();
      return;
    }

    if (_owner._phase == ConnectionPhase.contactStatusSent) {
      _owner._logger.info(
        '✅ Central: Received their contactStatus response - completing handshake',
      );
      await _owner._advanceToContactStatusComplete();
    }
  }

  Future<void> advanceToContactStatusComplete() async {
    _owner._logger.info('✅ Phase 2 Complete: Contact status exchange done');
    _owner._phase = ConnectionPhase.contactStatusComplete;
    _owner._emitPhase(_owner._phase);
    await _owner._advanceToComplete();
  }

  Future<void> advanceToComplete() async {
    _owner._logger.info(
      '🎉 HANDSHAKE COMPLETE! Session ready for normal communication',
    );
    _owner._logger.info(
      '   Their ephemeral ID: ${_owner._peerState.theirEphemeralId}',
    );
    _owner._logger.info('   (Persistent keys will be exchanged after pairing)');
    _owner._timeoutManager.cancelTimeout();

    _owner._phase = ConnectionPhase.complete;
    _owner._emitPhase(_owner._phase);
    _owner.onHandshakeStateChanged?.call(false);

    if (_owner._peerState.theirNoisePublicKey != null) {
      _owner._kkTracker.reset(_owner._peerState.theirNoisePublicKey!);
    }

    if (_owner._peerState.theirEphemeralId != null &&
        _owner._peerState.theirDisplayName != null) {
      await _owner._onHandshakeComplete(
        _owner._peerState.theirEphemeralId!,
        _owner._peerState.theirDisplayName!,
        _owner._peerState.theirNoisePublicKey,
      );

      if (_owner._peerState.theirNoisePublicKey != null) {
        try {
          TopologyManager.instance.recordNodeAnnouncement(
            nodeId: _owner._peerState.theirNoisePublicKey!,
            displayName: _owner._peerState.theirDisplayName!,
          );
          _owner._logger.info(
            '📊 Recorded peer in topology: ${_owner._peerState.theirDisplayName}',
          );
        } catch (e) {
          _owner._logger.warning('⚠️ Failed to record topology: $e');
        }
      }

      if (_owner.onHandshakeSuccess != null) {
        _owner._logger.info(
          '📤 Triggering queue flush for peer: ${_owner._peerState.theirEphemeralId}',
        );
        await _owner.onHandshakeSuccess!(_owner._peerState.theirEphemeralId!);
      }
    }
  }

  void startPhaseTimeout(String waitingFor) {
    _owner._timeoutManager.startTimeout(
      waitingFor: waitingFor,
      isComplete: () => _owner._phase == ConnectionPhase.complete,
      onTimeout: (reason) => failHandshake(reason),
    );
  }

  Future<void> failHandshake(String reason) async {
    _owner._logger.severe('❌ Handshake failed: $reason');
    _owner._timeoutManager.cancelTimeout();

    _owner._phase = ConnectionPhase.failed;
    _owner._emitPhase(_owner._phase);
    _owner.onHandshakeStateChanged?.call(false);
  }

  Future<void> sendWithGuard(ProtocolMessage message, String context) async {
    try {
      await _owner._sendMessage(message);
    } catch (e) {
      _owner._logger.severe('❌ Failed to send $context: $e');
      await failHandshake('Failed to send $context: $e');
      rethrow;
    }
  }

  Future<void> sendRejectionMessage({
    required String reason,
    required String attemptedPattern,
    required String suggestedPattern,
    Map<String, dynamic>? contactStatus,
  }) async {
    _owner._logger.warning('📤 Sending handshake rejection: $reason');
    _owner._logger.warning(
      '   Attempted: $attemptedPattern → Suggested: $suggestedPattern',
    );

    final message = ProtocolMessage.noiseHandshakeRejected(
      reason: reason,
      attemptedPattern: attemptedPattern,
      suggestedPattern: suggestedPattern,
      peerEphemeralId: _owner._myEphemeralId,
      contactStatus: contactStatus,
    );

    await sendWithGuard(message, 'noiseHandshakeRejected');
  }

  Future<void> handleNoiseHandshakeRejected(ProtocolMessage message) async {
    final reason = message.noiseHandshakeRejectReason;
    final attemptedPattern = message.noiseHandshakeRejectAttemptedPattern;
    final suggestedPattern = message.noiseHandshakeRejectSuggestedPattern;
    final contactStatus = message.noiseHandshakeRejectContactStatus;

    _owner._logger.warning('📥 Received handshake rejection');
    _owner._logger.warning('   Reason: $reason');
    _owner._logger.warning(
      '   Attempted: $attemptedPattern → Suggested: $suggestedPattern',
    );
    if (_owner._peerState.attemptedPattern != null) {
      _owner._logger.info(
        '   Local attempted pattern: ${_owner._peerState.attemptedPattern!.name.toUpperCase()}',
      );
    }

    _owner._peerState.markRejection(reason);

    if (_owner._peerState.theirNoisePublicKey != null) {
      _owner._kkTracker.recordFailure(
        _owner._peerState.theirNoisePublicKey!,
        reason ?? 'unknown',
      );
    }

    if (contactStatus != null) {
      final peerHasUs = contactStatus['haveThemAsContact'] as bool? ?? false;
      final shouldDowngrade =
          contactStatus['shouldDowngrade'] as bool? ?? false;

      if (!peerHasUs && shouldDowngrade) {
        _owner._logger.warning(
          '⚠️ PEER LOST DATA: They don\'t have us anymore',
        );
        _owner._logger.info(
          '   Will downgrade peer security after handshake completes',
        );
        _owner._peerState.markPatternMismatch();
      }
    }

    if (suggestedPattern == 'xx') {
      _owner._logger.info('🔄 Retrying handshake with XX pattern');
      _owner._phase = ConnectionPhase.identityComplete;
      _owner._emitPhase(_owner._phase);
      _owner._peerState.markAttemptedPattern(NoisePattern.xx);
      await _owner._advanceToNoiseHandshake1Sent();
      return;
    }

    _owner._logger.severe('❌ Unknown suggested pattern: $suggestedPattern');
    await failHandshake('Unsupported suggested pattern: $suggestedPattern');
  }
}
