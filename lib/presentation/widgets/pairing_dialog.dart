import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PairingDialog extends StatefulWidget {
  final String myCode;
  final Function(String) onCodeEntered;
  final VoidCallback onCancel;
  
  const PairingDialog({
    super.key,
    required this.myCode,
    required this.onCodeEntered,
    required this.onCancel,
  });
  
  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  final TextEditingController _controller = TextEditingController();
  bool _isVerifying = false;
  
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.lock, color: Theme.of(context).colorScheme.primary),
          SizedBox(width: 8),
          Text('Secure Pairing'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Show this code to the other person:',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          SizedBox(height: 12),
          Container(
            padding: EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              widget.myCode,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 8,
              ),
            ),
          ),
          SizedBox(height: 20),
          Text(
            'Enter their code:',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          SizedBox(height: 8),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            maxLength: 4,
            style: Theme.of(context).textTheme.headlineSmall,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              border: OutlineInputBorder(),
              hintText: '0000',
              counterText: '',
            ),
            onChanged: (value) {
              if (value.length == 4 && !_isVerifying) {
                _submitCode();
              }
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isVerifying ? null : widget.onCancel,
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isVerifying || _controller.text.length != 4 
            ? null 
            : _submitCode,
          child: _isVerifying 
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text('Verify'),
        ),
      ],
    );
  }
  
  void _submitCode() {
    setState(() => _isVerifying = true);
    widget.onCodeEntered(_controller.text);
  }
  
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}