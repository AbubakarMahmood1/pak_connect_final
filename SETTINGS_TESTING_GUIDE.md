# Settings Implementation - Testing Guide

**Date:** October 9, 2025  
**Features Implemented:** Storage Usage Fix + Auto-Archive Scheduler

---

## ✅ What Was Implemented

### 1. Fixed Storage Usage Display
**File:** `lib/presentation/screens/settings_screen.dart`

**What Changed:**
- Replaced hardcoded values with real database size calculation
- Now shows actual MB/KB from `DatabaseHelper.getDatabaseSize()`
- Added loading indicator while calculating
- Handles errors gracefully

**Before:**
```
Database: ~2.5 MB  (HARDCODED)
Cached Data: ~1.2 MB  (HARDCODED)
Total: ~3.7 MB  (HARDCODED)
```

**After:**
```
Database: 3.45 MB  (REAL DATA)
(3532.12 KB)
Includes: messages, chats, contacts, archives
```

---

### 2. Auto-Archive Scheduler
**Files:**
- `lib/domain/services/auto_archive_scheduler.dart` (NEW)
- `lib/core/app_core.dart` (updated)
- `lib/presentation/screens/settings_screen.dart` (updated)

**What It Does:**
- Runs daily check for inactive chats
- Archives chats based on user-configured threshold (30/60/90/180/365 days)
- Starts automatically on app launch
- Restarts when settings change
- Manual trigger button for testing

**Integration Points:**
1. **App Startup:** Scheduler starts in `AppCore._startIntegratedSystems()`
2. **Settings Toggle:** Scheduler restarts when auto-archive enabled/disabled
3. **Days Changed:** Scheduler restarts when threshold changes
4. **Manual Trigger:** New button in settings screen

---

## 🧪 Single-Device Testing Guide

### Test 1: Storage Usage
**Steps:**
1. Launch app
2. Navigate to Settings
3. Tap "Storage Usage"
4. **Verify:** Shows actual database size (not hardcoded)
5. Add some messages/contacts
6. Tap "Storage Usage" again
7. **Verify:** Size increased
8. Clear all data
9. Tap "Storage Usage"
10. **Verify:** Size dropped to base (~0.5 MB)

**Expected Result:**
- Real-time accurate storage calculation
- No hardcoded values
- Shows in MB and KB

---

### Test 2: Auto-Archive Basic Flow
**Steps:**
1. Enable "Auto-Archive Old Chats"
2. Set threshold to 30 days
3. **Verify:** Scheduler started (check logs)
4. Disable auto-archive
5. **Verify:** Scheduler stopped (check logs)

**Expected Logs:**
```
[AutoArchiveScheduler] Starting auto-archive scheduler
[AutoArchiveScheduler] Auto-archive scheduler started successfully
[AutoArchiveScheduler] Auto-archive scheduler stopped
```

---

### Test 3: Manual Archive Check (Simple)
**Steps:**
1. Enable auto-archive, set to 7 days
2. Create a chat (send/receive messages normally)
3. Tap "Check Inactive Chats Now"
4. **Verify:** Shows "No inactive chats found"

**Expected Result:**
```
SnackBar: "No inactive chats found"
```

---

### Test 4: Manual Archive Check (With Old Chat)

**Option A: Database Manipulation (Advanced)**
```dart
// In Dart DevTools Console or test file:
final db = await DatabaseHelper.database;
await db.update(
  'messages',
  {'timestamp': DateTime.now().subtract(Duration(days: 8)).millisecondsSinceEpoch},
  where: 'chat_id = ?',
  whereArgs: ['your_chat_id'],
);
```

**Option B: Time Mocking (Simpler)**
1. Create test chat
2. Wait 8 days... ❌ (not practical)

**Option C: Modified Test (Recommended)**
1. Set threshold to 0 days (not available in UI, would need code change)
2. OR: Manually modify `_checkAndArchiveInactiveChats()` to use test cutoff

**Recommended Test Approach:**
```dart
// Temporary test modification
// In auto_archive_scheduler.dart, line ~75:
// BEFORE:
final cutoffDate = DateTime.now().subtract(Duration(days: archiveAfterDays));

// AFTER (for testing):
final cutoffDate = DateTime.now().add(Duration(days: 1)); // Archive everything!
```

**Steps:**
1. Make temporary code change above
2. Create a chat with messages
3. Tap "Check Inactive Chats Now"
4. **Verify:** Chat archived successfully
5. **Verify:** SnackBar shows "Auto-archived 1 inactive chat"
6. Check archive screen
7. **Verify:** Chat appears in archives
8. Restore chat from archive
9. **Verify:** Chat restored correctly

**Cleanup:** Revert code change

---

### Test 5: Scheduler Persistence
**Steps:**
1. Enable auto-archive, set to 30 days
2. Close app completely
3. Relaunch app
4. Check logs
5. **Verify:** Scheduler started automatically

**Expected Logs:**
```
[AppCore] Starting integrated systems...
[AppCore] 🗄️ Starting auto-archive scheduler...
[AutoArchiveScheduler] Starting auto-archive scheduler
[AutoArchiveScheduler] Checking for chats inactive since: ...
[AutoArchiveScheduler] ✓ Auto-archive check complete: no inactive chats found
[AppCore] ✅ Auto-archive scheduler started
```

---

### Test 6: Settings Changes
**Steps:**
1. Enable auto-archive, set to 30 days
2. Change threshold to 90 days
3. **Verify:** Scheduler restarted (check logs)
4. Disable auto-archive
5. **Verify:** Scheduler stopped
6. Enable again
7. **Verify:** Scheduler started

**Expected Logs:**
```
[AutoArchiveScheduler] Restarting auto-archive scheduler
[AutoArchiveScheduler] Auto-archive scheduler stopped
[AutoArchiveScheduler] Starting auto-archive scheduler
```

---

## 📋 Test Checklist

### Basic Functionality
- [ ] Storage usage shows real data
- [ ] Storage updates when data added
- [ ] Storage drops when data cleared
- [ ] Auto-archive toggle works
- [ ] Days selector works
- [ ] Manual check button works

### Scheduler Behavior
- [ ] Starts on app launch (when enabled)
- [ ] Stops when disabled
- [ ] Restarts when threshold changes
- [ ] Respects user settings
- [ ] Logs show correct operations

### Edge Cases
- [ ] Works with no chats
- [ ] Works with multiple chats
- [ ] Handles archiving errors gracefully
- [ ] Shows correct count in snackbar
- [ ] Doesn't archive recently active chats

---

## 🐛 Known Limitations & Future Work

### Current Limitations
1. **24-hour check interval** - Cannot manually set check frequency
2. **No notifications** - User not notified when chats auto-archived
3. **No whitelist** - Cannot exclude specific chats from auto-archive
4. **Testing difficulty** - Hard to test with real time delays

### Future Enhancements
```dart
// Potential improvements:
1. Configurable check interval (hourly, daily, weekly)
2. Notification when chats archived
3. Whitelist/pin protection
4. Archive preview before archiving
5. Undo functionality
6. Statistics dashboard
```

---

## 🔍 Debugging Tips

### Enable Verbose Logging
```dart
// In auto_archive_scheduler.dart
static final _logger = Logger('AutoArchiveScheduler');
// Change log level if needed for more details
```

### Check Scheduler Status
```dart
// In Settings screen or dev tools:
print('Scheduler running: ${AutoArchiveScheduler.isRunning}');
print('Last check: ${AutoArchiveScheduler.lastCheckTime}');
```

### Manual Trigger from Code
```dart
// Anywhere in code:
final count = await AutoArchiveScheduler.checkNow();
print('Archived $count chats');
```

---

## 📊 Testing Scenarios

### Scenario 1: New User
**Setup:** Fresh install, no data  
**Expected:** Scheduler starts but finds nothing to archive

### Scenario 2: Active User
**Setup:** Multiple chats, all recent  
**Expected:** Scheduler runs, no archiving

### Scenario 3: Inactive Chats
**Setup:** Old chats + new chats  
**Expected:** Only old chats archived

### Scenario 4: Settings Changes
**Setup:** Enable/disable/change threshold  
**Expected:** Scheduler responds correctly

---

## 🎯 Success Criteria

### Storage Usage
- ✅ Shows real data
- ✅ Updates dynamically
- ✅ No hardcoded values

### Auto-Archive
- ✅ Starts automatically
- ✅ Respects settings
- ✅ Archives inactive chats only
- ✅ Manual trigger works
- ✅ Provides user feedback
- ✅ Logs operations

---

## 📝 Quick Reference

### Key Files
```
lib/
├── domain/services/
│   └── auto_archive_scheduler.dart          (NEW)
├── presentation/screens/
│   └── settings_screen.dart                 (UPDATED)
└── core/
    └── app_core.dart                        (UPDATED)
```

### Settings Path
```
Main Screen → Settings Icon → Data & Storage Section
```

### Manual Trigger Path
```
Settings → Data & Storage → Auto-Archive Old Chats (enable)
       → Check Inactive Chats Now
```

---

**End of Testing Guide**
