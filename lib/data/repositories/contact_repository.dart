import 'package:shared_preferences/shared_preferences.dart';

class ContactRepository {
  static const String _contactsKey = 'device_contacts';

  Future<void> saveContact(String persistentId, String userName) async {
  final prefs = await SharedPreferences.getInstance();
  final contacts = await getContacts();
  contacts[persistentId] = userName;
  
  final contactsList = contacts.entries
      .map((entry) => '${entry.key}:${entry.value}')
      .toList();
  
  await prefs.setStringList(_contactsKey, contactsList);
}

  Future<Map<String, String>> getContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final contactsList = prefs.getStringList(_contactsKey) ?? [];
    
    final contacts = <String, String>{};
    for (final contact in contactsList) {
      final parts = contact.split(':');
      if (parts.length == 2) {
        contacts[parts[0]] = parts[1];
      }
    }
    return contacts;
  }

  Future<String?> getContactName(String persistentId) async {
  final contacts = await getContacts();
  return contacts[persistentId];
}
}