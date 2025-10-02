# SQLite Migration Plan - pak_connect

**Status**: Ready for Implementation
**Estimated Time**: 3-4 days
**Risk Level**: Moderate (data migration involved)

---

## Table of Contents
1. [Current State Analysis](#current-state-analysis)
2. [SQLite Schema Design](#sqlite-schema-design)
3. [Migration Strategy](#migration-strategy)
4. [Implementation Steps](#implementation-steps)
5. [Media Storage Architecture](#media-storage-architecture)
6. [Testing Strategy](#testing-strategy)
7. [Rollback Plan](#rollback-plan)

---

## Current State Analysis

### Files Using SharedPreferences

| Repository | Data Stored | Current Issues |
|------------|-------------|----------------|
| `user_preferences.dart` | Username, device ID | ✅ Low volume, acceptable |
| `message_repository.dart` | All messages as JSON list | ❌ O(n) operations, 2MB limit risk |
| `contact_repository.dart` | All contacts as JSON list | ❌ O(n) lookups, no indexing |
| `chats_repository.dart` | Unread counts, last seen data | ❌ String-encoded maps, fragile |
| `archive_repository.dart` | Archived chats + search index | ❌ Complex manual indexing |

### Performance Bottlenecks

```dart
// Example: MessageRepository.getMessages() - LOADS ALL MESSAGES
Future<List<Message>> getMessages(String chatId) async {
  final messagesJson = prefs.getStringList(_messagesKey) ?? [];  // ❌ Load ALL
  return messagesJson
    .map((json) => Message.fromJson(jsonDecode(json)))           // ❌ Parse ALL
    .where((message) => message.chatId == chatId)                // ❌ Filter ALL
    .toList();
}
```

**With 10,000 messages**: This loads/parses 10MB+ on every operation.

---

## SQLite Schema Design

### Core Tables

```sql
-- User Profile (replaces user_preferences.dart partially)
CREATE TABLE user_profile (
  id INTEGER PRIMARY KEY CHECK (id = 1),  -- Singleton table
  username TEXT NOT NULL,
  device_id TEXT NOT NULL UNIQUE,
  public_key TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Contacts (replaces contact_repository.dart)
CREATE TABLE contacts (
  public_key TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  trust_status INTEGER NOT NULL,          -- TrustStatus enum index
  security_level INTEGER NOT NULL,        -- SecurityLevel enum index
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  last_security_sync INTEGER,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX idx_contacts_display_name ON contacts(display_name);
CREATE INDEX idx_contacts_last_seen ON contacts(last_seen DESC);

-- Chats (replaces chats_repository.dart)
CREATE TABLE chats (
  chat_id TEXT PRIMARY KEY,
  contact_public_key TEXT,
  contact_name TEXT NOT NULL,
  last_message_time INTEGER,
  unread_count INTEGER DEFAULT 0,
  is_archived INTEGER DEFAULT 0,          -- Boolean as 0/1
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY (contact_public_key) REFERENCES contacts(public_key) ON DELETE CASCADE
);

CREATE INDEX idx_chats_contact ON chats(contact_public_key);
CREATE INDEX idx_chats_last_message ON chats(last_message_time DESC);
CREATE INDEX idx_chats_unread ON chats(unread_count) WHERE unread_count > 0;

-- Messages (replaces message_repository.dart)
CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  is_from_me INTEGER NOT NULL,            -- Boolean as 0/1
  status INTEGER NOT NULL,                -- MessageStatus enum index
  has_media INTEGER DEFAULT 0,            -- Boolean as 0/1
  media_type TEXT,                        -- 'image', 'voice', null
  created_at INTEGER NOT NULL,
  FOREIGN KEY (chat_id) REFERENCES chats(chat_id) ON DELETE CASCADE
);

CREATE INDEX idx_messages_chat ON messages(chat_id, timestamp DESC);
CREATE INDEX idx_messages_status ON messages(status) WHERE status = 3; -- Failed messages
CREATE INDEX idx_messages_media ON messages(chat_id) WHERE has_media = 1;

-- Media Metadata (NEW - for voice/images)
CREATE TABLE media (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL UNIQUE,
  file_path TEXT NOT NULL,
  file_type TEXT NOT NULL,               -- MIME type: image/jpeg, audio/m4a
  file_size INTEGER NOT NULL,            -- Bytes
  duration INTEGER,                      -- Seconds (for voice)
  thumbnail_path TEXT,                   -- For images/videos
  download_status INTEGER DEFAULT 0,     -- 0=pending, 1=downloading, 2=complete, 3=failed
  created_at INTEGER NOT NULL,
  FOREIGN KEY (message_id) REFERENCES messages(id) ON DELETE CASCADE
);

CREATE INDEX idx_media_message ON media(message_id);
CREATE INDEX idx_media_status ON media(download_status);

-- Archived Chats (replaces archive_repository.dart)
CREATE TABLE archived_chats (
  archive_id TEXT PRIMARY KEY,
  original_chat_id TEXT NOT NULL,
  contact_name TEXT NOT NULL,
  contact_public_key TEXT,
  archived_at INTEGER NOT NULL,
  archive_reason TEXT,
  message_count INTEGER NOT NULL,
  estimated_size INTEGER NOT NULL,
  is_compressed INTEGER DEFAULT 0,
  custom_data TEXT,                      -- JSON blob
  created_at INTEGER NOT NULL
);

CREATE INDEX idx_archived_chats_date ON archived_chats(archived_at DESC);
CREATE INDEX idx_archived_chats_contact ON archived_chats(contact_name);

-- Archived Messages (stores messages from archived chats)
CREATE TABLE archived_messages (
  id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  original_message_id TEXT NOT NULL,
  content TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  is_from_me INTEGER NOT NULL,
  status INTEGER NOT NULL,
  has_media INTEGER DEFAULT 0,
  media_type TEXT,
  was_starred INTEGER DEFAULT 0,
  was_edited INTEGER DEFAULT 0,
  FOREIGN KEY (archive_id) REFERENCES archived_chats(archive_id) ON DELETE CASCADE
);

CREATE INDEX idx_archived_messages_archive ON archived_messages(archive_id, timestamp);

-- Full-Text Search for Archives (SQLite FTS5)
CREATE VIRTUAL TABLE archived_messages_fts USING fts5(
  content,
  content=archived_messages,
  content_rowid=rowid
);

-- Triggers to keep FTS in sync
CREATE TRIGGER archived_messages_ai AFTER INSERT ON archived_messages BEGIN
  INSERT INTO archived_messages_fts(rowid, content)
  VALUES (new.rowid, new.content);
END;

CREATE TRIGGER archived_messages_ad AFTER DELETE ON archived_messages BEGIN
  DELETE FROM archived_messages_fts WHERE rowid = old.rowid;
END;

CREATE TRIGGER archived_messages_au AFTER UPDATE ON archived_messages BEGIN
  UPDATE archived_messages_fts
  SET content = new.content
  WHERE rowid = old.rowid;
END;
```

---

## Migration Strategy

### Phase 1: Preparation (Day 1)

#### 1.1 Add Dependencies

```yaml
# pubspec.yaml
dependencies:
  sqflite: ^2.3.0
  path_provider: ^2.1.0
  path: ^1.8.3

  # For future media support
  image_picker: ^1.0.4
  record: ^5.0.0
```

#### 1.2 Create Database Helper

**New File**: `lib/data/database/database_helper.dart`

```dart
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('pak_connect.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
      onConfigure: _onConfigure,
    );
  }

  Future _onConfigure(Database db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }

  Future _createDB(Database db, int version) async {
    // Execute schema from above
    await db.execute('''CREATE TABLE user_profile (...);''');
    await db.execute('''CREATE TABLE contacts (...);''');
    // ... rest of schema
  }

  Future close() async {
    final db = await instance.database;
    db.close();
  }
}
```

#### 1.3 Create Data Migration Service

**New File**: `lib/data/database/migration_service.dart`

```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';
import '../repositories/contact_repository.dart';
import '../repositories/message_repository.dart';
import 'database_helper.dart';

class MigrationService {
  static final _logger = Logger('MigrationService');
  static const _migrationCompletedKey = 'sqlite_migration_completed_v1';

  /// Check if migration is needed
  Future<bool> isMigrationNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    return !(prefs.getBool(_migrationCompletedKey) ?? false);
  }

  /// Perform full migration from SharedPreferences to SQLite
  Future<MigrationResult> migrateData() async {
    final startTime = DateTime.now();
    _logger.info('🔄 Starting data migration to SQLite...');

    try {
      final db = await DatabaseHelper.instance.database;
      final prefs = await SharedPreferences.getInstance();

      int migratedContacts = 0;
      int migratedMessages = 0;
      int migratedChats = 0;

      // 1. Migrate user profile
      await _migrateUserProfile(db, prefs);

      // 2. Migrate contacts
      migratedContacts = await _migrateContacts(db);

      // 3. Migrate messages
      migratedMessages = await _migrateMessages(db);

      // 4. Migrate chats metadata
      migratedChats = await _migrateChats(db, prefs);

      // 5. Mark migration complete
      await prefs.setBool(_migrationCompletedKey, true);

      final duration = DateTime.now().difference(startTime);
      _logger.info('✅ Migration completed in ${duration.inSeconds}s');

      return MigrationResult.success(
        contacts: migratedContacts,
        messages: migratedMessages,
        chats: migratedChats,
        duration: duration,
      );

    } catch (e, stackTrace) {
      _logger.severe('❌ Migration failed: $e', e, stackTrace);
      return MigrationResult.failure(error: e.toString());
    }
  }

  Future<void> _migrateUserProfile(Database db, SharedPreferences prefs) async {
    final username = prefs.getString('user_display_name') ?? 'User';
    final deviceId = prefs.getString('my_persistent_device_id') ?? '';

    // Public key stored in flutter_secure_storage, handled separately
    await db.insert('user_profile', {
      'id': 1,
      'username': username,
      'device_id': deviceId,
      'public_key': '', // Will be populated from secure storage
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int> _migrateContacts(Database db) async {
    final contactRepo = ContactRepository();
    final contacts = await contactRepo.getAllContacts();

    int count = 0;
    for (final contact in contacts.values) {
      await db.insert('contacts', {
        'public_key': contact.publicKey,
        'display_name': contact.displayName,
        'trust_status': contact.trustStatus.index,
        'security_level': contact.securityLevel.index,
        'first_seen': contact.firstSeen.millisecondsSinceEpoch,
        'last_seen': contact.lastSeen.millisecondsSinceEpoch,
        'last_security_sync': contact.lastSecuritySync?.millisecondsSinceEpoch,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      count++;
    }

    _logger.info('✅ Migrated $count contacts');
    return count;
  }

  Future<int> _migrateMessages(Database db) async {
    final messageRepo = MessageRepository();
    final messages = await messageRepo.getAllMessages();

    int count = 0;
    for (final message in messages) {
      await db.insert('messages', {
        'id': message.id,
        'chat_id': message.chatId,
        'content': message.content,
        'timestamp': message.timestamp.millisecondsSinceEpoch,
        'is_from_me': message.isFromMe ? 1 : 0,
        'status': message.status.index,
        'has_media': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      count++;
    }

    _logger.info('✅ Migrated $count messages');
    return count;
  }

  Future<int> _migrateChats(Database db, SharedPreferences prefs) async {
    // Extract chat metadata from SharedPreferences
    final unreadData = prefs.getString('chat_unread_counts') ?? '';
    final unreadCounts = <String, int>{};

    if (unreadData.isNotEmpty) {
      for (final entry in unreadData.split(',')) {
        final parts = entry.split(':');
        if (parts.length == 2) {
          unreadCounts[parts[0]] = int.tryParse(parts[1]) ?? 0;
        }
      }
    }

    // Get unique chat IDs from messages
    final result = await db.query(
      'messages',
      columns: ['DISTINCT chat_id', 'MAX(timestamp) as last_message'],
      groupBy: 'chat_id',
    );

    int count = 0;
    for (final row in result) {
      final chatId = row['chat_id'] as String;
      await db.insert('chats', {
        'chat_id': chatId,
        'contact_name': 'Unknown', // Will be updated by app logic
        'last_message_time': row['last_message'],
        'unread_count': unreadCounts[chatId] ?? 0,
        'is_archived': 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      });
      count++;
    }

    _logger.info('✅ Migrated $count chats');
    return count;
  }
}

class MigrationResult {
  final bool success;
  final int contacts;
  final int messages;
  final int chats;
  final Duration? duration;
  final String? error;

  MigrationResult.success({
    required this.contacts,
    required this.messages,
    required this.chats,
    required this.duration,
  }) : success = true, error = null;

  MigrationResult.failure({required this.error})
    : success = false,
      contacts = 0,
      messages = 0,
      chats = 0,
      duration = null;
}
```

---

### Phase 2: Repository Refactoring (Day 2-3)

#### 2.1 Update MessageRepository

**File**: `lib/data/repositories/message_repository.dart`

```dart
import 'package:sqflite/sqflite.dart';
import '../database/database_helper.dart';
import '../../domain/entities/message.dart';

class MessageRepository {
  final _dbHelper = DatabaseHelper.instance;

  /// Get messages for a specific chat (OPTIMIZED)
  Future<List<Message>> getMessages(String chatId) async {
    final db = await _dbHelper.database;

    final results = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'timestamp ASC',
    );

    return results.map((row) => Message.fromMap(row)).toList();
  }

  /// Save a new message
  Future<void> saveMessage(Message message) async {
    final db = await _dbHelper.database;

    await db.insert(
      'messages',
      message.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Update chat's last message time
    await db.update(
      'chats',
      {
        'last_message_time': message.timestamp.millisecondsSinceEpoch,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'chat_id = ?',
      whereArgs: [message.chatId],
    );
  }

  /// Update message status
  Future<void> updateMessage(Message message) async {
    final db = await _dbHelper.database;

    await db.update(
      'messages',
      message.toMap(),
      where: 'id = ?',
      whereArgs: [message.id],
    );
  }

  /// Delete all messages in a chat
  Future<void> clearMessages(String chatId) async {
    final db = await _dbHelper.database;

    await db.delete(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
    );
  }

  /// Delete specific message
  Future<bool> deleteMessage(String messageId) async {
    final db = await _dbHelper.database;

    final count = await db.delete(
      'messages',
      where: 'id = ?',
      whereArgs: [messageId],
    );

    return count > 0;
  }

  /// Get all messages (for backward compatibility)
  Future<List<Message>> getAllMessages() async {
    final db = await _dbHelper.database;

    final results = await db.query(
      'messages',
      orderBy: 'timestamp ASC',
    );

    return results.map((row) => Message.fromMap(row)).toList();
  }

  /// Get messages for a contact
  Future<List<Message>> getMessagesForContact(String publicKey) async {
    final db = await _dbHelper.database;

    final results = await db.query(
      'messages',
      where: 'chat_id LIKE ?',
      whereArgs: ['%$publicKey%'],
      orderBy: 'timestamp ASC',
    );

    return results.map((row) => Message.fromMap(row)).toList();
  }
}
```

#### 2.2 Update Message Entity

**File**: `lib/domain/entities/message.dart`

```dart
class Message {
  final String id;
  final String chatId;
  final String content;
  final DateTime timestamp;
  final bool isFromMe;
  final MessageStatus status;

  Message({
    required this.id,
    required this.chatId,
    required this.content,
    required this.timestamp,
    required this.isFromMe,
    required this.status,
  });

  // Existing JSON methods (keep for backward compatibility)
  Map<String, dynamic> toJson() => {
    'id': id,
    'chatId': chatId,
    'content': content,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'isFromMe': isFromMe,
    'status': status.index,
  };

  factory Message.fromJson(Map<String, dynamic> json) => Message(
    id: json['id'],
    chatId: json['chatId'],
    content: json['content'],
    timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp']),
    isFromMe: json['isFromMe'],
    status: MessageStatus.values[json['status']],
  );

  // NEW: SQLite database methods
  Map<String, dynamic> toMap() => {
    'id': id,
    'chat_id': chatId,
    'content': content,
    'timestamp': timestamp.millisecondsSinceEpoch,
    'is_from_me': isFromMe ? 1 : 0,
    'status': status.index,
    'has_media': 0,
    'created_at': DateTime.now().millisecondsSinceEpoch,
  };

  factory Message.fromMap(Map<String, dynamic> map) => Message(
    id: map['id'],
    chatId: map['chat_id'],
    content: map['content'],
    timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp']),
    isFromMe: map['is_from_me'] == 1,
    status: MessageStatus.values[map['status']],
  );

  Message copyWith({MessageStatus? status}) => Message(
    id: id,
    chatId: chatId,
    content: content,
    timestamp: timestamp,
    isFromMe: isFromMe,
    status: status ?? this.status,
  );
}

enum MessageStatus {
  sending,
  sent,
  delivered,
  failed,
}
```

#### 2.3 Update ContactRepository (Similar Pattern)

**Changes**:
- Replace `prefs.getStringList()` with `db.query()`
- Replace `prefs.setStringList()` with `db.insert()/update()`
- Add `toMap()/fromMap()` to Contact entity
- Keep `getAllContacts()` signature for compatibility

#### 2.4 Update ChatsRepository (Similar Pattern)

**Changes**:
- JOIN queries to get chat info with contact details
- Use SQL for unread count management
- Efficient filtering with WHERE clauses

---

### Phase 3: Archive System Migration (Day 3)

#### 3.1 Update ArchiveRepository

**Key Changes**:

```dart
/// Archive a chat (SQLite version)
Future<ArchiveOperationResult> archiveChat({
  required String chatId,
  String? archiveReason,
}) async {
  final db = await _dbHelper.database;

  await db.transaction((txn) async {
    // 1. Get chat metadata
    final chatData = await txn.query('chats', where: 'chat_id = ?', whereArgs: [chatId]);

    // 2. Create archive record
    final archiveId = _generateArchiveId(chatId);
    await txn.insert('archived_chats', {
      'archive_id': archiveId,
      'original_chat_id': chatId,
      'archived_at': DateTime.now().millisecondsSinceEpoch,
      'archive_reason': archiveReason,
      // ... other fields
    });

    // 3. Move messages to archived_messages
    await txn.execute('''
      INSERT INTO archived_messages (
        id, archive_id, original_message_id, content, timestamp, is_from_me, status
      )
      SELECT
        id || '_archived', ?, id, content, timestamp, is_from_me, status
      FROM messages
      WHERE chat_id = ?
    ''', [archiveId, chatId]);

    // 4. Delete original messages
    await txn.delete('messages', where: 'chat_id = ?', whereArgs: [chatId]);

    // 5. Delete chat
    await txn.delete('chats', where: 'chat_id = ?', whereArgs: [chatId]);
  });
}

/// Search archives using FTS5
Future<ArchiveSearchResult> searchArchives({
  required String query,
  int limit = 50,
}) async {
  final db = await _dbHelper.database;

  // Use FTS5 for lightning-fast full-text search
  final results = await db.rawQuery('''
    SELECT
      am.*,
      ac.contact_name,
      ac.archived_at
    FROM archived_messages_fts fts
    JOIN archived_messages am ON fts.rowid = am.rowid
    JOIN archived_chats ac ON am.archive_id = ac.archive_id
    WHERE archived_messages_fts MATCH ?
    ORDER BY rank
    LIMIT ?
  ''', [query, limit]);

  // Convert results to domain objects
  return ArchiveSearchResult.fromDatabase(results);
}
```

**Benefits**:
- Remove ALL manual search indexing code (lines 589-909 in current implementation)
- FTS5 handles tokenization, ranking, phrase matching automatically
- 10-100x faster than current implementation

---

## Media Storage Architecture

### Directory Structure

```
/data/user/0/com.example.pak_connect/
├── databases/
│   └── pak_connect.db              # SQLite database
├── files/
│   └── media/
│       ├── images/
│       │   ├── {chatId}/
│       │   │   ├── {messageId}.jpg
│       │   │   └── {messageId}_thumb.jpg
│       │   └── .nomedia           # Hide from gallery
│       ├── voice/
│       │   └── {chatId}/
│       │       └── {messageId}.m4a
│       └── temp/                  # In-progress downloads
│           └── {messageId}.tmp
└── cache/
    └── thumbnails/                # Auto-cleared by system
```

### Media Repository

**New File**: `lib/data/repositories/media_repository.dart`

```dart
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import '../database/database_helper.dart';

enum MediaType { image, voice }

class MediaRepository {
  final _dbHelper = DatabaseHelper.instance;

  /// Save media file and metadata
  Future<String> saveMedia({
    required File file,
    required String messageId,
    required String chatId,
    required MediaType type,
    int? duration,
  }) async {
    // 1. Create directory structure
    final mediaDir = await _getMediaDirectory(chatId, type);
    await mediaDir.create(recursive: true);

    // 2. Determine file extension
    final extension = type == MediaType.image ? 'jpg' : 'm4a';
    final fileName = '$messageId.$extension';
    final destPath = path.join(mediaDir.path, fileName);

    // 3. Copy file to app storage
    final destFile = await file.copy(destPath);

    // 4. Generate thumbnail for images
    String? thumbnailPath;
    if (type == MediaType.image) {
      thumbnailPath = await _generateThumbnail(destFile, messageId);
    }

    // 5. Save metadata to database
    final db = await _dbHelper.database;
    await db.insert('media', {
      'message_id': messageId,
      'file_path': destPath,
      'file_type': type == MediaType.image ? 'image/jpeg' : 'audio/m4a',
      'file_size': await destFile.length(),
      'duration': duration,
      'thumbnail_path': thumbnailPath,
      'download_status': 2, // Complete
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    // 6. Update message has_media flag
    await db.update(
      'messages',
      {
        'has_media': 1,
        'media_type': type == MediaType.image ? 'image' : 'voice',
      },
      where: 'id = ?',
      whereArgs: [messageId],
    );

    return destPath;
  }

  /// Get media file path
  Future<String?> getMediaPath(String messageId) async {
    final db = await _dbHelper.database;
    final result = await db.query(
      'media',
      columns: ['file_path'],
      where: 'message_id = ? AND download_status = 2',
      whereArgs: [messageId],
    );

    if (result.isEmpty) return null;

    final filePath = result.first['file_path'] as String;
    final file = File(filePath);

    // Verify file exists
    if (!await file.exists()) {
      await _markMediaAsMissing(messageId);
      return null;
    }

    return filePath;
  }

  /// Delete media file and metadata
  Future<void> deleteMedia(String messageId) async {
    final db = await _dbHelper.database;

    // Get file path before deleting metadata
    final result = await db.query(
      'media',
      where: 'message_id = ?',
      whereArgs: [messageId],
    );

    if (result.isNotEmpty) {
      final filePath = result.first['file_path'] as String;
      final thumbnailPath = result.first['thumbnail_path'] as String?;

      // Delete files
      await _deleteFile(filePath);
      if (thumbnailPath != null) await _deleteFile(thumbnailPath);

      // Delete metadata
      await db.delete('media', where: 'message_id = ?', whereArgs: [messageId]);
    }
  }

  /// Get all media for a chat
  Future<List<MediaInfo>> getChatMedia(String chatId, {MediaType? type}) async {
    final db = await _dbHelper.database;

    var query = '''
      SELECT m.*, msg.timestamp
      FROM media m
      JOIN messages msg ON m.message_id = msg.id
      WHERE msg.chat_id = ?
    ''';

    if (type != null) {
      query += ' AND m.file_type LIKE ?';
    }

    query += ' ORDER BY msg.timestamp DESC';

    final args = type == null
      ? [chatId]
      : [chatId, type == MediaType.image ? 'image/%' : 'audio/%'];

    final results = await db.rawQuery(query, args);
    return results.map((row) => MediaInfo.fromMap(row)).toList();
  }

  /// Calculate total media size for storage management
  Future<int> getTotalMediaSize() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery('SELECT SUM(file_size) as total FROM media');
    return result.first['total'] as int? ?? 0;
  }

  // Private helpers

  Future<Directory> _getMediaDirectory(String chatId, MediaType type) async {
    final appDir = await getApplicationDocumentsDirectory();
    final typeDir = type == MediaType.image ? 'images' : 'voice';
    return Directory(path.join(appDir.path, 'media', typeDir, chatId));
  }

  Future<String> _generateThumbnail(File imageFile, String messageId) async {
    // TODO: Implement actual thumbnail generation
    // For now, just return placeholder path
    final appDir = await getApplicationDocumentsDirectory();
    return path.join(appDir.path, 'cache', 'thumbnails', '${messageId}_thumb.jpg');
  }

  Future<void> _deleteFile(String filePath) async {
    try {
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      // Log but don't throw
    }
  }

  Future<void> _markMediaAsMissing(String messageId) async {
    final db = await _dbHelper.database;
    await db.update(
      'media',
      {'download_status': 3}, // Failed
      where: 'message_id = ?',
      whereArgs: [messageId],
    );
  }
}

class MediaInfo {
  final String messageId;
  final String filePath;
  final String fileType;
  final int fileSize;
  final int? duration;
  final String? thumbnailPath;

  MediaInfo({
    required this.messageId,
    required this.filePath,
    required this.fileType,
    required this.fileSize,
    this.duration,
    this.thumbnailPath,
  });

  factory MediaInfo.fromMap(Map<String, dynamic> map) => MediaInfo(
    messageId: map['message_id'],
    filePath: map['file_path'],
    fileType: map['file_type'],
    fileSize: map['file_size'],
    duration: map['duration'],
    thumbnailPath: map['thumbnail_path'],
  );
}
```

---

## Implementation Steps

### Day 1: Setup & Migration Preparation

**Morning (2-3 hours)**
1. ✅ Add dependencies to `pubspec.yaml`
2. ✅ Run `flutter pub get`
3. ✅ Create `lib/data/database/` directory
4. ✅ Implement `database_helper.dart` with schema
5. ✅ Test database creation on emulator

**Afternoon (3-4 hours)**
6. ✅ Implement `migration_service.dart`
7. ✅ Create backup mechanism for SharedPreferences data
8. ✅ Test migration on development device with sample data

### Day 2: Repository Refactoring

**Morning (3-4 hours)**
1. ✅ Update `Message` entity with `toMap()/fromMap()`
2. ✅ Refactor `MessageRepository` to use SQLite
3. ✅ Run tests for message operations
4. ✅ Update `Contact` entity
5. ✅ Refactor `ContactRepository` to use SQLite

**Afternoon (3-4 hours)**
6. ✅ Refactor `ChatsRepository` to use SQLite
7. ✅ Test chat list loading and unread counts
8. ✅ Update `UserPreferences` (keep minimal data in SharedPreferences)

### Day 3: Archive System & Media

**Morning (2-3 hours)**
1. ✅ Refactor `ArchiveRepository` to use SQLite + FTS5
2. ✅ Test archive/restore operations
3. ✅ Test archive search functionality

**Afternoon (3-4 hours)**
4. ✅ Implement `MediaRepository`
5. ✅ Create media directory structure
6. ✅ Test media save/retrieve operations
7. ✅ Update UI to handle media messages

### Day 4: Integration & Testing

**Full Day (6-8 hours)**
1. ✅ Run migration on test device with real data
2. ✅ Verify data integrity (message counts, contacts, etc.)
3. ✅ Performance testing (load 10k+ messages)
4. ✅ UI testing (chat list, message history, archive search)
5. ✅ Edge case testing (large archives, media deletion, etc.)
6. ✅ Migration rollback testing

---

## Testing Strategy

### Unit Tests

**File**: `test/data/repositories/message_repository_test.dart`

```dart
void main() {
  late MessageRepository repository;
  late Database testDb;

  setUp(() async {
    testDb = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) async {
        // Create test schema
      },
    );
    repository = MessageRepository();
  });

  test('saveMessage inserts message correctly', () async {
    final message = Message(
      id: 'test_1',
      chatId: 'chat_1',
      content: 'Test message',
      timestamp: DateTime.now(),
      isFromMe: true,
      status: MessageStatus.sent,
    );

    await repository.saveMessage(message);

    final retrieved = await repository.getMessages('chat_1');
    expect(retrieved.length, 1);
    expect(retrieved.first.content, 'Test message');
  });

  test('getMessages returns messages in chronological order', () async {
    // Insert 3 messages with different timestamps
    // Verify order
  });

  test('deleteMessage removes message and returns true', () async {
    // Test deletion
  });
}
```

### Integration Tests

**File**: `integration_test/database_migration_test.dart`

```dart
void main() {
  testWidgets('Migration preserves all data', (tester) async {
    // 1. Populate SharedPreferences with test data
    // 2. Run migration
    // 3. Verify SQLite contains same data
    // 4. Verify counts match
  });

  testWidgets('App functions after migration', (tester) async {
    // 1. Run migration
    // 2. Open chat list
    // 3. Send message
    // 4. Verify message appears
  });
}
```

### Performance Benchmarks

```dart
void main() {
  test('Message loading performance - 10k messages', () async {
    // OLD: SharedPreferences
    final stopwatch1 = Stopwatch()..start();
    await oldRepo.getMessages('chat_1'); // Loads ALL messages
    stopwatch1.stop();
    print('SharedPreferences: ${stopwatch1.elapsedMilliseconds}ms');

    // NEW: SQLite
    final stopwatch2 = Stopwatch()..start();
    await newRepo.getMessages('chat_1'); // Loads only chat_1 messages
    stopwatch2.stop();
    print('SQLite: ${stopwatch2.elapsedMilliseconds}ms');

    // Expect: SQLite 10-100x faster
    expect(stopwatch2.elapsedMilliseconds < stopwatch1.elapsedMilliseconds / 10, true);
  });
}
```

---

## Rollback Plan

### If Migration Fails

1. **Detect failure** in `MigrationService.migrateData()`
2. **Delete SQLite database**:
   ```dart
   await deleteDatabase(path);
   ```
3. **Clear migration flag**:
   ```dart
   await prefs.remove('sqlite_migration_completed_v1');
   ```
4. **Keep SharedPreferences intact** (never delete until migration succeeds)
5. **App continues using old repositories**

### Gradual Rollout Strategy

**Phase 1**: Internal testing (1 week)
- Test on development devices
- Monitor crash reports
- Verify data integrity

**Phase 2**: Beta release (1-2 weeks)
- Enable for 10% of users
- A/B test performance metrics
- Collect feedback

**Phase 3**: Full rollout
- Deploy to all users
- Monitor for 1 week
- Remove SharedPreferences fallback code

### Backup Mechanism

**Before Migration**:
```dart
Future<void> createBackup() async {
  final prefs = await SharedPreferences.getInstance();
  final allKeys = prefs.getKeys();
  final backup = <String, dynamic>{};

  for (final key in allKeys) {
    backup[key] = prefs.get(key);
  }

  // Save to file
  final appDir = await getApplicationDocumentsDirectory();
  final backupFile = File('${appDir.path}/backup_${DateTime.now().millisecondsSinceEpoch}.json');
  await backupFile.writeAsString(jsonEncode(backup));
}
```

---

## Performance Expectations

### Before (SharedPreferences)

| Operation | 100 msgs | 1k msgs | 10k msgs |
|-----------|----------|---------|----------|
| Load chat messages | 50ms | 500ms | 5000ms |
| Save message | 60ms | 600ms | 6000ms |
| Search archives | N/A | N/A | N/A |

### After (SQLite)

| Operation | 100 msgs | 1k msgs | 10k msgs |
|-----------|----------|---------|----------|
| Load chat messages | 5ms | 8ms | 12ms |
| Save message | 3ms | 3ms | 3ms |
| Search archives (FTS5) | 10ms | 15ms | 25ms |

**Expected improvements**:
- 10-100x faster read operations
- 200x faster write operations
- Archive search now feasible

---

## Post-Migration Cleanup

### After 30 Days of Successful SQLite Usage

1. **Remove SharedPreferences data** (except user preferences):
   ```dart
   await prefs.remove('chat_messages');
   await prefs.remove('enhanced_contacts_v2');
   await prefs.remove('archived_chats_v2');
   ```

2. **Remove migration code**:
   - Delete `migration_service.dart`
   - Remove migration check from `main.dart`

3. **Remove old repository code**:
   - Clean up `toJson()/fromJson()` if no longer needed
   - Remove SharedPreferences dependencies

4. **Update documentation**:
   - Update CLAUDE.md with SQLite architecture
   - Document database schema in separate file

---

## Additional Resources

### SQLite Best Practices

1. **Use transactions** for multi-step operations:
   ```dart
   await db.transaction((txn) async {
     await txn.insert(...);
     await txn.update(...);
   });
   ```

2. **Use indices** for frequently queried columns
3. **Use EXPLAIN QUERY PLAN** to optimize slow queries
4. **Vacuum database** periodically to reclaim space:
   ```dart
   await db.execute('VACUUM');
   ```

### Debugging Tools

- **SQLite Browser**: View database on desktop
- **ADB pull**: Extract database from device
  ```bash
  adb pull /data/data/com.example.pak_connect/databases/pak_connect.db
  ```

---

## Success Metrics

✅ **Migration Complete** when:
- All data migrated without loss
- App loads chats in <100ms (vs 1000ms+)
- Archive search works in <50ms
- No crashes for 1 week post-migration
- User preferences intact

📊 **Performance Targets**:
- Chat list: 60fps scrolling with 1000+ chats
- Message history: <50ms to load 500 messages
- Search: <30ms for 10k+ archived messages

---

**End of Migration Plan**

*Generated for pak_connect v1.0*
*Last Updated: 2025*
