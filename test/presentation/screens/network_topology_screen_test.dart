import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pak_connect/domain/routing/topology_manager.dart';
import 'package:pak_connect/presentation/providers/mesh_networking_provider.dart';
import 'package:pak_connect/presentation/screens/network_topology_screen.dart';

void _seedNode(
  TopologyManager manager, {
  required String nodeId,
  required String displayName,
  required List<String> neighbors,
}) {
  manager.recordNodeAnnouncementWithNeighbors(
    nodeId: nodeId,
    displayName: displayName,
    neighborIds: neighbors,
  );
}

Future<void> _pumpNetworkTopologyScreen(
  WidgetTester tester,
  TopologyManager manager,
) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [topologyManagerProvider.overrideWithValue(manager)],
      child: const MaterialApp(home: NetworkTopologyScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('NetworkTopologyScreen', () {
    late TopologyManager manager;

    setUp(() {
      manager = TopologyManager.instance;
      manager.initializeForTests('node_self');
    });

    tearDown(() {
      manager.clear();
    });

    testWidgets('renders status dashboard, graph, and node list', (
      tester,
    ) async {
      _seedNode(
        manager,
        nodeId: 'node_a',
        displayName: 'Alice Node',
        neighbors: const <String>['node_self'],
      );
      _seedNode(
        manager,
        nodeId: 'node_b',
        displayName: 'Bob Node',
        neighbors: const <String>['node_a'],
      );

      await _pumpNetworkTopologyScreen(tester, manager);

      expect(find.text('Mesh Network'), findsOneWidget);
      expect(find.text('Network Status'), findsOneWidget);
      expect(find.text('Network Graph'), findsOneWidget);
      expect(find.textContaining('Network Nodes ('), findsOneWidget);
      expect(find.text('You'), findsWidgets);
      expect(find.text('Bob Node'), findsOneWidget);
    });

    testWidgets('refresh button reloads topology changes', (tester) async {
      _seedNode(
        manager,
        nodeId: 'node_a',
        displayName: 'Alice Node',
        neighbors: const <String>['node_self'],
      );

      await _pumpNetworkTopologyScreen(tester, manager);
      expect(find.text('Carol Node'), findsNothing);

      _seedNode(
        manager,
        nodeId: 'node_c',
        displayName: 'Carol Node',
        neighbors: const <String>['node_self'],
      );

      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Carol Node'), findsOneWidget);
      expect(find.textContaining('Network Nodes ('), findsOneWidget);
    });

    testWidgets('topology stream updates UI without manual refresh', (
      tester,
    ) async {
      _seedNode(
        manager,
        nodeId: 'node_a',
        displayName: 'Alice Node',
        neighbors: const <String>['node_self'],
      );

      await _pumpNetworkTopologyScreen(tester, manager);
      expect(find.text('Dora Node'), findsNothing);

      _seedNode(
        manager,
        nodeId: 'node_d',
        displayName: 'Dora Node',
        neighbors: const <String>['node_a'],
      );
      await tester.pumpAndSettle();

      expect(find.text('Dora Node'), findsOneWidget);
      expect(find.textContaining('Network Nodes ('), findsOneWidget);
    });
  });
}
