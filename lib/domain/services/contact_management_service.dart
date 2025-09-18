// Comprehensive contact management system with advanced search and privacy controls

import 'dart:convert';
import 'package:logging/logging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/repositories/contact_repository.dart';
import '../../data/repositories/message_repository.dart';
import '../../core/services/security_manager.dart';
import '../entities/enhanced_contact.dart';

/// Comprehensive contact management service with advanced search and privacy features
class ContactManagementService {
  static final _logger = Logger('ContactManagementService');
  final ContactRepository _contactRepository = ContactRepository();
  final MessageRepository _messageRepository = MessageRepository();
  static const String _settingsPrefix = 'contact_mgmt_';
  static const String _searchHistoryKey = 'contact_search_history';
  static const String _contactGroupsKey = 'contact_groups';
  
  // Privacy settings
  bool _allowAddressBookSync = false;
  bool _allowContactExport = false;
  bool _enableContactAnalytics = false;
  
  // Search and filtering
  final List<String> _recentSearches = [];
  final Map<String, ContactGroup> _contactGroups = {};
  
  /// Initialize contact management service
  Future<void> initialize() async {
    await _loadSettings();
    await _loadSearchHistory();
    await _loadContactGroups();
    _logger.info('Contact management service initialized');
  }
  
  /// Get all contacts with enhanced information
  Future<List<EnhancedContact>> getAllEnhancedContacts() async {
    try {
      final contacts = await _contactRepository.getAllContacts();
      final enhancedContacts = <EnhancedContact>[];
      
      for (final contact in contacts.values) {
        final enhanced = await _enhanceContact(contact);
        enhancedContacts.add(enhanced);
      }
      
      // Sort by display name
      enhancedContacts.sort((a, b) => a.displayName.compareTo(b.displayName));
      
      return enhancedContacts;
    } catch (e) {
      _logger.severe('Failed to get enhanced contacts: $e');
      return [];
    }
  }
  
  /// Search contacts with advanced filtering capabilities
  Future<ContactSearchResult> searchContacts({
    required String query,
    ContactSearchFilter? filter,
    ContactSortOption sortBy = ContactSortOption.name,
    bool ascending = true,
  }) async {
    try {
      final startTime = DateTime.now();
      final allContacts = await getAllEnhancedContacts();
      
      // Apply search query
      List<EnhancedContact> filteredContacts = allContacts;
      
      if (query.isNotEmpty) {
        filteredContacts = _performTextSearch(allContacts, query);
        _addToSearchHistory(query);
      }
      
      // Apply additional filters
      if (filter != null) {
        filteredContacts = _applySearchFilter(filteredContacts, filter);
      }
      
      // Apply sorting
      filteredContacts = _sortContacts(filteredContacts, sortBy, ascending);
      
      final searchTime = DateTime.now().difference(startTime);
      
      final result = ContactSearchResult(
        contacts: filteredContacts,
        query: query,
        totalResults: filteredContacts.length,
        searchTime: searchTime,
        appliedFilter: filter,
        sortedBy: sortBy,
        ascending: ascending,
      );
      
      _logger.info('Contact search completed: ${result.totalResults} results in ${searchTime.inMilliseconds}ms');
      return result;
      
    } catch (e) {
      _logger.severe('Contact search failed: $e');
      return ContactSearchResult.empty(query);
    }
  }
  
  /// Get contact by public key with enhanced information
  Future<EnhancedContact?> getEnhancedContact(String publicKey) async {
    try {
      final contact = await _contactRepository.getContact(publicKey);
      if (contact == null) return null;
      
      return await _enhanceContact(contact);
    } catch (e) {
      _logger.severe('Failed to get enhanced contact: $e');
      return null;
    }
  }
  
  /// Delete contact with confirmation and cleanup
  Future<ContactOperationResult> deleteContact(String publicKey) async {
    try {
      final contact = await _contactRepository.getContact(publicKey);
      if (contact == null) {
        return ContactOperationResult.failure('Contact not found');
      }
      
      // Clear associated data
      await _contactRepository.clearCachedSecrets(publicKey);
      
      // Remove from groups
      await _removeContactFromAllGroups(publicKey);
      
      // Delete the contact (this will require implementing delete in ContactRepository)
      await _deleteContactFromRepository(publicKey);
      
      _logger.info('Contact deleted: ${contact.displayName} (${publicKey.substring(0, 16)}...)');
      return ContactOperationResult.success('Contact deleted successfully');
      
    } catch (e) {
      _logger.severe('Failed to delete contact: $e');
      return ContactOperationResult.failure('Failed to delete contact: $e');
    }
  }
  
  /// Bulk delete contacts
  Future<BulkOperationResult> deleteContacts(List<String> publicKeys) async {
    int successCount = 0;
    int failureCount = 0;
    final List<String> failedDeletes = [];
    
    for (final publicKey in publicKeys) {
      final result = await deleteContact(publicKey);
      if (result.success) {
        successCount++;
      } else {
        failureCount++;
        failedDeletes.add(publicKey);
      }
    }
    
    return BulkOperationResult(
      totalOperations: publicKeys.length,
      successCount: successCount,
      failureCount: failureCount,
      failedItems: failedDeletes,
    );
  }
  
  /// Get contact statistics and analytics
  Future<ContactAnalytics> getContactAnalytics() async {
    try {
      final contacts = await getAllEnhancedContacts();
      
      final totalContacts = contacts.length;
      final verifiedContacts = contacts.where((c) => c.trustStatus == TrustStatus.verified).length;
      final highSecurityContacts = contacts.where((c) => c.securityLevel == SecurityLevel.high).length;
      
      final securityLevelDistribution = <SecurityLevel, int>{};
      final trustStatusDistribution = <TrustStatus, int>{};
      
      for (final contact in contacts) {
        securityLevelDistribution[contact.securityLevel] = 
          (securityLevelDistribution[contact.securityLevel] ?? 0) + 1;
        trustStatusDistribution[contact.trustStatus] = 
          (trustStatusDistribution[contact.trustStatus] ?? 0) + 1;
      }
      
      final oldestContact = contacts.isNotEmpty 
        ? contacts.reduce((a, b) => a.firstSeen.isBefore(b.firstSeen) ? a : b)
        : null;
      
      final newestContact = contacts.isNotEmpty
        ? contacts.reduce((a, b) => a.firstSeen.isAfter(b.firstSeen) ? a : b)
        : null;
      
      return ContactAnalytics(
        totalContacts: totalContacts,
        verifiedContacts: verifiedContacts,
        highSecurityContacts: highSecurityContacts,
        securityLevelDistribution: securityLevelDistribution,
        trustStatusDistribution: trustStatusDistribution,
        oldestContact: oldestContact,
        newestContact: newestContact,
        averageContactAge: _calculateAverageContactAge(contacts),
      );
      
    } catch (e) {
      _logger.severe('Failed to get contact analytics: $e');
      return ContactAnalytics.empty();
    }
  }
  
  /// Create contact group for organization
  Future<ContactOperationResult> createContactGroup({
    required String name,
    required String description,
    List<String> memberPublicKeys = const [],
  }) async {
    try {
      if (_contactGroups.containsKey(name)) {
        return ContactOperationResult.failure('Group already exists');
      }
      
      final group = ContactGroup(
        id: _generateGroupId(),
        name: name,
        description: description,
        memberPublicKeys: Set.from(memberPublicKeys),
        createdAt: DateTime.now(),
        lastModified: DateTime.now(),
      );
      
      _contactGroups[name] = group;
      await _saveContactGroups();
      
      return ContactOperationResult.success('Contact group created');
    } catch (e) {
      _logger.severe('Failed to create contact group: $e');
      return ContactOperationResult.failure('Failed to create group: $e');
    }
  }
  
  /// Add contact to group
  Future<ContactOperationResult> addContactToGroup(String publicKey, String groupName) async {
    try {
      final group = _contactGroups[groupName];
      if (group == null) {
        return ContactOperationResult.failure('Group not found');
      }
      
      group.memberPublicKeys.add(publicKey);
      group.lastModified = DateTime.now();
      await _saveContactGroups();
      
      return ContactOperationResult.success('Contact added to group');
    } catch (e) {
      return ContactOperationResult.failure('Failed to add contact to group: $e');
    }
  }
  
  /// Get recent search queries
  List<String> getRecentSearches() {
    return List.from(_recentSearches.reversed);
  }
  
  /// Clear search history
  Future<void> clearSearchHistory() async {
    _recentSearches.clear();
    await _saveSearchHistory();
  }
  
  /// Get privacy settings
  ContactPrivacySettings getPrivacySettings() {
    return ContactPrivacySettings(
      allowAddressBookSync: _allowAddressBookSync,
      allowContactExport: _allowContactExport,
      enableContactAnalytics: _enableContactAnalytics,
    );
  }
  
  /// Update privacy settings
  Future<void> updatePrivacySettings(ContactPrivacySettings settings) async {
    _allowAddressBookSync = settings.allowAddressBookSync;
    _allowContactExport = settings.allowContactExport;
    _enableContactAnalytics = settings.enableContactAnalytics;
    
    await _saveSettings();
    _logger.info('Privacy settings updated');
  }
  
  /// Export contacts (if privacy settings allow)
  Future<ContactOperationResult> exportContacts({
    ContactExportFormat format = ContactExportFormat.json,
    bool includeSecurityData = false,
  }) async {
    if (!_allowContactExport) {
      return ContactOperationResult.failure('Contact export is disabled in privacy settings');
    }
    
    try {
      final contacts = await getAllEnhancedContacts();
      final exportData = _prepareExportData(contacts, includeSecurityData);
      
      String serializedData;
      switch (format) {
        case ContactExportFormat.json:
          serializedData = jsonEncode(exportData);
          break;
        case ContactExportFormat.csv:
          serializedData = _convertToCSV(exportData);
          break;
      }
      
      // Save to SharedPreferences as exported data (in real app would save to file)
      await _saveExportedData(serializedData, format);
      _logger.info('Exported ${contacts.length} contacts in ${format.name} format');
      return ContactOperationResult.success('Contacts exported successfully to local storage');
      
    } catch (e) {
      _logger.severe('Failed to export contacts: $e');
      return ContactOperationResult.failure('Export failed: $e');
    }
  }
  
  // Private methods
  
  /// Enhance basic contact with additional information
  Future<EnhancedContact> _enhanceContact(Contact contact) async {
    final lastSeenAgo = DateTime.now().difference(contact.lastSeen);
    final isRecentlyActive = lastSeenAgo.inDays <= 7;

    // Calculate interaction metrics using real message data
    final interactionCount = await _calculateInteractionCount(contact.publicKey);
    final averageResponseTime = await _calculateAverageResponseTime(contact.publicKey);
    
    return EnhancedContact(
      contact: contact,
      lastSeenAgo: lastSeenAgo,
      isRecentlyActive: isRecentlyActive,
      interactionCount: interactionCount,
      averageResponseTime: averageResponseTime,
      groupMemberships: _getContactGroupMemberships(contact.publicKey),
    );
  }
  
  /// Perform text-based search on contacts
  List<EnhancedContact> _performTextSearch(List<EnhancedContact> contacts, String query) {
    final searchTerms = query.toLowerCase().split(' ').where((term) => term.isNotEmpty).toList();
    
    return contacts.where((contact) {
      final searchableText = '${contact.displayName} ${contact.publicKey}'.toLowerCase();
      
      // All search terms must be found
      return searchTerms.every((term) => searchableText.contains(term));
    }).toList();
  }
  
  /// Apply advanced search filters
  List<EnhancedContact> _applySearchFilter(List<EnhancedContact> contacts, ContactSearchFilter filter) {
    return contacts.where((contact) {
      if (filter.securityLevel != null && contact.securityLevel != filter.securityLevel) {
        return false;
      }
      
      if (filter.trustStatus != null && contact.trustStatus != filter.trustStatus) {
        return false;
      }
      
      if (filter.onlyRecentlyActive && !contact.isRecentlyActive) {
        return false;
      }
      
      if (filter.minInteractions != null && contact.interactionCount < filter.minInteractions!) {
        return false;
      }
      
      return true;
    }).toList();
  }
  
  /// Sort contacts by specified criteria
  List<EnhancedContact> _sortContacts(
    List<EnhancedContact> contacts, 
    ContactSortOption sortBy, 
    bool ascending
  ) {
    contacts.sort((a, b) {
      int comparison;
      
      switch (sortBy) {
        case ContactSortOption.name:
          comparison = a.displayName.compareTo(b.displayName);
          break;
        case ContactSortOption.lastSeen:
          comparison = a.lastSeen.compareTo(b.lastSeen);
          break;
        case ContactSortOption.securityLevel:
          comparison = a.securityLevel.index.compareTo(b.securityLevel.index);
          break;
        case ContactSortOption.interactions:
          comparison = a.interactionCount.compareTo(b.interactionCount);
          break;
        case ContactSortOption.dateAdded:
          comparison = a.firstSeen.compareTo(b.firstSeen);
          break;
      }
      
      return ascending ? comparison : -comparison;
    });
    
    return contacts;
  }
  
  /// Add search query to history
  void _addToSearchHistory(String query) {
    _recentSearches.remove(query); // Remove if already exists
    _recentSearches.add(query);
    
    // Keep only last 10 searches
    if (_recentSearches.length > 10) {
      _recentSearches.removeAt(0);
    }
    
    _saveSearchHistory();
  }
  
  /// Delete contact from repository
  Future<void> _deleteContactFromRepository(String publicKey) async {
    try {
      final success = await _contactRepository.deleteContact(publicKey);
      if (success) {
        _logger.info('Successfully deleted contact: ${publicKey.substring(0, 16)}...');
      } else {
        _logger.warning('Failed to delete contact - not found: ${publicKey.substring(0, 16)}...');
      }
    } catch (e) {
      _logger.severe('Error deleting contact: $e');
      throw Exception('Failed to delete contact: $e');
    }
  }
  
  /// Remove contact from all groups
  Future<void> _removeContactFromAllGroups(String publicKey) async {
    bool modified = false;
    for (final group in _contactGroups.values) {
      if (group.memberPublicKeys.remove(publicKey)) {
        group.lastModified = DateTime.now();
        modified = true;
      }
    }
    
    if (modified) {
      await _saveContactGroups();
    }
  }
  
  /// Calculate real interaction metrics based on message history
  Future<int> _calculateInteractionCount(String publicKey) async {
    try {
      final messages = await _messageRepository.getMessagesForContact(publicKey);
      return messages.length;
    } catch (e) {
      _logger.warning('Failed to calculate interaction count: $e');
      return 0;
    }
  }

  
  /// Calculate real average response time based on message timestamps
  Future<Duration> _calculateAverageResponseTime(String publicKey) async {
    try {
      final messages = await _messageRepository.getMessagesForContact(publicKey);
      if (messages.length < 2) {
        return const Duration(minutes: 5); // Default for contacts with few messages
      }

      // Sort messages by timestamp
      messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      final responseTimes = <Duration>[];
      DateTime? lastMyMessageTime;

      for (final message in messages) {
        if (message.isFromMe) {
          lastMyMessageTime = message.timestamp;
        } else if (lastMyMessageTime != null) {
          // This is a response to my message
          final responseTime = message.timestamp.difference(lastMyMessageTime);
          if (responseTime.inMinutes > 0 && responseTime.inHours < 24) {
            // Only count reasonable response times (positive and less than 24 hours)
            responseTimes.add(responseTime);
          }
        }
      }

      if (responseTimes.isEmpty) {
        return const Duration(minutes: 5); // Default fallback
      }

      // Calculate average response time
      final totalMs = responseTimes.fold<int>(0, (sum, duration) => sum + duration.inMilliseconds);
      return Duration(milliseconds: totalMs ~/ responseTimes.length);
    } catch (e) {
      _logger.warning('Failed to calculate response time: $e');
      return const Duration(minutes: 5); // Default fallback
    }
  }

  
  /// Get contact group memberships
  List<String> _getContactGroupMemberships(String publicKey) {
    return _contactGroups.values
        .where((group) => group.memberPublicKeys.contains(publicKey))
        .map((group) => group.name)
        .toList();
  }
  
  /// Calculate average contact age
  Duration _calculateAverageContactAge(List<EnhancedContact> contacts) {
    if (contacts.isEmpty) return Duration.zero;
    
    final now = DateTime.now();
    final totalAge = contacts
        .map((c) => now.difference(c.firstSeen).inDays)
        .reduce((a, b) => a + b);
    
    return Duration(days: totalAge ~/ contacts.length);
  }
  
  /// Generate unique group ID
  String _generateGroupId() {
    return 'group_${DateTime.now().millisecondsSinceEpoch}';
  }
  
  /// Prepare contact data for export
  Map<String, dynamic> _prepareExportData(List<EnhancedContact> contacts, bool includeSecurityData) {
    return {
      'export_timestamp': DateTime.now().toIso8601String(),
      'contact_count': contacts.length,
      'include_security_data': includeSecurityData,
      'contacts': contacts.map((contact) => {
        'display_name': contact.displayName,
        'public_key': includeSecurityData ? contact.publicKey : '[REDACTED]',
        'trust_status': contact.trustStatus.name,
        'security_level': includeSecurityData ? contact.securityLevel.name : '[REDACTED]',
        'first_seen': contact.firstSeen.toIso8601String(),
        'last_seen': contact.lastSeen.toIso8601String(),
        'interaction_count': contact.interactionCount,
        'group_memberships': contact.groupMemberships,
      }).toList(),
    };
  }
  
  /// Convert export data to CSV format
  String _convertToCSV(Map<String, dynamic> exportData) {
    final contacts = exportData['contacts'] as List<dynamic>;
    
    final csvLines = <String>[];
    csvLines.add('Display Name,Trust Status,First Seen,Last Seen,Interaction Count,Groups');
    
    for (final contact in contacts) {
      final groups = (contact['group_memberships'] as List<dynamic>).join(';');
      csvLines.add([
        contact['display_name'],
        contact['trust_status'],
        contact['first_seen'],
        contact['last_seen'],
        contact['interaction_count'].toString(),
        groups,
      ].map((field) => '"$field"').join(','));
    }
    
    return csvLines.join('\n');
  }
  
  /// Load settings from persistent storage
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _allowAddressBookSync = prefs.getBool('${_settingsPrefix}address_book_sync') ?? false;
      _allowContactExport = prefs.getBool('${_settingsPrefix}contact_export') ?? false;
      _enableContactAnalytics = prefs.getBool('${_settingsPrefix}analytics') ?? false;
    } catch (e) {
      _logger.warning('Failed to load contact management settings: $e');
    }
  }
  
  /// Save settings to persistent storage
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('${_settingsPrefix}address_book_sync', _allowAddressBookSync);
      await prefs.setBool('${_settingsPrefix}contact_export', _allowContactExport);
      await prefs.setBool('${_settingsPrefix}analytics', _enableContactAnalytics);
    } catch (e) {
      _logger.warning('Failed to save contact management settings: $e');
    }
  }
  
  /// Load search history from storage
  Future<void> _loadSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final history = prefs.getStringList(_searchHistoryKey) ?? [];
      _recentSearches.clear();
      _recentSearches.addAll(history);
    } catch (e) {
      _logger.warning('Failed to load search history: $e');
    }
  }
  
  /// Save search history to storage
  Future<void> _saveSearchHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_searchHistoryKey, _recentSearches);
    } catch (e) {
      _logger.warning('Failed to save search history: $e');
    }
  }
  
  /// Load contact groups from storage
  Future<void> _loadContactGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final groupsJson = prefs.getStringList(_contactGroupsKey) ?? [];
      
      _contactGroups.clear();
      for (final json in groupsJson) {
        final group = ContactGroup.fromJson(jsonDecode(json));
        _contactGroups[group.name] = group;
      }
    } catch (e) {
      _logger.warning('Failed to load contact groups: $e');
    }
  }
  
  /// Save contact groups to storage
  Future<void> _saveContactGroups() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final groupsJson = _contactGroups.values
          .map((group) => jsonEncode(group.toJson()))
          .toList();
      
      await prefs.setStringList(_contactGroupsKey, groupsJson);
    } catch (e) {
      _logger.warning('Failed to save contact groups: $e');
    }
  }

  /// Save exported data to local storage
  Future<void> _saveExportedData(String data, ContactExportFormat format) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final key = 'contact_export_${format.name}_$timestamp';
      await prefs.setString(key, data);
      
      // Also save export metadata
      final exports = prefs.getStringList('contact_exports') ?? [];
      exports.add(jsonEncode({
        'key': key,
        'format': format.name,
        'timestamp': timestamp,
        'size': data.length,
      }));
      await prefs.setStringList('contact_exports', exports);
      
      _logger.info('Exported data saved with key: $key');
    } catch (e) {
      _logger.warning('Failed to save exported data: $e');
    }
  }

}

// Enums and data classes would be defined in separate files in a real app
enum ContactSortOption { name, lastSeen, securityLevel, interactions, dateAdded }
enum ContactExportFormat { json, csv }

class ContactSearchFilter {
  final SecurityLevel? securityLevel;
  final TrustStatus? trustStatus;
  final bool onlyRecentlyActive;
  final int? minInteractions;
  
  const ContactSearchFilter({
    this.securityLevel,
    this.trustStatus,
    this.onlyRecentlyActive = false,
    this.minInteractions,
  });
}

class ContactSearchResult {
  final List<EnhancedContact> contacts;
  final String query;
  final int totalResults;
  final Duration searchTime;
  final ContactSearchFilter? appliedFilter;
  final ContactSortOption sortedBy;
  final bool ascending;
  
  const ContactSearchResult({
    required this.contacts,
    required this.query,
    required this.totalResults,
    required this.searchTime,
    this.appliedFilter,
    required this.sortedBy,
    required this.ascending,
  });
  
  factory ContactSearchResult.empty(String query) => ContactSearchResult(
    contacts: [],
    query: query,
    totalResults: 0,
    searchTime: Duration.zero,
    sortedBy: ContactSortOption.name,
    ascending: true,
  );
}

class ContactOperationResult {
  final bool success;
  final String message;
  
  const ContactOperationResult._(this.success, this.message);
  
  factory ContactOperationResult.success(String message) => ContactOperationResult._(true, message);
  factory ContactOperationResult.failure(String message) => ContactOperationResult._(false, message);
}

class BulkOperationResult {
  final int totalOperations;
  final int successCount;
  final int failureCount;
  final List<String> failedItems;
  
  const BulkOperationResult({
    required this.totalOperations,
    required this.successCount,
    required this.failureCount,
    required this.failedItems,
  });
  
  double get successRate => totalOperations > 0 ? successCount / totalOperations : 0.0;
}

class ContactAnalytics {
  final int totalContacts;
  final int verifiedContacts;
  final int highSecurityContacts;
  final Map<SecurityLevel, int> securityLevelDistribution;
  final Map<TrustStatus, int> trustStatusDistribution;
  final EnhancedContact? oldestContact;
  final EnhancedContact? newestContact;
  final Duration averageContactAge;
  
  const ContactAnalytics({
    required this.totalContacts,
    required this.verifiedContacts,
    required this.highSecurityContacts,
    required this.securityLevelDistribution,
    required this.trustStatusDistribution,
    this.oldestContact,
    this.newestContact,
    required this.averageContactAge,
  });
  
  factory ContactAnalytics.empty() => ContactAnalytics(
    totalContacts: 0,
    verifiedContacts: 0,
    highSecurityContacts: 0,
    securityLevelDistribution: {},
    trustStatusDistribution: {},
    averageContactAge: Duration.zero,
  );
}

class ContactPrivacySettings {
  final bool allowAddressBookSync;
  final bool allowContactExport;
  final bool enableContactAnalytics;
  
  const ContactPrivacySettings({
    required this.allowAddressBookSync,
    required this.allowContactExport,
    required this.enableContactAnalytics,
  });
}

class ContactGroup {
  final String id;
  final String name;
  final String description;
  final Set<String> memberPublicKeys;
  final DateTime createdAt;
  DateTime lastModified;
  
  ContactGroup({
    required this.id,
    required this.name,
    required this.description,
    required this.memberPublicKeys,
    required this.createdAt,
    required this.lastModified,
  });
  
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'member_public_keys': memberPublicKeys.toList(),
    'created_at': createdAt.millisecondsSinceEpoch,
    'last_modified': lastModified.millisecondsSinceEpoch,
  };
  
  factory ContactGroup.fromJson(Map<String, dynamic> json) => ContactGroup(
    id: json['id'],
    name: json['name'],
    description: json['description'],
    memberPublicKeys: Set<String>.from(json['member_public_keys']),
    createdAt: DateTime.fromMillisecondsSinceEpoch(json['created_at']),
    lastModified: DateTime.fromMillisecondsSinceEpoch(json['last_modified']),
  );
}