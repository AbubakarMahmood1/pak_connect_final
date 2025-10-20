// Screen to create a new contact group

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/group_providers.dart';
import '../../data/repositories/contact_repository.dart';
import '../../core/services/security_manager.dart';

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final Set<String> _selectedMemberKeys = {};
  bool _isLoading = false;
  List<Contact>? _availableContacts;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    try {
      final repo = ContactRepository();
      final contactsMap = await repo.getAllContacts();
      // Convert map to list and filter to only verified contacts at MEDIUM+ security
      final verified = contactsMap.values.where((c) =>
        c.trustStatus == TrustStatus.verified &&
        (c.securityLevel == SecurityLevel.medium || c.securityLevel == SecurityLevel.high)
      ).toList();

      setState(() {
        _availableContacts = verified;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to load contacts: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_selectedMemberKeys.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one member')),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      final createGroup = ref.read(createGroupProvider);
      await createGroup(
        name: _nameController.text.trim(),
        memberKeys: _selectedMemberKeys.toList(),
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Group created successfully')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create group: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Group'),
      ),
      body: _availableContacts == null
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  // Group name
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Group Name',
                      hintText: 'Enter group name',
                      prefixIcon: Icon(Icons.group),
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a group name';
                      }
                      return null;
                    },
                    textCapitalization: TextCapitalization.words,
                  ),

                  const SizedBox(height: 16),

                  // Description (optional)
                  TextFormField(
                    controller: _descriptionController,
                    decoration: const InputDecoration(
                      labelText: 'Description (optional)',
                      hintText: 'Enter group description',
                      prefixIcon: Icon(Icons.description),
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                  ),

                  const SizedBox(height: 24),

                  // Member selection header
                  Row(
                    children: [
                      const Text(
                        'Select Members',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Chip(
                        label: Text('${_selectedMemberKeys.length} selected'),
                        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      ),
                    ],
                  ),

                  const SizedBox(height: 8),

                  // Member list
                  if (_availableContacts!.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No verified contacts available.\nVerify contacts at MEDIUM+ security first.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    )
                  else
                    ..._availableContacts!.map((contact) {
                      final isSelected = _selectedMemberKeys.contains(contact.noisePublicKey ?? contact.publicKey);
                      return CheckboxListTile(
                        value: isSelected,
                        onChanged: (selected) {
                          setState(() {
                            final key = contact.noisePublicKey ?? contact.publicKey;
                            if (selected == true) {
                              _selectedMemberKeys.add(key);
                            } else {
                              _selectedMemberKeys.remove(key);
                            }
                          });
                        },
                        title: Text(contact.displayName),
                        subtitle: Text(
                          '${contact.securityLevel.name.toUpperCase()} security',
                          style: TextStyle(
                            fontSize: 12,
                            color: contact.securityLevel == SecurityLevel.high
                                ? Colors.green
                                : Colors.orange,
                          ),
                        ),
                        secondary: CircleAvatar(
                          backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                          child: Text(
                            contact.displayName[0].toUpperCase(),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ),
                      );
                    }),

                  const SizedBox(height: 24),

                  // Create button
                  ElevatedButton(
                    onPressed: _isLoading ? null : _createGroup,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Create Group'),
                  ),
                ],
              ),
            ),
    );
  }
}
