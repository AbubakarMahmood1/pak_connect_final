import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/domain/routing/network_topology_analyzer.dart';
import 'package:pak_connect/domain/routing/routing_models.dart';

/// NetworkTopologyAnalyzer unit tests
/// Pure graph logic: BFS reachability, connectivity, stats, topology mutations
void main() {
 late List<LogRecord> logRecords;
 late NetworkTopologyAnalyzer analyzer;

 setUp(() {
 logRecords = [];
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(logRecords.add);
 analyzer = NetworkTopologyAnalyzer();
 });

 tearDown(() {
 analyzer.dispose();
 final severeErrors = logRecords
 .where((log) => log.level >= Level.SEVERE)
 .toList();
 expect(severeErrors, isEmpty,
 reason:
 'Unexpected SEVERE errors:\n${severeErrors.map((e) => '${e.level}: ${e.message}').join('\n')}');
 });

 group('NetworkTopologyAnalyzer — basic topology', () {
 test('starts with empty topology', () {
 expect(analyzer.getAllKnownNodes(), isEmpty);
 expect(analyzer.getNetworkSize(), 0);
 });

 test('addConnection creates bidirectional edge', () async {
 await analyzer.addConnection('A', 'B');

 final nodes = analyzer.getAllKnownNodes();
 expect(nodes.contains('A'), true);
 expect(nodes.contains('B'), true);
 expect(analyzer.getNetworkSize(), 2);
 });

 test('addConnection with custom quality', () async {
 await analyzer.addConnection('A',
 'B',
 quality: ConnectionQuality.excellent,
);

 final topology = analyzer.getNetworkTopology();
 expect(topology.connections['A'], contains('B'));
 expect(topology.connections['B'], contains('A'));
 });

 test('addConnection with metrics', () async {
 final metrics = ConnectionMetrics(signalStrength: 0.9,
 latency: 50.0,
 packetLoss: 0.01,
 throughput: 0.95,
);

 await analyzer.addConnection('A', 'B', metrics: metrics);
 expect(analyzer.getNetworkSize(), 2);
 });

 test('removeConnection removes edge', () async {
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('A', 'C');

 await analyzer.removeConnection('A', 'B');

 final topology = analyzer.getNetworkTopology();
 expect(topology.connections['A']?.contains('B') ?? false, false);
 // A-C should remain
 expect(topology.connections['A'], contains('C'));
 });

 test('removeConnection is safe for non-existent edge', () async {
 await analyzer.removeConnection('X', 'Y');
 expect(analyzer.getNetworkSize(), 0);
 });
 });

 group('NetworkTopologyAnalyzer — getReachableNodes (BFS)', () {
 test('returns empty for isolated node', () async {
 final reachable = analyzer.getReachableNodes('A');
 expect(reachable, isEmpty);
 });

 test('returns direct neighbors at hop 1', () async {
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('A', 'C');

 final reachable = analyzer.getReachableNodes('A', maxHops: 1);
 expect(reachable.contains('B'), true);
 expect(reachable.contains('C'), true);
 expect(reachable.length, 2);
 });

 test('respects hop limit', () async {
 // Linear chain: A - B - C - D
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('B', 'C');
 await analyzer.addConnection('C', 'D');

 // From A with maxHops=1: only B
 final hop1 = analyzer.getReachableNodes('A', maxHops: 1);
 expect(hop1, contains('B'));
 expect(hop1.contains('C'), false);
 expect(hop1.contains('D'), false);

 // From A with maxHops=2: B, C
 final hop2 = analyzer.getReachableNodes('A', maxHops: 2);
 expect(hop2, containsAll(['B', 'C']));
 expect(hop2.contains('D'), false);

 // From A with maxHops=3: B, C, D
 final hop3 = analyzer.getReachableNodes('A', maxHops: 3);
 expect(hop3, containsAll(['B', 'C', 'D']));
 });

 test('handles cycles correctly', () async {
 // Triangle: A - B - C - A
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('B', 'C');
 await analyzer.addConnection('C', 'A');

 final reachable = analyzer.getReachableNodes('A', maxHops: 3);
 expect(reachable, containsAll(['B', 'C']));
 // Should not include self
 expect(reachable.contains('A'), false);
 });

 test('handles star topology', () async {
 // Hub: Center connected to spokes
 await analyzer.addConnection('Center', 'S1');
 await analyzer.addConnection('Center', 'S2');
 await analyzer.addConnection('Center', 'S3');
 await analyzer.addConnection('Center', 'S4');

 final fromCenter = analyzer.getReachableNodes('Center', maxHops: 1);
 expect(fromCenter.length, 4);

 // From spoke with 2 hops: can reach center + all other spokes
 final fromSpoke = analyzer.getReachableNodes('S1', maxHops: 2);
 expect(fromSpoke, containsAll(['Center', 'S2', 'S3', 'S4']));
 });

 test('handles disconnected subgraphs', () async {
 // Two disconnected pairs
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('C', 'D');

 final fromA = analyzer.getReachableNodes('A', maxHops: 10);
 expect(fromA, contains('B'));
 expect(fromA.contains('C'), false);
 expect(fromA.contains('D'), false);
 });
 });

 group('NetworkTopologyAnalyzer — isNetworkConnected', () {
 test('empty network is connected', () {
 expect(analyzer.isNetworkConnected(), true);
 });

 test('single edge is connected', () async {
 await analyzer.addConnection('A', 'B');
 expect(analyzer.isNetworkConnected(), true);
 });

 test('connected chain is connected', () async {
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('B', 'C');
 await analyzer.addConnection('C', 'D');
 expect(analyzer.isNetworkConnected(), true);
 });

 test('disconnected subgraphs are NOT connected', () async {
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('C', 'D');
 expect(analyzer.isNetworkConnected(), false);
 });

 test('reconnecting disconnected graph restores connectivity', () async {
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('C', 'D');
 expect(analyzer.isNetworkConnected(), false);

 // Bridge the gap
 await analyzer.addConnection('B', 'C');
 expect(analyzer.isNetworkConnected(), true);
 });
 });

 group('NetworkTopologyAnalyzer — getNetworkStats', () {
 test('empty network stats', () {
 final stats = analyzer.getNetworkStats();
 expect(stats.totalNodes, 0);
 expect(stats.totalConnections, 0);
 expect(stats.averageQuality, 0.0);
 expect(stats.isConnected, true);
 });

 test('stats reflect correct node and connection count', () async {
 await analyzer.addConnection('A', 'B');
 await analyzer.addConnection('B', 'C');
 await analyzer.addConnection('C', 'A');

 final stats = analyzer.getNetworkStats();
 expect(stats.totalNodes, 3);
 expect(stats.totalConnections, 3);
 expect(stats.isConnected, true);
 });

 test('average quality reflects connection qualities', () async {
 await analyzer.addConnection('A',
 'B',
 quality: ConnectionQuality.excellent,
);
 await analyzer.addConnection('B',
 'C',
 quality: ConnectionQuality.poor,
);

 final stats = analyzer.getNetworkStats();
 // excellent=1.0, poor=0.4 → avg=0.7
 expect(stats.averageQuality, closeTo(0.7, 0.01));
 });
 });

 group('NetworkTopologyAnalyzer — updateConnectionQuality', () {
 test('updates quality when metrics change', () async {
 await analyzer.addConnection('A',
 'B',
 quality: ConnectionQuality.good,
);

 // Update with excellent metrics
 final excellentMetrics = ConnectionMetrics(signalStrength: 0.95,
 latency: 30.0,
 packetLoss: 0.001,
 throughput: 0.99,
);

 await analyzer.updateConnectionQuality('A', 'B', excellentMetrics);

 final topology = analyzer.getNetworkTopology();
 final quality = topology.getConnectionQuality('A', 'B');
 expect(quality, ConnectionQuality.excellent);
 });
 });

 group('NetworkTopologyAnalyzer — topology stream', () {
 test('stream delivers current topology immediately', () async {
 await analyzer.addConnection('A', 'B');

 final topology = await analyzer.topologyUpdates.first;
 expect(topology.connections['A'], contains('B'));
 });
 });

 group('NetworkTopologyAnalyzer — dispose', () {
 test('dispose clears all state', () {
 analyzer.dispose();
 // After dispose, creating a new one should work cleanly
 final newAnalyzer = NetworkTopologyAnalyzer();
 expect(newAnalyzer.getNetworkSize(), 0);
 newAnalyzer.dispose();
 });
 });
}
