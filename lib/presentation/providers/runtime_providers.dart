import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';

import '../../core/app_core.dart';

/// Bootstrap state for the application lifecycle.
class AppBootstrapState {
  final AppStatus status;
  final Object? error;
  final StackTrace? stackTrace;

  const AppBootstrapState({required this.status, this.error, this.stackTrace});

  bool get isReady => status == AppStatus.ready || status == AppStatus.running;
}

/// AsyncNotifier that initializes [AppCore] once and surfaces lifecycle state.
class AppBootstrapNotifier extends AsyncNotifier<AppBootstrapState> {
  final _logger = Logger('AppBootstrapNotifier');
  StreamSubscription<AppStatus>? _statusSubscription;

  @override
  Future<AppBootstrapState> build() async {
    ref.onDispose(() => _statusSubscription?.cancel());

    final core = AppCore.instance;
    final initialStatus = core.isInitialized
        ? AppStatus.running
        : AppStatus.initializing;
    final initialState = AppBootstrapState(status: initialStatus);

    // Listen for status transitions and keep state in sync.
    _statusSubscription = core.statusStream.listen((status) {
      final current = state.asData?.value ?? initialState;
      state = AsyncValue.data(
        AppBootstrapState(
          status: status,
          error: current.error,
          stackTrace: current.stackTrace,
        ),
      );
    });

    try {
      _logger.info('🔧 Bootstrapping AppCore...');
      await core.initialize();
      _logger.info('✅ AppCore initialized');
      return AppBootstrapState(status: AppStatus.ready);
    } catch (e, stack) {
      _logger.severe('❌ AppCore initialization failed', e, stack);
      return AppBootstrapState(
        status: AppStatus.error,
        error: e,
        stackTrace: stack,
      );
    }
  }
}

/// Provider that ensures AppCore is initialized exactly once.
final appBootstrapProvider =
    AsyncNotifierProvider<AppBootstrapNotifier, AppBootstrapState>(
      () => AppBootstrapNotifier(),
    );
