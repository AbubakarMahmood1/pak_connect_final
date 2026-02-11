part of 'ble_state_manager.dart';

class _BleStateManagerSessionHelper {
  _BleStateManagerSessionHelper(this._owner);

  final BLEStateManager _owner;

  void setPeripheralMode(bool isPeripheral) {
    // ✅ DUAL-ROLE: In dual-role architecture, this tracks active connection type
    // (peripheral connection vs central connection), not device operating mode
    // Device is always BOTH peripheral (advertising) and central (scanning) simultaneously
    _owner._isPeripheralMode = isPeripheral;

    // ✅ REMOVED CONFUSING LOG: No need to log "mode switch" in dual-role architecture
    // Ephemeral ID regeneration is handled by EphemeralKeyManager on session lifecycle
  }

  String truncateId(String? id, {int maxLength = 16}) {
    if (id == null) return 'null';
    if (id.length <= maxLength) return id;
    return '${id.substring(0, maxLength)}...';
  }

  void clearSessionState({bool preservePersistentId = false}) {
    _owner._logger.warning(
      '🔍 [BLEStateManager] SESSION STATE CLEARING - CRITICAL NAVIGATION EVENT',
    );
    _owner._logger.warning(
      '  - BEFORE: otherUserName = "${_owner._otherUserName}"',
    );
    _owner._logger.warning(
      '  - BEFORE: otherDevicePersistentId = "${truncateId(_owner._currentSessionId)}"',
    );
    _owner._logger.warning('  - preservePersistentId = $preservePersistentId');
    _owner._logger.warning(
      '  - Called from: ${StackTrace.current.toString().split('\n').take(5).join(' -> ')}',
    );

    // FIX: Preserve identity during navigation to maintain connection state
    final previousName = _owner._otherUserName;
    final previousId = _owner._currentSessionId;

    if (!preservePersistentId) {
      // Actual disconnection - clear everything
      _owner._otherUserName = null;
      _owner._logger.warning(
        '  - ⚠️  CLEARED otherUserName: "$previousName" -> null (disconnection)',
      );

      _owner._identityState.clear(preservePersistentId: false);
      _owner._identityState.clearMappings();
      _owner._logger.warning(
        '  - ⚠️  CLEARED persistent ID: "${truncateId(previousId)}" -> null (connection loss)',
      );

      // 🔧 FIX: Removed SecurityManager.unregisterSessionMapping() - now using database ephemeral_id column
    } else {
      // Navigation only - preserve identity to maintain connection state
      _owner._logger.warning(
        '  - ✅ PRESERVED otherUserName: "${_owner._otherUserName}" (navigation)',
      );
      _owner._logger.warning(
        '  - ✅ PRESERVED persistent ID: "${truncateId(_owner._currentSessionId)}" (navigation)',
      );
      _owner._identityState.clear(preservePersistentId: true);
    }

    _owner._contactStatusSyncController.reset();

    // FIX: Only broadcast null name if we're actually clearing it (disconnection)
    if (!preservePersistentId) {
      _owner._logger.warning(
        '  - 🚨 BROADCASTING NULL NAME TO UI (triggers disconnected state)',
      );
      _owner.onNameChanged?.call(null);
      _owner._logger.warning(
        '🔍 [BLEStateManager] SESSION CLEAR COMPLETE - UI will now show DISCONNECTED',
      );
    } else {
      _owner._logger.warning(
        '  - ✅ PRESERVING NAME BROADCAST (UI stays connected during navigation)',
      );
      _owner._logger.warning(
        '🔍 [BLEStateManager] SESSION CLEAR COMPLETE - UI connection state preserved',
      );
    }
  }

  Future<void> initializeCrypto() async {
    try {
      SimpleCrypto.initialize();
      _owner._logger.info('Global baseline encryption initialized');
    } catch (e) {
      _owner._logger.warning('Failed to initialize encryption: $e');
    }
  }

  void clearOtherUserName() {
    _owner._logger.fine('🐛 NAV DEBUG: clearOtherUserName() called');
    // For navigation, preserve persistent ID to maintain security state
    clearSessionState(preservePersistentId: true);
  }

  Future<void> recoverIdentityFromStorage() async {
    if (_owner._currentSessionId == null) {
      _owner._logger.info(
        '[BLEStateManager] 🔄 RECOVERY: No persistent ID available for identity recovery',
      );
      return;
    }

    try {
      final displayName = await _owner._identityState.recoverDisplayName((
        publicKey,
      ) async {
        final contact = await _owner._contactRepository.getContact(publicKey);
        return contact?.displayName;
      });

      if (displayName != null && displayName.isNotEmpty) {
        _owner._logger.info(
          '[BLEStateManager] 🔄 RECOVERY: Restored identity from contacts',
        );
        _owner._logger.info(
          '  - Public key: ${truncateId(_owner._currentSessionId)}',
        );
        _owner._logger.info('  - Display name: $displayName');

        // Restore session identity without triggering full connection flow
        _owner._otherUserName = displayName;
        _owner.onNameChanged?.call(_owner._otherUserName);

        _owner._logger.info(
          '[BLEStateManager] ✅ RECOVERY: Identity successfully recovered from storage',
        );
      } else {
        _owner._logger.warning(
          '[BLEStateManager] 🔄 RECOVERY: No contact found in repository for persistent ID',
        );
      }
    } catch (e) {
      _owner._logger.warning(
        '[BLEStateManager] 🔄 RECOVERY: Failed to recover identity from storage: $e',
      );
    }
  }

  Future<Map<String, String?>> getIdentityWithFallback() async {
    // Primary: Use session state if available
    if (_owner._otherUserName != null && _owner._otherUserName!.isNotEmpty) {
      return {
        'displayName': _owner._otherUserName,
        'publicKey': _owner._currentSessionId ?? '',
        'source': 'session',
      };
    }

    // Secondary: Use last known display name tracked in identity state
    if (_owner._identityState.lastKnownDisplayName != null &&
        _owner._identityState.lastKnownDisplayName!.isNotEmpty &&
        _owner._currentSessionId != null) {
      return {
        'displayName': _owner._identityState.lastKnownDisplayName,
        'publicKey': _owner._currentSessionId!,
        'source': 'cache',
      };
    }

    // Fallback: Try to get from persistent storage
    if (_owner._currentSessionId != null) {
      try {
        final contact = await _owner._contactRepository.getContact(
          _owner._currentSessionId!,
        );
        if (contact != null) {
          return {
            'displayName': contact.displayName,
            'publicKey': _owner._currentSessionId!,
            'source': 'repository',
          };
        }
      } catch (e) {
        _owner._logger.warning('Failed to get fallback identity: $e');
      }
    }

    // Last resort: Return what we have
    return {
      'displayName': _owner._otherUserName ?? 'Connected Device',
      'publicKey': _owner._currentSessionId ?? '',
      'source': 'fallback',
    };
  }
}
