Release logging now exposes contact names and message metadata - cf22621877bc8191a993394c175cd3f7

Link: https://chatgpt.com/codex/security/findings/cf22621877bc8191a993394c175cd3f7?sev=critical%2Chigh%2Cmedium%2Clow

Criticality: low (attack path: low)

Status: new



Summary:

Introduced: release builds now emit INFO-level logs that contain PII/metadata (contact names, message/recipient IDs). Sanitization does not remove those fields, so the commit creates an information disclosure risk that did not exist when release logging was limited to WARNING.

AppLogger now sets the root level to INFO even in release/profile and always outputs log records. This means INFO logs that previously stayed silent in release are now emitted. Multiple INFO logs include contact display names and message/recipient identifiers (e.g., chat open events and outbound send diagnostics). The new redaction only targets key-like tokens and does not scrub names or IDs, so these details become visible in production logs (logcat/OS logs), creating a privacy and metadata disclosure vector.



Metadata:

Repo: AbubakarMahmood1/pak\_connect\_final

Commit: 4c1e386

Author: f219462@cfd.nu.edu.pk

Created: 07/03/2026, 15:05:34

Assignee: Unassigned

Signals: Security, Validated, Patch generated, Attack-path



Relevant lines:

/workspace/pak\_connect\_final/lib/data/services/outbound\_message\_sender.dart (L431 to 447)

&nbsp; Note: INFO logs emit message IDs, recipient IDs, and node IDs; these metadata fields are not redacted and will now be output in release logs.

&nbsp;       \_logger.info(

&nbsp;         '🔧 PERIPHERAL SEND DEBUG: Message ID: ${\_safeTruncate(msgId, 16)}...',

&nbsp;       );

&nbsp;       \_logger.info(

&nbsp;         '🔧 PERIPHERAL SEND DEBUG: Recipient ID: ${\_safeTruncate(finalRecipientId, 16, fallback: "NOT SPECIFIED")}...',

&nbsp;       );

&nbsp;       \_logger.info(

&nbsp;         '🔧 PERIPHERAL SEND DEBUG: Addressing: ${useEphemeralAddressing ? "EPHEMERAL" : "PERSISTENT"}',

&nbsp;       );

&nbsp;       \_logger.info(

&nbsp;         '🔧 PERIPHERAL SEND DEBUG: Intended recipient: ${\_safeTruncate(contactKey, 16, fallback: "NOT SPECIFIED")}...',

&nbsp;       );

&nbsp;       \_logger.info(

&nbsp;         '🔧 PERIPHERAL SEND DEBUG: Current node ID: ${\_safeTruncate(\_currentNodeId, 16, fallback: "NOT SET")}...',

&nbsp;       );

&nbsp;       \_logger.info(

&nbsp;         '🔧 PERIPHERAL SEND DEBUG: Encryption method: $encryptionMethod',



/workspace/pak\_connect\_final/lib/domain/utils/app\_logger.dart (L52 to 129)

&nbsp; Note: Release/profile logging now sets root level to INFO and prints every log record, enabling INFO logs in production.

&nbsp;   static Level \_resolveRootLevel() {

&nbsp;     final configured = \_parseLevel(

&nbsp;       const String.fromEnvironment(\_logLevelEnv, defaultValue: ''),

&nbsp;     );

&nbsp;     if (configured != null) return configured;

&nbsp; 

&nbsp;     if (kReleaseMode || kProfileMode) {

&nbsp;       return Level.INFO;

&nbsp;     }

&nbsp;     return Level.INFO;

&nbsp;   }

&nbsp; 

&nbsp;   static Level? \_parseLevel(String raw) {

&nbsp;     final normalized = raw.trim().toUpperCase();

&nbsp;     if (normalized.isEmpty) return null;

&nbsp; 

&nbsp;     switch (normalized) {

&nbsp;       case 'OFF':

&nbsp;         return Level.OFF;

&nbsp;       case 'SHOUT':

&nbsp;         return Level.SHOUT;

&nbsp;       case 'SEVERE':

&nbsp;         return Level.SEVERE;

&nbsp;       case 'WARNING':

&nbsp;       case 'WARN':

&nbsp;         return Level.WARNING;

&nbsp;       case 'INFO':

&nbsp;         return Level.INFO;

&nbsp;       case 'CONFIG':

&nbsp;         return Level.CONFIG;

&nbsp;       case 'FINE':

&nbsp;         return Level.FINE;

&nbsp;       case 'FINER':

&nbsp;         return Level.FINER;

&nbsp;       case 'FINEST':

&nbsp;       case 'DEBUG':

&nbsp;         return Level.FINEST;

&nbsp;       case 'ALL':

&nbsp;       case 'TRACE':

&nbsp;         return Level.ALL;

&nbsp;       default:

&nbsp;         return null;

&nbsp;     }

&nbsp;   }

&nbsp; 

&nbsp;   /// Initialize the logging system

&nbsp;   /// Call this once at app startup (already done in main.dart)

&nbsp;   static void initialize() {

&nbsp;     if (\_initialized) return;

&nbsp; 

&nbsp;     Logger.root.level = \_resolveRootLevel();

&nbsp;     hierarchicalLoggingEnabled = true;

&nbsp; 

&nbsp;     Logger.root.onRecord.listen((record) {

&nbsp;       final releaseSafeMode = kReleaseMode || kProfileMode;

&nbsp;       final message = sanitizeForOutput(

&nbsp;         record.message,

&nbsp;         releaseMode: releaseSafeMode,

&nbsp;       );

&nbsp; 

&nbsp;       // In debug mode: use emoji-enhanced formatting

&nbsp;       if (kDebugMode) {

&nbsp;         final emoji = \_getEmojiForLevel(record.level);

&nbsp;         debugPrint(

&nbsp;           '$emoji \[${record.loggerName}] ${record.level.name} $message',

&nbsp;         );

&nbsp;         if (record.error != null) {

&nbsp;           debugPrint('  ↳ Error: ${record.error}');

&nbsp;         }

&nbsp;         if (record.stackTrace != null) {

&nbsp;           debugPrint('  ↳ Stack: ${record.stackTrace}');

&nbsp;         }

&nbsp;       } else {

&nbsp;         // In release/profile mode: structured output with sanitized payload.

&nbsp;         final line =

&nbsp;             '\[${record.level.name}] ${record.loggerName} ${record.time.toIso8601String()} $message';

&nbsp;         debugPrint(line);

&nbsp;       }



/workspace/pak\_connect\_final/lib/presentation/controllers/chat\_screen\_controller.dart (L605 to 615)

&nbsp; Note: INFO log includes contact name and security/encryption metadata, which will now be emitted in release logs.

&nbsp;     final contact = await contactRepository.getContactByUserId(userId);

&nbsp;     final securityLevel = await SecurityServiceLocator.instance.getCurrentLevel(

&nbsp;       userId.value,

&nbsp;       contactRepository,

&nbsp;     );

&nbsp;     final encryptionMethod = await SecurityServiceLocator.instance

&nbsp;         .getEncryptionMethod(userId.value, contactRepository);

&nbsp; 

&nbsp;     \_logger.info(

&nbsp;       'Chat open: ${config.contactName ?? "Unknown"} | Security=${securityLevel.name} | Encryption=${encryptionMethod.type.name}',

&nbsp;     );





Validation:

Rubric:

\- \[x] Confirm release/profile logging level is INFO and release output prints all records (app\_logger.dart lines 52-129).

\- \[x] Identify INFO logs that include PII/metadata (chat\_screen\_controller.dart lines 613-615; outbound\_message\_sender.dart lines 431-447).

\- \[x] Verify redaction preserves message IDs/names (app\_logger\_test.dart lines 18-26; sanitize logic in app\_logger.dart lines 159-168).

\- \[x] Establish regression from prior release behavior limiting logs to WARNING (previous app\_logger.dart lines 24-46).

Report:

Crash/valgrind/debugger attempts were blocked by missing tooling: `flutter test test/domain/utils/app\_logger\_test.dart` failed with `command not found: flutter`, `valgrind --version` and `gdb --version` also not found. Code review shows release logging now emits INFO logs without level gating. In `lib/domain/utils/app\_logger.dart`, `\_resolveRootLevel()` returns `Level.INFO` even for release/profile (lines 52-61) and the release/profile path unconditionally prints every record after sanitization (lines 105-129). Previously, release mode only logged `>= WARNING` (parent version lines 24-46 in the previous file view). INFO logs include contact names and metadata: `chat\_screen\_controller.dart` logs `Chat open: ${config.contactName ...}` at INFO (lines 613-615), and `outbound\_message\_sender.dart` logs message/recipient/node IDs at INFO (lines 431-447). The redaction logic does not strip names/IDs: the new tests explicitly assert that `messageId` is preserved in release mode (`test/domain/utils/app\_logger\_test.dart` lines 18-26), and redaction only targets key-context tokens. Therefore, the commit introduces production INFO logs containing PII/metadata that were previously suppressed.



Proposed patch:

diff --git a/lib/domain/utils/app\_logger.dart b/lib/domain/utils/app\_logger.dart

index a648ce1fb026afb29c17e026827d16752ffbc357..20cbf865b7de715cb101e380a7be6392061fe247 100644

--- a/lib/domain/utils/app\_logger.dart

+++ b/lib/domain/utils/app\_logger.dart

@@ -34,51 +34,51 @@ class AppLogger {

&nbsp;    'identity',

&nbsp;    ' peer key',

&nbsp;    ' key ',

&nbsp;    'key=',

&nbsp;    'pubkey',

&nbsp;  ];

&nbsp;

&nbsp;  static final List<RegExp> \_labeledSecretPatterns = <RegExp>\[

&nbsp;    RegExp(

&nbsp;      r'\\b(public\\s\*key|private\\s\*key|persistent\\s\*public\\s\*key|current\\s\*ephemeral(?:\\s\*id)?|ephemeral(?:\\s\*(?:id|key|session(?:\\s\*key)?|signing(?:\\s\*key)?))|noise(?:\\s\*(?:public|static)?\\s\*key)?|noise\\s\*session|session\\s\*id(?:\\s\*for\\s\*noise)?|pubkey|identity\\s\*fingerprint|fingerprint)\\b\\s\*\[:=]\\s\*(\[^\\s|,;]+)',

&nbsp;      caseSensitive: false,

&nbsp;    ),

&nbsp;  ];

&nbsp;

&nbsp;  static final RegExp \_candidateTokenPattern = RegExp(

&nbsp;    r'\[A-Za-z0-9+/\_=-]{8,}\\.\\.\\.|\[A-Fa-f0-9]{24,}|\[A-Za-z0-9+/\_=-]{32,}',

&nbsp;  );

&nbsp;

&nbsp;  static Level \_resolveRootLevel() {

&nbsp;    final configured = \_parseLevel(

&nbsp;      const String.fromEnvironment(\_logLevelEnv, defaultValue: ''),

&nbsp;    );

&nbsp;    if (configured != null) return configured;

&nbsp;

&nbsp;    if (kReleaseMode || kProfileMode) {

\-      return Level.INFO;

\+      return Level.WARNING;

&nbsp;    }

&nbsp;    return Level.INFO;

&nbsp;  }

&nbsp;

&nbsp;  static Level? \_parseLevel(String raw) {

&nbsp;    final normalized = raw.trim().toUpperCase();

&nbsp;    if (normalized.isEmpty) return null;

&nbsp;

&nbsp;    switch (normalized) {

&nbsp;      case 'OFF':

&nbsp;        return Level.OFF;

&nbsp;      case 'SHOUT':

&nbsp;        return Level.SHOUT;

&nbsp;      case 'SEVERE':

&nbsp;        return Level.SEVERE;

&nbsp;      case 'WARNING':

&nbsp;      case 'WARN':

&nbsp;        return Level.WARNING;

&nbsp;      case 'INFO':

&nbsp;        return Level.INFO;

&nbsp;      case 'CONFIG':

&nbsp;        return Level.CONFIG;

&nbsp;      case 'FINE':

&nbsp;        return Level.FINE;

&nbsp;      case 'FINER':



Attack-path analysis:

Final: low | Decider: model\_decided | Matrix severity: ignore | Policy adjusted: ignore

Rationale: The issue is in-scope but is a local information disclosure only. Release logs now include metadata/PII (contact names, message/recipient IDs) and are emitted via debugPrint in release/profile. Exploitation requires access to device logs; impact is limited to metadata exposure rather than cryptographic secrets or remote compromise.

Likelihood: low - Requires local/privileged access to device logs; not remotely reachable.

Impact: low - Discloses user contact names and message metadata in device logs; no direct key exposure or remote compromise.

Assumptions:

\- Release/profile builds use debugPrint to emit logs to OS logging facilities (e.g., logcat).

\- Device log access requires local/physical access or privileged tooling (e.g., adb, rooted device, or privileged app).

\- release/profile build running

\- access to device logs (adb/logcat or privileged app/root)

Path:

\[Release INFO logs] -> \[PII/metadata in log lines] -> \[Local log access]

Narrative:

The app’s central logger sets release/profile root level to INFO and prints all log records, which makes INFO messages appear in production logs. Multiple INFO statements include contact display names and message/recipient/node identifiers. The sanitizer only targets key-like patterns, so these PII/metadata fields are still emitted. A local actor with access to device logs (e.g., adb/logcat or privileged app/root) could read this data. This is a low-impact, local information disclosure consistent with the threat model’s logging/diagnostics residual risk.

Evidence:

\- \[object Object]

\- \[object Object]

\- \[object Object]

\- \[object Object]

Controls:

\- sanitizeForOutput redaction of key-like tokens

\- kDebugMode gating for extra debug-only logs

Blindspots:

\- Cannot confirm runtime log routing or OS log access restrictions for specific platform builds.

\- No runtime verification of whether production builds disable or redirect debugPrint output.

