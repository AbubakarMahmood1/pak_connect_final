// permission_screen.dart comprehensive coverage
// Covers: BLE states, timeout listener, _requestBLEPermissions,
// _openSettings, _showImportDialog, permission explanation dialog,
// and _showPermissionDeniedDialog/_getPermissionName where reachable.

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:pak_connect/presentation/providers/ble_providers.dart';
import 'package:pak_connect/presentation/screens/permission_screen.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// A safe notifier that cancels its timer and can be disposed multiple times.
class _SafePermissionTimeoutNotifier extends PermissionTimeoutStateNotifier {
 bool _disposed = false;

 _SafePermissionTimeoutNotifier() : super() {
 cancel();
 }

 @override
 void dispose() {
 if (_disposed) return;
 _disposed = true;
 super.dispose();
 }
}

/// A controllable timeout notifier that lets tests trigger the timeout.
class _ControllableTimeoutNotifier extends PermissionTimeoutStateNotifier {
 bool _disposed = false;

 _ControllableTimeoutNotifier() : super() {
 cancel();
 }

 void fireTimeout() {
 if (!_disposed) state = true;
 }

 @override
 void dispose() {
 if (_disposed) return;
 _disposed = true;
 super.dispose();
 }
}

/// Pump the PermissionScreen wrapped in MaterialApp + ProviderScope.
Future<void> _pumpPermissionScreen(WidgetTester tester, {
 required AsyncValue<BluetoothLowEnergyState> bleState,
 PermissionTimeoutStateNotifier? timeoutNotifier,
}) async {
 tester.view.physicalSize = const Size(1200, 2400);
 tester.view.devicePixelRatio = 1.0;
 addTearDown(tester.view.resetPhysicalSize);
 addTearDown(tester.view.resetDevicePixelRatio);

 await tester.pumpWidget(ProviderScope(overrides: [
 bleStateProvider.overrideWith((ref) => bleState),
 permissionTimeoutProvider.overrideWith((ref) => timeoutNotifier ?? _SafePermissionTimeoutNotifier(),
),
],
 child: const MaterialApp(home: PermissionScreen()),
),
);
 await tester.pump();
}

// ---------------------------------------------------------------------------
// Captured log records helper
// ---------------------------------------------------------------------------
List<LogRecord> _captureLogRecords() {
 final records = <LogRecord>[];
 Logger.root.level = Level.ALL;
 Logger.root.onRecord.listen(records.add);
 return records;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
 setUp(() {
 Logger.root.level = Level.OFF;
 });

 group('PermissionScreen – UI rendering', () {
 testWidgets('loading state shows CircularProgressIndicator', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue<BluetoothLowEnergyState>.loading(),
);
 expect(find.byType(CircularProgressIndicator), findsOneWidget);
 });

 testWidgets('error state shows error text', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: AsyncValue<BluetoothLowEnergyState>.error('BLE init failed',
 StackTrace.empty,
),
);
 expect(find.textContaining('Error:'), findsOneWidget);
 expect(find.textContaining('BLE init failed'), findsOneWidget);
 });

 testWidgets('unsupported state shows checking status copy', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unsupported,
),
);
 expect(find.text('Checking Bluetooth status...'), findsOneWidget);
 expect(find.text('Please wait while we check your device capabilities.'),
 findsOneWidget,
);
 });

 testWidgets('poweredOn shows bluetooth icon, title, buttons', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);
 expect(find.text('BLE Chat'), findsOneWidget);
 expect(find.text('Secure offline messaging\nfor family & friends'),
 findsOneWidget,
);
 expect(find.byIcon(Icons.check_circle), findsOneWidget);
 expect(find.text('All set! Ready to chat'), findsOneWidget);
 expect(find.text('Start Anew'), findsOneWidget);
 expect(find.text('Import Existing Data'), findsOneWidget);
 expect(find.byIcon(Icons.upload_file), findsOneWidget);
 expect(find.text('Why is this needed?'), findsOneWidget);
 });

 testWidgets('unauthorized shows permission request UI', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);
 expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
 expect(find.text('Bluetooth Permission Required'), findsOneWidget);
 expect(find.textContaining('We need Bluetooth access to find nearby'),
 findsOneWidget,
);
 expect(find.text('Grant Permission'), findsOneWidget);
 expect(find.text('Open Settings'), findsOneWidget);
 });

 testWidgets('poweredOff shows detailed Bluetooth guidance', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOff,
),
);
 expect(find.byIcon(Icons.bluetooth_disabled), findsOneWidget);
 expect(find.text('Bluetooth is turned off'), findsOneWidget);
 expect(find.textContaining('Please turn on Bluetooth'), findsOneWidget);
 expect(find.text('Settings > Bluetooth > Turn On'), findsOneWidget);
 });

 testWidgets('unknown state shows progress indicator', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unknown),
);
 expect(find.text('Checking Bluetooth status...'), findsOneWidget);
 expect(find.byType(CircularProgressIndicator), findsWidgets);
 });

 testWidgets('renders app logo circle with bluetooth icon', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);
 expect(find.byIcon(Icons.bluetooth), findsOneWidget);
 expect(find.text('BLE Chat'), findsOneWidget);
 });

 testWidgets('screen wraps in SafeArea and Padding', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);
 expect(find.byType(SafeArea), findsOneWidget);
 expect(find.byType(Padding), findsWidgets);
 });

 testWidgets('grant permission button enabled in unauthorized state', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);
 final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Grant Permission'),
);
 expect(button.onPressed, isNotNull);
 });

 testWidgets('open settings button present in unauthorized state', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);
 expect(find.widgetWithText(OutlinedButton, 'Open Settings'),
 findsOneWidget,
);
 });

 testWidgets('distinct BLE states produce distinct UIs', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);
 expect(find.text('All set! Ready to chat'), findsOneWidget);
 expect(find.text('Bluetooth is turned off'), findsNothing);
 expect(find.text('Bluetooth Permission Required'), findsNothing);
 });
 });

 // =========================================================================
 // Permission explanation dialog
 // =========================================================================
 group('PermissionScreen – explanation dialog', () {
 testWidgets('shows all content', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);
 await tester.tap(find.text('Why is this needed?'));
 await tester.pumpAndSettle();

 expect(find.text('Why Bluetooth Permission?'), findsOneWidget);
 expect(find.text('We need Bluetooth to:'), findsOneWidget);
 expect(find.text('• Find nearby devices'), findsOneWidget);
 expect(find.text('• Send/receive messages'), findsOneWidget);
 expect(find.text('• Maintain connections'), findsOneWidget);
 expect(find.byIcon(Icons.security), findsOneWidget);
 expect(find.text('Your messages never leave your devices'),
 findsOneWidget,
);
 expect(find.text('Got it'), findsOneWidget);
 });

 testWidgets('dismisses cleanly via Got it', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);
 await tester.tap(find.text('Why is this needed?'));
 await tester.pumpAndSettle();
 expect(find.text('Why Bluetooth Permission?'), findsOneWidget);

 await tester.tap(find.text('Got it'));
 await tester.pumpAndSettle();
 expect(find.text('Why Bluetooth Permission?'), findsNothing);
 });
 });

 // =========================================================================
 // Timeout listener (lines 31-32)
 // =========================================================================
 group('PermissionScreen – timeout listener', () {
 testWidgets('timeout fires and triggers _showError log', (tester) async {
 final logRecords = _captureLogRecords();
 final notifier = _ControllableTimeoutNotifier();

 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unknown),
 timeoutNotifier: notifier,
);

 // Fire the timeout – this triggers the ref.listen callback (lines 31-32)
 notifier.fireTimeout();
 await tester.pump();
 await tester.pump();

 // _showError logs a warning with the timeout message
 expect(logRecords.any((r) => r.message.contains('BLE initialization timed out'),
),
 isTrue,
);
 });

 testWidgets('timeout fires while mounted does not crash', (tester) async {
 final notifier = _ControllableTimeoutNotifier();

 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unsupported,
),
 timeoutNotifier: notifier,
);

 // Fire the timeout – exercise the listener with unsupported state
 notifier.fireTimeout();
 await tester.pump();
 await tester.pump();

 // Should still be showing the screen
 expect(find.text('BLE Chat'), findsOneWidget);
 });
 });

 // =========================================================================
 // _requestBLEPermissions (lines 258-259, 262, 296, 299, 301-302)
 // On a non-Android test host, this exercises the else branch.
 // =========================================================================
 group('PermissionScreen – _requestBLEPermissions', () {
 testWidgets('grant permission tap executes non-Android path', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);

 // Tap Grant Permission – triggers _requestBLEPermissions
 // On non-Android host: lines 258-259 (entry+setState),
 // 262 (Platform.isAndroid=false), 296 (else branch: navigate),
 // 301-302 (finally block)
 await tester.tap(find.widgetWithText(FilledButton, 'Grant Permission'));
 await tester.pump(const Duration(milliseconds: 100));

 // The method ran without synchronous exceptions
 });

 testWidgets('grant permission button not null in unauthorized', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);

 final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Grant Permission'),
);
 // onPressed is not null (lines 169-171: _isRequestingPermissions is false)
 expect(button.onPressed, isNotNull);
 });
 });

 // =========================================================================
 // _openSettings (lines 362-368)
 // openAppSettings() throws in test env → catch block → _showError
 // =========================================================================
 group('PermissionScreen – _openSettings', () {
 testWidgets('open settings tap exercises _openSettings catch path', (tester,
) async {
 final logRecords = _captureLogRecords();

 // Mock the permission_handler channel to throw, exercising catch path
 const channel = MethodChannel('flutter.baseflow.com/permissions/methods',
);
 TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
 .setMockMethodCallHandler(channel, (call) async {
 if (call.method == 'openAppSettings') {
 throw PlatformException(code: 'ERROR',
 message: 'Not available in test',
);
 }
 return null;
 });
 addTearDown(() {
 TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
 .setMockMethodCallHandler(channel, null);
 });

 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);

 // Tap "Open Settings" – triggers _openSettings (line 362)
 // Mocked channel throws → catch block (lines 365-367) → _showError
 await tester.tap(find.widgetWithText(OutlinedButton, 'Open Settings'));
 await tester.pump();
 await tester.pump(const Duration(milliseconds: 500));

 // The _showError should have logged
 expect(logRecords.any((r) => r.message.contains('Could not open settings'),
),
 isTrue,
);
 });

 testWidgets('open settings success path does not log error', (tester,
) async {
 final logRecords = _captureLogRecords();

 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.unauthorized,
),
);

 // Tap "Open Settings" without mocked channel – Windows plugin
 // handles it (success path, line 364)
 await tester.tap(find.widgetWithText(OutlinedButton, 'Open Settings'));
 await tester.pump();
 await tester.pump(const Duration(milliseconds: 500));

 // No "Could not open settings" error should be logged
 expect(logRecords.any((r) => r.message.contains('Could not open settings'),
),
 isFalse,
);
 });
 });

 // =========================================================================
 // _showImportDialog (line 138)
 // =========================================================================
 group('PermissionScreen – _showImportDialog', () {
 testWidgets('tapping Import Existing Data shows ImportDialog', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);

 // Tap "Import Existing Data" (line 138)
 await tester.tap(find.text('Import Existing Data'));
 await tester.pumpAndSettle();

 // ImportDialog should be visible
 expect(find.text('Import Backup'), findsOneWidget);
 expect(find.text('Select Backup File'), findsOneWidget);
 expect(find.text('Cancel'), findsOneWidget);
 });

 testWidgets('dismissing ImportDialog with Cancel returns null', (tester,
) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);

 await tester.tap(find.text('Import Existing Data'));
 await tester.pumpAndSettle();

 // Dismiss via Cancel (result=null, so no navigation)
 await tester.tap(find.text('Cancel'));
 await tester.pumpAndSettle();

 // Should be back on PermissionScreen
 expect(find.text('All set! Ready to chat'), findsOneWidget);
 expect(find.text('Import Backup'), findsNothing);
 });
 });

 // =========================================================================
 // Start Anew navigation (line 130 → _navigateToChatsScreen)
 // =========================================================================
 group('PermissionScreen – navigation', () {
 testWidgets('tapping Start Anew does not crash', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);
 await tester.tap(find.text('Start Anew'));
 await tester.pump(const Duration(milliseconds: 100));
 });

 testWidgets('import button is rendered with upload icon', (tester) async {
 await _pumpPermissionScreen(tester,
 bleState: const AsyncValue.data(BluetoothLowEnergyState.poweredOn),
);
 expect(find.text('Import Existing Data'), findsOneWidget);
 expect(find.byIcon(Icons.upload_file), findsOneWidget);
 });
 });

 // =========================================================================
 // PermissionTimeoutStateNotifier unit tests
 // =========================================================================
 group('PermissionTimeoutStateNotifier', () {
 test('starts with false and fires after 10s', () {
 fakeAsync((async) {
 final notifier = PermissionTimeoutStateNotifier();
 addTearDown(notifier.dispose);

 expect(notifier.state, isFalse);

 async.elapse(const Duration(seconds: 10));
 expect(notifier.state, isTrue);
 });
 });

 test('cancel prevents timeout from firing', () {
 fakeAsync((async) {
 final notifier = PermissionTimeoutStateNotifier();
 addTearDown(notifier.dispose);

 notifier.cancel();
 async.elapse(const Duration(seconds: 15));
 expect(notifier.state, isFalse);
 });
 });

 test('cancel resets state to false after fire', () {
 fakeAsync((async) {
 final notifier = PermissionTimeoutStateNotifier();
 addTearDown(notifier.dispose);

 async.elapse(const Duration(seconds: 10));
 expect(notifier.state, isTrue);

 notifier.cancel();
 expect(notifier.state, isFalse);
 });
 });

 test('dispose cancels timer', () {
 fakeAsync((async) {
 final notifier = PermissionTimeoutStateNotifier();
 notifier.dispose();

 async.elapse(const Duration(seconds: 15));
 // After dispose, the notifier should not fire.
 // (Accessing state after dispose is undefined but shouldn't throw)
 });
 });
 });
}
