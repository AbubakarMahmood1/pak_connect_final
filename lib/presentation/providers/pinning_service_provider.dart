import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pak_connect/core/services/pinning_service.dart';

/// Provider for PinningService instance
final pinningServiceProvider = Provider.autoDispose<PinningService>((ref) {
  final service = PinningService();
  ref.onDispose(service.dispose);
  return service;
});

/// Stream provider for message update events
final messageUpdatesProvider = StreamProvider.autoDispose<dynamic>((
  ref,
) async* {
  final service = ref.watch(pinningServiceProvider);
  yield* service.messageUpdates;
});
