import 'dart:async';

import 'package:flutter/material.dart';

Future<bool> showPanicWipeDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => const _PanicWipeDialog(),
  );
  return confirmed ?? false;
}

class _PanicWipeDialog extends StatefulWidget {
  const _PanicWipeDialog();

  @override
  State<_PanicWipeDialog> createState() => _PanicWipeDialogState();
}

class _PanicWipeDialogState extends State<_PanicWipeDialog> {
  static const _requiredPhrase = 'WIPE';
  static const _holdDuration = Duration(seconds: 2);

  final TextEditingController _textController = TextEditingController();
  Timer? _holdTimer;
  bool _phraseMatches = false;
  bool _isHolding = false;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _textController.dispose();
    super.dispose();
  }

  void _handlePhraseChanged(String value) {
    final matches = value.trim() == _requiredPhrase;
    if (_phraseMatches == matches) {
      return;
    }
    if (!matches) {
      _cancelHold();
    }
    setState(() {
      _phraseMatches = matches;
    });
  }

  void _startHold() {
    if (!_phraseMatches || _isHolding) {
      return;
    }
    setState(() {
      _isHolding = true;
    });
    _holdTimer = Timer(_holdDuration, () {
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(true);
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    if (_isHolding && mounted) {
      setState(() {
        _isHolding = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabledColor = theme.colorScheme.error;
    final disabledColor = theme.colorScheme.surfaceContainerHighest;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: enabledColor),
          const SizedBox(width: 8),
          const Text('Panic Wipe'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This permanently destroys your local identity, chats, contacts, archives, encrypted database, and settings.',
          ),
          const SizedBox(height: 12),
          Text(
            'Type WIPE to unlock the hold-to-confirm action.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('panicWipePhraseField'),
            controller: _textController,
            autofocus: true,
            onChanged: _handlePhraseChanged,
            decoration: const InputDecoration(
              labelText: 'Confirmation phrase',
              hintText: 'WIPE',
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _isHolding
                ? 'Keep holding to confirm...'
                : 'Press and hold for 2 seconds to wipe.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _phraseMatches ? enabledColor : theme.hintColor,
            ),
          ),
          const SizedBox(height: 12),
          IgnorePointer(
            ignoring: !_phraseMatches,
            child: Listener(
              onPointerDown: (_) => _startHold(),
              onPointerUp: (_) => _cancelHold(),
              onPointerCancel: (_) => _cancelHold(),
              child: AnimatedContainer(
                key: const Key('panicWipeHoldButton'),
                duration: const Duration(milliseconds: 120),
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: _phraseMatches ? enabledColor : disabledColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _isHolding ? 'Keep Holding...' : 'Press and Hold to Wipe',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: _phraseMatches
                        ? theme.colorScheme.onError
                        : theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
