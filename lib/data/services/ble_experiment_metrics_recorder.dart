import 'dart:math' as math;

import 'package:logging/logging.dart';
import 'package:pak_connect/domain/interfaces/i_ble_experiment_metrics_recorder.dart';

final class BleExperimentMetricsRecorder
    implements IBleExperimentMetricsRecorder {
  BleExperimentMetricsRecorder({
    required Logger logger,
    required this.sessionMode,
  }) : _logger = logger;

  final Logger _logger;

  @override
  final String sessionMode;

  final List<_MetricsEvent> _events = <_MetricsEvent>[];
  final List<_ScanWindowSession> _scanSessions = <_ScanWindowSession>[];
  final Map<String, _PeerCycle> _activeCycles = <String, _PeerCycle>{};
  final List<_PeerCycle> _completedCycles = <_PeerCycle>[];

  _ScanWindowSession? _activeScanSession;
  bool _summaryLogged = false;

  @override
  void recordPeerDiscovered(String peerId) {
    _record(BleExperimentEventType.peerDiscovered, peerId: peerId);
    final scanSession = _activeScanSession;
    if (scanSession != null && scanSession.firstPeerDiscoveredAt == null) {
      scanSession.firstPeerDiscoveredAt = DateTime.now();
    }
  }

  @override
  void recordAdvertisingStarted() =>
      _record(BleExperimentEventType.advertiseStarted);

  @override
  void recordAdvertisingStopped() =>
      _record(BleExperimentEventType.advertiseStopped);

  @override
  void recordScanStarted() {
    _record(BleExperimentEventType.scanStarted);
    _summaryLogged = false;
    final session = _ScanWindowSession(startedAt: DateTime.now());
    _activeScanSession = session;
    _scanSessions.add(session);
  }

  @override
  void recordScanStopped() {
    _record(BleExperimentEventType.scanStopped);
    _activeScanSession?.stoppedAt = DateTime.now();
    _activeScanSession = null;
  }

  @override
  void recordOutboundConnectRequested(String peerId) {
    _record(BleExperimentEventType.outboundConnectRequested, peerId: peerId);
    _activeCycles[peerId] = _PeerCycle(
      peerId: peerId,
      startedAt: DateTime.now(),
      startedByInbound: false,
    );
  }

  @override
  void recordInboundConnected(String peerId) {
    _record(BleExperimentEventType.inboundConnected, peerId: peerId);
    _activeCycles.putIfAbsent(
      peerId,
      () => _PeerCycle(
        peerId: peerId,
        startedAt: DateTime.now(),
        startedByInbound: true,
      ),
    );
  }

  @override
  void recordMtuReady(String peerId, int mtu) {
    _record(BleExperimentEventType.mtuReady, peerId: peerId, value: mtu);
    _activeCycles
            .putIfAbsent(
              peerId,
              () => _PeerCycle(
                peerId: peerId,
                startedAt: DateTime.now(),
                startedByInbound: true,
              ),
            )
            .mtuReadyAt =
        DateTime.now();
  }

  @override
  void recordNotifySubscribed(String peerId) {
    _record(BleExperimentEventType.notifySubscribed, peerId: peerId);
    _activeCycles
            .putIfAbsent(
              peerId,
              () => _PeerCycle(
                peerId: peerId,
                startedAt: DateTime.now(),
                startedByInbound: true,
              ),
            )
            .notifySubscribedAt =
        DateTime.now();
  }

  @override
  void recordHandshakeStarted(String peerId) {
    _record(BleExperimentEventType.handshakeStarted, peerId: peerId);
    _activeCycles
            .putIfAbsent(
              peerId,
              () => _PeerCycle(
                peerId: peerId,
                startedAt: DateTime.now(),
                startedByInbound: true,
              ),
            )
            .handshakeStartedAt =
        DateTime.now();
  }

  @override
  void recordHandshakeReady(String peerId) {
    _record(BleExperimentEventType.handshakeReady, peerId: peerId);
    _activeCycles
            .putIfAbsent(
              peerId,
              () => _PeerCycle(
                peerId: peerId,
                startedAt: DateTime.now(),
                startedByInbound: true,
              ),
            )
            .handshakeReadyAt =
        DateTime.now();
  }

  @override
  void recordDisconnect(String peerId, String reason) {
    _record(
      BleExperimentEventType.disconnect,
      peerId: peerId,
      metadata: reason,
    );
    final cycle = _activeCycles.remove(peerId);
    if (cycle != null) {
      cycle.disconnectAt = DateTime.now();
      _completedCycles.add(cycle);
    }
  }

  @override
  void recordReconnectAttemptStarted(String? peerId) {
    _record(BleExperimentEventType.reconnectAttemptStarted, peerId: peerId);
  }

  @override
  void recordReconnectAttemptFinished(String? peerId, {required bool success}) {
    _record(
      BleExperimentEventType.reconnectAttemptFinished,
      peerId: peerId,
      metadata: success ? 'success' : 'failure',
    );
  }

  @override
  BleExperimentMetricsSummary snapshot() {
    final discoverySuccessCount = _scanSessions
        .where((session) => session.firstPeerDiscoveredAt != null)
        .length;
    final scanCount = _count(BleExperimentEventType.scanStarted);
    final connectCycles = _allCycles();
    final connectSuccessCount = connectCycles
        .where(
          (cycle) => cycle.mtuReadyAt != null || cycle.handshakeReadyAt != null,
        )
        .length;
    final handshakeStartedCount = connectCycles
        .where((cycle) => cycle.handshakeStartedAt != null)
        .length;
    final handshakeReadyCount = connectCycles
        .where((cycle) => cycle.handshakeReadyAt != null)
        .length;
    final reconnectFinished = _events
        .where(
          (event) =>
              event.type == BleExperimentEventType.reconnectAttemptFinished,
        )
        .toList(growable: false);
    final reconnectSuccesses = reconnectFinished
        .where((event) => event.metadata == 'success')
        .length;
    final reconnectFailures = reconnectFinished.length - reconnectSuccesses;

    return BleExperimentMetricsSummary(
      sessionMode: sessionMode,
      totalEvents: _events.length,
      peerDiscoveredCount: _count(BleExperimentEventType.peerDiscovered),
      advertiseStartedCount: _count(BleExperimentEventType.advertiseStarted),
      advertiseStoppedCount: _count(BleExperimentEventType.advertiseStopped),
      scanStartedCount: scanCount,
      scanStoppedCount: _count(BleExperimentEventType.scanStopped),
      connectRequestedCount: _count(
        BleExperimentEventType.outboundConnectRequested,
      ),
      inboundConnectedCount: _count(BleExperimentEventType.inboundConnected),
      mtuReadyCount: _count(BleExperimentEventType.mtuReady),
      notifySubscribedCount: _count(BleExperimentEventType.notifySubscribed),
      handshakeStartedCount: handshakeStartedCount,
      handshakeReadyCount: handshakeReadyCount,
      disconnectCount: _count(BleExperimentEventType.disconnect),
      reconnectAttemptStartedCount: _count(
        BleExperimentEventType.reconnectAttemptStarted,
      ),
      reconnectAttemptFinishedCount: reconnectFinished.length,
      reconnectSuccessCount: reconnectSuccesses,
      reconnectFailureCount: reconnectFailures,
      discoverySuccessRate: _rate(discoverySuccessCount, scanCount),
      connectSuccessRate: _rate(connectSuccessCount, connectCycles.length),
      handshakeSuccessRate: _rate(handshakeReadyCount, handshakeStartedCount),
      disconnectDropRate: _rate(
        _count(BleExperimentEventType.disconnect),
        math.max(1, connectCycles.length),
      ),
      medianTimeToFirstPeerMs: _median(
        _scanSessions
            .where((session) => session.firstPeerDiscoveredAt != null)
            .map(
              (session) => session.firstPeerDiscoveredAt!
                  .difference(session.startedAt)
                  .inMilliseconds,
            )
            .toList(growable: false),
      ),
      medianConnectToHandshakeReadyMs: _median(
        connectCycles
            .where((cycle) => cycle.handshakeReadyAt != null)
            .map(
              (cycle) => cycle.handshakeReadyAt!
                  .difference(cycle.startedAt)
                  .inMilliseconds,
            )
            .toList(growable: false),
      ),
    );
  }

  @override
  void logSummary({String reason = 'session-end'}) {
    if (_summaryLogged) {
      return;
    }
    _summaryLogged = true;
    final summary = snapshot();
    _logger.info(
      'BLE_EXPERIMENT_SUMMARY ${summary.toStructuredLogLine(reason: reason)}',
    );
  }

  void _record(
    BleExperimentEventType type, {
    String? peerId,
    int? value,
    String? metadata,
  }) {
    _summaryLogged = false;
    _events.add(
      _MetricsEvent(
        type: type,
        timestamp: DateTime.now(),
        peerId: peerId,
        value: value,
        metadata: metadata,
      ),
    );
  }

  List<_PeerCycle> _allCycles() {
    final cycles = <_PeerCycle>[..._completedCycles, ..._activeCycles.values];
    return cycles;
  }

  int _count(BleExperimentEventType type) =>
      _events.where((event) => event.type == type).length;

  double _rate(int numerator, int denominator) {
    if (denominator <= 0) {
      return 0;
    }
    return numerator / denominator;
  }

  int? _median(List<int> values) {
    if (values.isEmpty) return null;
    values.sort();
    final middle = values.length ~/ 2;
    if (values.length.isOdd) {
      return values[middle];
    }
    return ((values[middle - 1] + values[middle]) / 2).round();
  }
}

final class _MetricsEvent {
  const _MetricsEvent({
    required this.type,
    required this.timestamp,
    this.peerId,
    this.value,
    this.metadata,
  });

  final BleExperimentEventType type;
  final DateTime timestamp;
  final String? peerId;
  final int? value;
  final String? metadata;
}

final class _ScanWindowSession {
  _ScanWindowSession({required this.startedAt});

  final DateTime startedAt;
  DateTime? firstPeerDiscoveredAt;
  DateTime? stoppedAt;
}

final class _PeerCycle {
  _PeerCycle({
    required this.peerId,
    required this.startedAt,
    required this.startedByInbound,
  });

  final String peerId;
  final DateTime startedAt;
  final bool startedByInbound;
  DateTime? mtuReadyAt;
  DateTime? notifySubscribedAt;
  DateTime? handshakeStartedAt;
  DateTime? handshakeReadyAt;
  DateTime? disconnectAt;
}
