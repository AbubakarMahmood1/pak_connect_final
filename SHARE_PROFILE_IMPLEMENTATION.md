# Share Profile Feature Implementation Guide

## 🎯 Objective
Enhance the "Share Profile" button in Profile Screen to provide better UX for sharing user profiles via QR code.

## 📋 Current State

**Location:** `lib/presentation/screens/profile_screen.dart`, line 458-461

**Current Implementation:**
```dart
void _shareProfile() {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text('Show QR code to share your profile')),
  );
}
```

**Status:** ❌ Placeholder only, no actual sharing functionality

---

## 🔧 Proposed Solutions

### **Option 1: Full-Screen QR Code Dialog** ✅ RECOMMENDED
**Advantages:**
- ✅ No external dependencies
- ✅ 100% testable on single device
- ✅ Better UX for in-person sharing
- ✅ Quick implementation (15-30 minutes)

**Implementation:**

#### Step 1: Add method to profile_screen.dart

Replace the current `_shareProfile()` method with:

```dart
void _shareProfile() async {
  final usernameAsync = ref.read(usernameProvider);
  
  await usernameAsync.when(
    data: (username) async {
      await showDialog(
        context: context,
        builder: (context) => Dialog(
          child: Container(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Share Your Profile',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),

                SizedBox(height: 24),

                // Large QR Code
                Container(
                  padding: EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: QrImageView(
                    data: _generateQRData(username),
                    version: QrVersions.auto,
                    size: 280,
                    backgroundColor: Colors.white,
                    padding: EdgeInsets.all(8),
                  ),
                ),

                SizedBox(height: 24),

                // Instructions
                Text(
                  'Ask your friend to scan this QR code\nto add you as a contact',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),

                SizedBox(height: 16),

                // User info
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      Text(
                        username,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        _deviceId,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),

                SizedBox(height: 16),

                // Close button
                FilledButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(Icons.check),
                  label: Text('Done'),
                  style: FilledButton.styleFrom(
                    minimumSize: Size(double.infinity, 48),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
    loading: () => null,
    error: (error, stack) => null,
  );
}
```

#### Step 2: Test on Single Device

**Test Scenario:**
```
1. Open Profile Screen
2. Tap "Share" button in AppBar
3. Verify:
   ✅ Full-screen dialog appears
   ✅ Large QR code is visible
   ✅ Username and device ID are shown
   ✅ Instructions are clear
4. Take screenshot
5. Use external QR scanner app to scan screenshot
6. Verify JSON data is correct
7. Tap "Done" to close
```

**Expected Result:**
- Dialog opens smoothly
- QR code is large and scannable
- User info matches profile screen
- No errors in console

---

### **Option 2: Share via System Share Dialog**
**Advantages:**
- ✅ Native sharing UX
- ✅ Can share to any app (WhatsApp, Telegram, etc.)
- ⚠️ Requires dependency: `share_plus`

**Implementation:**

#### Step 1: Add dependency to pubspec.yaml

```yaml
dependencies:
  share_plus: ^7.0.0
```

#### Step 2: Add method to profile_screen.dart

```dart
import 'package:share_plus/share_plus.dart';

void _shareProfile() async {
  final usernameAsync = ref.read(usernameProvider);
  
  await usernameAsync.when(
    data: (username) async {
      final qrData = _generateQRData(username);
      
      // Option A: Share as text (QR data JSON)
      await Share.share(
        'Add me on PakConnect!\n\n'
        'Scan this QR code or import this data:\n\n'
        '$qrData\n\n'
        'Username: $username\n'
        'Device ID: $_deviceId',
        subject: 'My PakConnect Profile',
      );
      
      // Option B: Share QR code as image (requires image generation)
      // See advanced implementation below
    },
    loading: () => null,
    error: (error, stack) => null,
  );
}
```

#### Step 3: Test on Single Device

**Test Scenario:**
```
1. Open Profile Screen
2. Tap "Share" button
3. Verify system share sheet appears
4. Select "Messages" or "Notes"
5. Send to yourself
6. Verify:
   ✅ QR data JSON is received
   ✅ Username and device ID are correct
```

---

### **Option 3: Copy QR Data to Clipboard**
**Advantages:**
- ✅ Simplest implementation
- ✅ No dependencies
- ✅ 100% testable on single device

**Implementation:**

```dart
void _shareProfile() async {
  final usernameAsync = ref.read(usernameProvider);
  
  await usernameAsync.when(
    data: (username) async {
      final qrData = _generateQRData(username);
      
      await Clipboard.setData(ClipboardData(text: qrData));
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Profile data copied to clipboard!'),
            action: SnackBarAction(
              label: 'View QR',
              onPressed: () {
                // Show full-screen QR dialog (Option 1 implementation)
              },
            ),
          ),
        );
      }
    },
    loading: () => null,
    error: (error, stack) => null,
  );
}
```

---

## 🎯 Recommendation

**Implement Option 1 (Full-Screen QR Dialog)** because:

1. ✅ **No external dependencies** - Uses existing `qr_flutter` package
2. ✅ **Best UX** - Large QR code is easier to scan
3. ✅ **100% testable on single device** - Can screenshot and scan
4. ✅ **Quick to implement** - 15-30 minutes
5. ✅ **Professional appearance** - Polished dialog with instructions

---

## 🧪 Testing Checklist

### Single Device Tests

- [ ] Share button triggers dialog/share sheet
- [ ] QR code is visible and large enough
- [ ] Username displays correctly
- [ ] Device ID displays correctly
- [ ] Can close dialog/share sheet
- [ ] Screenshot QR and scan with external app
- [ ] Scanned data contains all required fields
- [ ] No console errors

### Multi-Device Tests (When Available)

- [ ] Other device can scan QR code
- [ ] Scanned data creates valid contact
- [ ] Contact appears with correct username
- [ ] Public key is correct

---

## 📝 Implementation Instructions

1. Open `lib/presentation/screens/profile_screen.dart`
2. Locate `_shareProfile()` method (around line 458)
3. Replace with Option 1 implementation above
4. Save file
5. Hot reload app
6. Test using checklist above

**Estimated Time:** 15-30 minutes  
**Difficulty:** Easy  
**Risk:** Very Low (only affects one button)

---

## 🎓 Learning Points

This enhancement demonstrates:
- ✅ Dialog-based UI patterns
- ✅ QR code generation and display
- ✅ Async/await with Riverpod providers
- ✅ Material Design 3 styling
- ✅ User feedback via dialogs

---

## 📊 Before/After Comparison

### Before
```
Tap Share → Toast message "Show QR code to share your profile"
```

### After
```
Tap Share → Full-screen dialog with:
  - Large, scannable QR code
  - User's name and device ID
  - Clear instructions
  - Professional styling
  - Easy close button
```

---

**Ready to implement?** Follow the step-by-step instructions above!
