import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/presentation/providers/di_providers.dart';
import 'package:logging/logging.dart';

import '../../domain/interfaces/i_shared_message_queue_provider.dart';
import '../../domain/messaging/offline_message_queue_contract.dart';

/// Bootstrap state values for the application lifecycle.
enum AppBootstrapStatus { initializing, ready, running, error }

/// Bootstrap state for the application lifecycle.
class AppBootstrapState {
  final AppBootstrapStatus status;
  final Object? error;
  final StackTrace? stackTrace;

  const AppBootstrapState({required this.status, this.error, this.stackTrace});

  bool get isReady =>
      status == AppBootstrapStatus.ready ||
      status == AppBootstrapStatus.running;
}

/// AsyncNotifier that initializes app runtime dependencies once.
class AppBootstrapNotifier extends AsyncNotifier<AppBootstrapState> {
  final _logger = Logger('AppBootstrapNotifier');

  @override
  Future<AppBootstrapState> build() async {
    final bootstrapHost = _resolveBootstrapHost();
    final initialStatus = bootstrapHost.isInitialized
        ? AppBootstrapStatus.running
        : AppBootstrapStatus.initializing;
    state = AsyncValue.data(AppBootstrapState(status: initialStatus));

    try {
      _logger.info('🔧 Bootstrapping runtime host...');
      await bootstrapHost.initialize();
      _logger.info('✅ Runtime host initialized');
      return const AppBootstrapState(status: AppBootstrapStatus.ready);
    } catch (e, stack) {
      _logger.severe('❌ Runtime bootstrap failed', e, stack);
      return AppBootstrapState(
        status: AppBootstrapStatus.error,
        error: e,
        stackTrace: stack,
      );
    }
  }

  ISharedMessageQueueProvider _resolveBootstrapHost() {
    return maybeResolveFromAppServicesOrServiceLocator<
          ISharedMessageQueueProvider
        >(fromServices: (services) => services.sharedMessageQueueProvider) ??
        const _NoopSharedMessageQueueProvider();
  }
}

/// Provider that ensures application bootstrap is triggered once.
final appBootstrapProvider =
    AsyncNotifierProvider<AppBootstrapNotifier, AppBootstrapState>(
      () => AppBootstrapNotifier(),
    );

/// Waits until bootstrap reaches a usable ready/running state.
///
/// Unlike `appBootstrapProvider.future`, this will not resolve on the
/// intermediate `initializing` data state that the bootstrap notifier publishes
/// during startup.
final appBootstrapReadyProvider = FutureProvider<AppBootstrapState>((
  ref,
) async {
  // AppCore now publishes the typed runtime composition root before BLE warm-up
  // completes. If that snapshot is already live, presentation/runtime features
  // can proceed immediately instead of waiting on the secondary bootstrap
  // notifier, which may still be catching up in the background.
  if (maybeResolveAppServices() != null) {
    return const AppBootstrapState(status: AppBootstrapStatus.ready);
  }

  final current = ref.read(appBootstrapProvider);
  final currentState = current.asData?.value;
  if (currentState?.isReady ?? false) {
    return currentState!;
  }

  if (currentState?.status == AppBootstrapStatus.error) {
    throw currentState?.error ??
        StateError('App bootstrap failed during startup.');
  }

  if (current.hasError) {
    throw current.error!;
  }

  final completer = Completer<AppBootstrapState>();

  void completeError(Object error, [StackTrace? stackTrace]) {
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void handle(AsyncValue<AppBootstrapState> next) {
    next.when(
      data: (value) {
        if (value.isReady) {
          if (!completer.isCompleted) {
            completer.complete(value);
          }
          return;
        }

        if (value.status == AppBootstrapStatus.error) {
          completeError(
            value.error ?? StateError('App bootstrap failed during startup.'),
            value.stackTrace,
          );
        }
      },
      loading: () {},
      error: completeError,
    );
  }

  ref.listen<AsyncValue<AppBootstrapState>>(
    appBootstrapProvider,
    (previous, next) => handle(next),
  );
  handle(ref.read(appBootstrapProvider));

  return completer.future;
});

class _NoopSharedMessageQueueProvider
    with SharedMessageQueueProviderWaitMixin
    implements ISharedMessageQueueProvider {
  const _NoopSharedMessageQueueProvider();

  @override
  bool get isInitialized => true;

  @override
  bool get isInitializing => false;

  @override
  Future<void> initialize() async {}

  @override
  OfflineMessageQueueContract get messageQueue =>
      throw StateError('No shared queue host registered.');
}
