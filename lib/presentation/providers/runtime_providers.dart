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

class _NoopSharedMessageQueueProvider implements ISharedMessageQueueProvider {
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
