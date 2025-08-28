enum ChatConnectionState {
  disconnected,     // No BLE connection
  connecting,       // BLE connected, establishing protocol
  exchangingIds,    // Identity exchange in progress
  ready,           // Fully ready to chat
  reconnecting,     // Attempting to reconnect
  failed           // Connection failed
}

class ConnectionInfo {
  final ChatConnectionState state;
  final String? deviceId;
  final String? displayName;
  final String? error;
  
  const ConnectionInfo({
    required this.state,
    this.deviceId,
    this.displayName, 
    this.error,
  });
  
  bool get isConnected => state == ChatConnectionState.ready;
  bool get canSendMessages => state == ChatConnectionState.ready;
}