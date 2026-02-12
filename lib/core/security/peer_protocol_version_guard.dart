/// Shared runtime guard for protocol version downgrade policy.
///
/// Once a peer is observed sending v2+, later v1 messages from the same peer
/// can be rejected to prevent downgrade drift during migration.
class PeerProtocolVersionGuard {
  static const bool isEnabled = bool.fromEnvironment(
    'PAKCONNECT_ENFORCE_V2_DOWNGRADE_GUARD',
    defaultValue: true,
  );
  static const int _maxTrackedPeers = 4096;
  static final Map<String, int> _peerProtocolVersionFloor = <String, int>{};

  static bool shouldRejectLegacyMessage({
    required int messageVersion,
    required String peerKey,
  }) {
    if (!isEnabled || messageVersion >= 2 || peerKey.isEmpty) {
      return false;
    }
    return floorForPeer(peerKey) >= 2;
  }

  static int floorForPeer(String peerKey) {
    if (peerKey.isEmpty) {
      return 1;
    }
    return _peerProtocolVersionFloor[peerKey] ?? 1;
  }

  static ProtocolVersionTrackResult trackObservedVersion({
    required int messageVersion,
    required String peerKey,
  }) {
    if (!isEnabled || messageVersion < 2 || peerKey.isEmpty) {
      return ProtocolVersionTrackResult(
        upgraded: false,
        cacheCleared: false,
        floor: floorForPeer(peerKey),
      );
    }

    var cacheCleared = false;
    if (_peerProtocolVersionFloor.length >= _maxTrackedPeers &&
        !_peerProtocolVersionFloor.containsKey(peerKey)) {
      _peerProtocolVersionFloor.clear();
      cacheCleared = true;
    }

    final currentFloor = floorForPeer(peerKey);
    final upgraded = messageVersion > currentFloor;
    if (upgraded) {
      _peerProtocolVersionFloor[peerKey] = messageVersion;
    }

    return ProtocolVersionTrackResult(
      upgraded: upgraded,
      cacheCleared: cacheCleared,
      floor: floorForPeer(peerKey),
    );
  }

  static void clearForTest() {
    _peerProtocolVersionFloor.clear();
  }
}

class ProtocolVersionTrackResult {
  const ProtocolVersionTrackResult({
    required this.upgraded,
    required this.cacheCleared,
    required this.floor,
  });

  final bool upgraded;
  final bool cacheCleared;
  final int floor;
}
