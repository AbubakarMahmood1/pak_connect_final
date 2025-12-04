import 'dart:async';
import 'package:pak_connect/domain/values/id_types.dart';

/// Tracks outbound message ACKs with timeout handling.
class MessageAckTracker {
  MessageAckTracker({Duration timeout = const Duration(seconds: 5)})
    : _timeout = timeout;

  final Duration _timeout;
  final Map<String, Completer<bool>> _pendingAcks = {};
  final Map<String, Timer> _ackTimers = {};

  /// Start tracking an outbound message.
  Completer<bool> track(
    String messageId, {
    void Function(String messageId)? onTimeout,
  }) {
    final completer = Completer<bool>();
    _pendingAcks[messageId] = completer;

    _ackTimers[messageId] = Timer(_timeout, () {
      if (completer.isCompleted) {
        _cleanup(messageId);
        return;
      }

      onTimeout?.call(messageId);
      completer.complete(false);
      _cleanup(messageId);
    });

    return completer;
  }

  Completer<bool> trackId(
    MessageId messageId, {
    void Function(MessageId messageId)? onTimeout,
  }) => track(
    messageId.value,
    onTimeout: onTimeout != null ? (id) => onTimeout(MessageId(id)) : null,
  );

  /// Complete and clear an ACK if it's still pending.
  bool complete(String messageId, {bool success = true}) {
    final completer = _pendingAcks[messageId];

    if (completer == null || completer.isCompleted) {
      _cleanup(messageId);
      return false;
    }

    completer.complete(success);
    _cleanup(messageId);
    return true;
  }

  bool completeId(MessageId messageId, {bool success = true}) =>
      complete(messageId.value, success: success);

  /// Checks if an ACK is still pending for the given message ID.
  bool isPending(String messageId) => _pendingAcks.containsKey(messageId);
  bool isPendingId(MessageId messageId) => isPending(messageId.value);

  /// Cancel tracking for a message without completing it.
  void cancel(String messageId) {
    _cleanup(messageId);
  }

  void dispose() {
    for (final timer in _ackTimers.values) {
      timer.cancel();
    }
    _ackTimers.clear();
    _pendingAcks.clear();
  }

  void _cleanup(String messageId) {
    _ackTimers.remove(messageId)?.cancel();
    _pendingAcks.remove(messageId);
  }
}
