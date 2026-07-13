import 'dart:convert';

enum BleExperimentEventType {
  peerDiscovered,
  advertiseStarted,
  advertiseStopped,
  scanStarted,
  scanStopped,
  outboundConnectRequested,
  inboundConnected,
  mtuReady,
  notifySubscribed,
  handshakeStarted,
  handshakeReady,
  disconnect,
  reconnectAttemptStarted,
  reconnectAttemptFinished,
}

final class BleExperimentMetricsSummary {
  const BleExperimentMetricsSummary({
    required this.sessionMode,
    required this.totalEvents,
    required this.peerDiscoveredCount,
    required this.advertiseStartedCount,
    required this.advertiseStoppedCount,
    required this.scanStartedCount,
    required this.scanStoppedCount,
    required this.connectRequestedCount,
    required this.inboundConnectedCount,
    required this.mtuReadyCount,
    required this.notifySubscribedCount,
    required this.handshakeStartedCount,
    required this.handshakeReadyCount,
    required this.disconnectCount,
    required this.reconnectAttemptStartedCount,
    required this.reconnectAttemptFinishedCount,
    required this.reconnectSuccessCount,
    required this.reconnectFailureCount,
    required this.discoverySuccessRate,
    required this.connectSuccessRate,
    required this.handshakeSuccessRate,
    required this.disconnectDropRate,
    required this.medianTimeToFirstPeerMs,
    required this.medianConnectToHandshakeReadyMs,
  });

  final String sessionMode;
  final int totalEvents;
  final int peerDiscoveredCount;
  final int advertiseStartedCount;
  final int advertiseStoppedCount;
  final int scanStartedCount;
  final int scanStoppedCount;
  final int connectRequestedCount;
  final int inboundConnectedCount;
  final int mtuReadyCount;
  final int notifySubscribedCount;
  final int handshakeStartedCount;
  final int handshakeReadyCount;
  final int disconnectCount;
  final int reconnectAttemptStartedCount;
  final int reconnectAttemptFinishedCount;
  final int reconnectSuccessCount;
  final int reconnectFailureCount;
  final double discoverySuccessRate;
  final double connectSuccessRate;
  final double handshakeSuccessRate;
  final double disconnectDropRate;
  final int? medianTimeToFirstPeerMs;
  final int? medianConnectToHandshakeReadyMs;

  Map<String, Object?> toJson() => {
    'sessionMode': sessionMode,
    'totalEvents': totalEvents,
    'peerDiscoveredCount': peerDiscoveredCount,
    'advertiseStartedCount': advertiseStartedCount,
    'advertiseStoppedCount': advertiseStoppedCount,
    'scanStartedCount': scanStartedCount,
    'scanStoppedCount': scanStoppedCount,
    'connectRequestedCount': connectRequestedCount,
    'inboundConnectedCount': inboundConnectedCount,
    'mtuReadyCount': mtuReadyCount,
    'notifySubscribedCount': notifySubscribedCount,
    'handshakeStartedCount': handshakeStartedCount,
    'handshakeReadyCount': handshakeReadyCount,
    'disconnectCount': disconnectCount,
    'reconnectAttemptStartedCount': reconnectAttemptStartedCount,
    'reconnectAttemptFinishedCount': reconnectAttemptFinishedCount,
    'reconnectSuccessCount': reconnectSuccessCount,
    'reconnectFailureCount': reconnectFailureCount,
    'discoverySuccessRate': discoverySuccessRate,
    'connectSuccessRate': connectSuccessRate,
    'handshakeSuccessRate': handshakeSuccessRate,
    'disconnectDropRate': disconnectDropRate,
    'medianTimeToFirstPeerMs': medianTimeToFirstPeerMs,
    'medianConnectToHandshakeReadyMs': medianConnectToHandshakeReadyMs,
  };

  String toStructuredLogLine({required String reason}) =>
      jsonEncode({'reason': reason, ...toJson()});
}

abstract interface class IBleExperimentMetricsRecorder {
  String get sessionMode;

  void recordPeerDiscovered(String peerId);
  void recordAdvertisingStarted();
  void recordAdvertisingStopped();
  void recordScanStarted();
  void recordScanStopped();
  void recordOutboundConnectRequested(String peerId);
  void recordInboundConnected(String peerId);
  void recordMtuReady(String peerId, int mtu);
  void recordNotifySubscribed(String peerId);
  void recordHandshakeStarted(String peerId);
  void recordHandshakeReady(String peerId);
  void recordDisconnect(String peerId, String reason);
  void recordReconnectAttemptStarted(String? peerId);
  void recordReconnectAttemptFinished(String? peerId, {required bool success});
  BleExperimentMetricsSummary snapshot();
  void logSummary({String reason = 'session-end'});
}
