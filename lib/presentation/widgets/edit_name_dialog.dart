import 'package:flutter/material.dart';

class EditNameDialog extends StatefulWidget {
  final String currentName;

  const EditNameDialog({super.key, required this.currentName});

  @override
  State<EditNameDialog> createState() => _EditNameDialogState();
}

class _EditNameDialogState extends State<EditNameDialog> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Your Display Name'),
      content: TextField(
        controller: _controller,
        decoration: InputDecoration(
          labelText: 'Name',
          hintText: 'Enter your name',
          border: OutlineInputBorder(),
        ),
        maxLength: 20,
        textCapitalization: TextCapitalization.words,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final name = _controller.text.trim();
            if (name.isNotEmpty) {
              Navigator.pop(context, name);
            }
          },
          child: Text('Save'),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}
