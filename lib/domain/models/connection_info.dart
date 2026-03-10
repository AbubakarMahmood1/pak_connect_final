// JUSTIFICATION: Single comprehensive connection state model prevents
// UI from needing to combine multiple streams. Previous attempts with
// separate streams led to synchronization issues and UI inconsistencies.
class ConnectionInfo {
  static const Object _unset = Object();

  final bool isConnected; // Basic BLE connection
  final bool isReady; // Ready for messaging (has identity)
  final String? otherUserName; // Display name for UI
  final String? statusMessage; // Human readable status
  final bool isScanning; // For discovery screen
  final bool isAdvertising; // For peripheral mode
  final bool isReconnecting; // For loading states
  final bool awaitingHandshake; // Whether handshake/notify setup is in progress

  const ConnectionInfo({
    required this.isConnected,
    required this.isReady,
    this.otherUserName,
    this.statusMessage,
    this.isScanning = false,
    this.isAdvertising = false,
    this.isReconnecting = false,
    this.awaitingHandshake = false,
  });

  // Convenience getters for common UI needs
  bool get canSendMessages => isReady;
  bool get showConnectedUI => isReady;

  ConnectionInfo copyWith({
    bool? isConnected,
    bool? isReady,
    Object? otherUserName = _unset,
    Object? statusMessage = _unset,
    bool? isScanning,
    bool? isAdvertising,
    bool? isReconnecting,
    bool? awaitingHandshake,
  }) => ConnectionInfo(
    isConnected: isConnected ?? this.isConnected,
    isReady: isReady ?? this.isReady,
    otherUserName: identical(otherUserName, _unset)
        ? this.otherUserName
        : otherUserName as String?,
    statusMessage: identical(statusMessage, _unset)
        ? this.statusMessage
        : statusMessage as String?,
    isScanning: isScanning ?? this.isScanning,
    isAdvertising: isAdvertising ?? this.isAdvertising,
    isReconnecting: isReconnecting ?? this.isReconnecting,
    awaitingHandshake: awaitingHandshake ?? this.awaitingHandshake,
  );
}
