# Non-Functional Requirements

This document details quality attributes and constraints extracted from implementation.

> **Evidence status:** Numeric latency, throughput, capacity, availability,
> delivery-rate, battery, memory, CPU, and storage figures below are design
> targets unless a row cites a measured artifact in the current readiness
> ledger. They are not current product results. Automated tests establish code
> behavior, not BLE radio, multi-link, battery, killed-process background, or
> fleet-scale performance on physical devices.

## Evidence disposition for open NFR families

| Area | Current disposition | Evidence required before claiming completion |
|---|---|---|
| Database migration (`NFR-5.3.3`, `NFR-10.1.1`) | Partial: fresh v12 and migrations through v10 have automated coverage; no direct v10 -> v11 -> v12 upgrade proof was found | Add a populated v10 fixture test that upgrades through v12 and verifies change-log triggers, per-peer queue-sync cursor data, user data, schema version, and reopen; then retain a baseline-bound Android app-update smoke artifact |
| Cross-version protocol (`NFR-10.1.2`, `NFR-10.2.2`, `NFR-10.2.3`) | Partial: automated peer-version floor behavior exists; no mixed-app-version physical run is recorded | Define the supported version pair, expected accept/reject behavior, two distinct build hashes, clean install/upgrade order, bidirectional XX/KK/message cases, and saved device logs in a baseline-bound checklist extension |
| Accessibility (`NFR-4.2.*`) | Unverified as a product-level claim; high-contrast mode is explicitly absent | Record TalkBack traversal/labels, 200% text-scale overflow checks, non-color-only status cues, touch targets, and any platform keyboard/focus behavior actually claimed, with screen/model/build evidence |
| Numeric performance and efficiency (`NFR-1.*`, `NFR-3.1.*`, `NFR-7.*`) | Design targets only; no current benchmark artifact establishes the published thresholds | Use a named build/device/OS, fixed workload and radio conditions, warm-up, sample count, percentile/statistical rule, battery interval, and raw machine-readable output; report misses as misses rather than deleting samples |
| Distribution licensing (`NFR-8.1.1`, `NFR-8.1.3`, `NFR-8.1.4`) | Root code license is proprietary; dependency notices and jurisdiction-specific crypto distribution review are incomplete | Generate a dependency/SBOM inventory from the exact release lockfile, review every bundled license and notice obligation, retain the notices shipped with the binary, and record the applicable export/legal review; device testing cannot close this gate |

## NFR-1: Performance

### NFR-1.1: Response Time
| ID | Requirement | Target | Measurement |
|----|-------------|--------|-------------|
| NFR-1.1.1 | Message encryption latency | < 50ms | `PerformanceMonitor` tracking |
| NFR-1.1.2 | Message decryption latency | < 50ms | Crypto operation timing |
| NFR-1.1.3 | Database query response | < 100ms | SQLite query execution |
| NFR-1.1.4 | BLE characteristic write | < 200ms | MTU-dependent |
| NFR-1.1.5 | Handshake completion (XX pattern) | < 2 seconds | 3-message round-trip |
| NFR-1.1.6 | Handshake completion (KK pattern) | < 1 second | 2-message round-trip |

### NFR-1.2: Throughput
| ID | Requirement | Target | Implementation |
|----|-------------|--------|----------------|
| NFR-1.2.1 | Messages per second (1-to-1) | 5-10 messages/sec | BLE MTU limited |
| NFR-1.2.2 | Concurrent BLE connections | Configuration target: 7 (Android), 10 (iOS) | Current payload policy is single-link; multi-link device evidence pending |
| NFR-1.2.3 | Database writes | 100+ inserts/sec | WAL mode enabled |
| NFR-1.2.4 | Relay throughput | 3-5 messages/sec/node | Duplicate detection overhead |
| NFR-1.2.5 | Fragment reassembly | < 500ms per message | 30-second timeout |

### NFR-1.3: Scalability
| ID | Requirement | Target | Notes |
|----|-------------|--------|-------|
| NFR-1.3.1 | Maximum contacts | 1000+ | SQLite indexed |
| NFR-1.3.2 | Maximum messages per chat | 100,000+ | Paginated queries |
| NFR-1.3.3 | Maximum message queue size | 10,000 messages | Persistent storage |
| NFR-1.3.4 | Maximum network nodes | Design target: 50-100 nodes | Not demonstrated on physical hardware |
| NFR-1.3.5 | Maximum relay hops | 5 hops | Configurable limit |

## NFR-2: Security

### NFR-2.1: Cryptographic Strength
| ID | Requirement | Standard | Implementation |
|----|-------------|----------|----------------|
| NFR-2.1.1 | Key exchange algorithm | X25519 ECDH | `pinenacl` package |
| NFR-2.1.2 | Symmetric encryption | ChaCha20-Poly1305 | `cryptography` package |
| NFR-2.1.3 | Hash function | SHA-256 | `crypto` package |
| NFR-2.1.4 | Key size | 256 bits | X25519 standard |
| NFR-2.1.5 | Nonce/IV uniqueness | 64-bit counter + 32-bit random | Noise Protocol spec |
| NFR-2.1.6 | Forward secrecy | Ephemeral DH per session | XX/KK patterns |

### NFR-2.2: Data Protection
| ID | Requirement | Method | Implementation |
|----|-------------|--------|----------------|
| NFR-2.2.1 | Mobile database encryption | SQLCipher path on Android/iOS | Implemented path; device at-rest proof pending; desktop/test may be plaintext |
| NFR-2.2.2 | Key storage | Platform secure storage | `flutter_secure_storage` |
| NFR-2.2.3 | Memory clearing | Secure key destruction | `DHState.destroy()` |
| NFR-2.2.4 | Replay protection | Nonce sequence tracking | Per-session counters |
| NFR-2.2.5 | Message authentication | AEAD MAC tag | ChaCha20-Poly1305 |

### NFR-2.3: Privacy
| ID | Requirement | Implementation | Status |
|----|-------------|----------------|--------|
| NFR-2.3.1 | No project-operated cloud storage | No PakConnect account/message server | Implemented default composition |
| NFR-2.3.2 | No project-operated telemetry/analytics | No analytics SDK or endpoint | Implemented default composition |
| NFR-2.3.3 | Ephemeral identity rotation | `EphemeralKeyManager` | Implemented |
| NFR-2.3.4 | Reduce metadata correlation | Rotating ephemeral IDs and blinded hints | Partial; BLE/control/routing metadata remains exposed |
| NFR-2.3.5 | Secure deletion | Overwrite sensitive memory | Partial (key objects only) |

## NFR-3: Reliability

### NFR-3.1: Availability
| ID | Requirement | Target | Mechanism |
|----|-------------|--------|-----------|
| NFR-3.1.1 | App uptime | 99% during active use | Error handling |
| NFR-3.1.2 | BLE connection stability | Reconnect within 30s | Auto-reconnect logic |
| NFR-3.1.3 | Database availability | 99.9% | SQLite robustness |
| NFR-3.1.4 | Message delivery (1-hop) | 95%+ success rate | Retry mechanism |
| NFR-3.1.5 | Message delivery (multi-hop) | 80%+ success rate | Best-effort relay |

### NFR-3.2: Fault Tolerance
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-3.2.1 | Crash recovery | Persist queue state | SQLite transactions |
| NFR-3.2.2 | Network partition handling | Offline queue | Persistent message queue |
| NFR-3.2.3 | Corrupted message handling | AEAD verification | Discard invalid messages |
| NFR-3.2.4 | Database corruption recovery | Integrity checks | `PRAGMA integrity_check` |
| NFR-3.2.5 | BLE adapter failures | Graceful degradation | State monitoring |

### NFR-3.3: Data Integrity
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-3.3.1 | Message authenticity | AEAD MAC | ChaCha20-Poly1305 tag |
| NFR-3.3.2 | Database constraints | Foreign keys, unique indexes | SQLite schema |
| NFR-3.3.3 | Transaction atomicity | ACID properties | SQLite transactions |
| NFR-3.3.4 | Backup integrity | Checksums | `MigrationService` validation |
| NFR-3.3.5 | Fragment integrity | Sequence validation | `MessageFragmenter` |

## NFR-4: Usability

### NFR-4.1: User Interface
| ID | Requirement | Target | Implementation |
|----|-------------|--------|----------------|
| NFR-4.1.1 | First-time setup | < 2 minutes | Key generation + onboarding |
| NFR-4.1.2 | Add contact via QR | < 10 seconds | QR scan + handshake |
| NFR-4.1.3 | Send message | < 2 seconds | UI responsiveness |
| NFR-4.1.4 | Search results | < 1 second | Indexed queries + FTS5 |
| NFR-4.1.5 | Chat list load | < 500ms | Paginated, cached |

### NFR-4.2: Accessibility
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-4.2.1 | Screen reader support | Unverified | Flutter default semantics exist; no TalkBack/VoiceOver audit is recorded |
| NFR-4.2.2 | High contrast mode | Not implemented | Future enhancement |
| NFR-4.2.3 | Font scaling | Unverified | Framework scaling exists; no 200% layout/overflow audit is recorded |
| NFR-4.2.4 | Keyboard navigation | Unverified | Mobile-first design; desktop focus traversal has not been audited |
| NFR-4.2.5 | Color-blind friendly | Partial | Security indicators use icons; end-to-end non-color-only audit pending |

### NFR-4.3: Learnability
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-4.3.1 | Intuitive UI | Familiar chat interface | Standard patterns |
| NFR-4.3.2 | Security indicators | Visual icons | Lock/shield icons |
| NFR-4.3.3 | Error messages | User-friendly text | Contextual errors |
| NFR-4.3.4 | Onboarding hints | Intro screens | `IntroHintRepository` |
| NFR-4.3.5 | Status feedback | Message status icons | Pending/sent/delivered |

## NFR-5: Maintainability

### NFR-5.1: Code Quality
| ID | Requirement | Metric | Status |
|----|-------------|--------|--------|
| NFR-5.1.1 | Code documentation | Doc comments on public APIs | Good |
| NFR-5.1.2 | Logging coverage | Emoji-prefixed structured logging | Excellent |
| NFR-5.1.3 | Error handling | Try-catch with logging | Good |
| NFR-5.1.4 | Architectural separation | Layered architecture (4 layers) | Excellent |
| NFR-5.1.5 | SOLID principles | Applied throughout | Good |

### NFR-5.2: Testability
| ID | Requirement | Implementation | Status |
|----|-------------|----------------|--------|
| NFR-5.2.1 | Unit test coverage | Arrange-Act-Assert pattern | Partial |
| NFR-5.2.2 | Mock support | Dependency injection | Good |
| NFR-5.2.3 | Test database | `sqflite_common_ffi` | Implemented |
| NFR-5.2.4 | Integration tests | Key flows covered | Partial |
| NFR-5.2.5 | Test isolation | Independent test cases | Good |

### NFR-5.3: Extensibility
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-5.3.1 | Plugin architecture | Riverpod providers | Yes |
| NFR-5.3.2 | Configurable policies | `RelayPolicy`, `ArchivePolicy` | Yes |
| NFR-5.3.3 | Database migrations | Version-based upgrades | Implemented v1-v12; v11/v12 upgrade proof pending |
| NFR-5.3.4 | Notification handlers | Factory pattern | Yes |
| NFR-5.3.5 | Power management strategies | Strategy pattern | Yes |

## NFR-6: Portability

### NFR-6.1: Platform Support
| ID | Platform | Status | Notes |
|----|----------|--------|-------|
| NFR-6.1.1 | Android API 24+ | Build target | Primary platform; hardware matrix pending |
| NFR-6.1.2 | iOS 12.0+ | Source target only | Build, radio, and background behavior unverified |
| NFR-6.1.3 | Windows | Development/test target | BLE behavior unverified |
| NFR-6.1.4 | Linux | Desktop BLE limited | Dev/testing only |
| NFR-6.1.5 | macOS | Desktop BLE limited | Dev/testing only |

### NFR-6.2: Environment
| ID | Requirement | Implementation | Notes |
|----|-------------|----------------|-------|
| NFR-6.2.1 | Flutter version | 3.44.4+ | Lockfile and CI authority pinned to 3.44.4 |
| NFR-6.2.2 | Dart version | 3.10.3+ language floor; canonical 3.12.2 | Bundled with Flutter; null safety |
| NFR-6.2.3 | Android SDK | min 24, compile/target 36 | Resolved by the current Flutter SDK; repo does not pin it |
| NFR-6.2.4 | iOS deployment target | 12.0+ | Background BLE remains limited |
| NFR-6.2.5 | Storage requirement | Artifact-derived | Baseline `9434384` debug APK is 205,113,616 bytes before installed data; release size unverified |

## NFR-7: Efficiency

### NFR-7.1: Battery Consumption
| ID | Requirement | Target | Mechanism |
|----|-------------|--------|-----------|
| NFR-7.1.1 | Continuous scanning drain | < 5%/hour | Burst scanning |
| NFR-7.1.2 | Idle battery drain | < 1%/hour | Duty cycling |
| NFR-7.1.3 | Active messaging drain | < 10%/hour | Optimized BLE writes |
| NFR-7.1.4 | Screen-off power mode | 90% reduction | LOW_POWER mode |
| NFR-7.1.5 | Battery level monitoring | Real-time | `BatteryOptimizer` |

### NFR-7.2: Resource Usage
| ID | Requirement | Target | Notes |
|----|-------------|--------|-------|
| NFR-7.2.1 | Memory footprint | < 150MB | Including UI |
| NFR-7.2.2 | Database size (typical) | < 50MB | 10k messages |
| NFR-7.2.3 | Network bandwidth | 1-5 KB/message | BLE limited |
| NFR-7.2.4 | CPU usage (idle) | < 2% | Background tasks |
| NFR-7.2.5 | CPU usage (active) | < 20% | Crypto operations |

### NFR-7.3: Storage Efficiency
| ID | Requirement | Mechanism | Implementation |
|----|-------------|-----------|----------------|
| NFR-7.3.1 | Message compression | Archive compression | Optional feature |
| NFR-7.3.2 | Database VACUUM | Monthly automatic | `DatabaseHelper.vacuumIfDue()` |
| NFR-7.3.3 | Image optimization | Not implemented | Future feature |
| NFR-7.3.4 | Log rotation | File-based logging | Partial |
| NFR-7.3.5 | Cache management | LRU caches | `HintCacheManager` |

## NFR-8: Compliance

### NFR-8.1: Legal
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-8.1.1 | Repository license | Proprietary | See `LICENSE`; public source does not grant reuse rights |
| NFR-8.1.2 | Privacy review | Not independently audited | No project-operated analytics, account, or message server |
| NFR-8.1.3 | Export control (crypto) | Jurisdiction review required | No exemption is claimed |
| NFR-8.1.4 | Third-party licenses | Distribution audit pending | Dependencies retain their own terms/notices |
| NFR-8.1.5 | Privacy policy | Included | `assets/privacy_policy.md` |

### NFR-8.2: Standards
| ID | Requirement | Standard | Compliance |
|----|-------------|----------|------------|
| NFR-8.2.1 | Noise Protocol | Noise Protocol Framework (Rev 34) | Implementation and automated vectors/tests; no independent conformance audit |
| NFR-8.2.2 | BLE GATT | Bluetooth 4.0+ GATT | Plugin/source implementation; hardware interoperability pending |
| NFR-8.2.3 | Cryptography | ChaCha20-Poly1305, X25519, SHA-256 | Algorithm selection only; no compliance certification claimed |
| NFR-8.2.4 | SQL | SQLite dialect | Implemented through SQLite/SQLCipher paths |
| NFR-8.2.5 | UTF-8 encoding | Unicode standard | Automated round-trip coverage; physical BLE row pending |

## NFR-9: Localization

### NFR-9.1: Internationalization
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-9.1.1 | Multi-language support | Not implemented | English only |
| NFR-9.1.2 | UTF-8 message support | Implemented | Full Unicode |
| NFR-9.1.3 | RTL language support | Not implemented | Future feature |
| NFR-9.1.4 | Date/time formatting | Implemented | `intl` package |
| NFR-9.1.5 | Currency formatting | Not applicable | No financial features |

## NFR-10: Compatibility

### NFR-10.1: Backward Compatibility
| ID | Requirement | Mechanism | Status |
|----|-------------|-----------|--------|
| NFR-10.1.1 | Database schema migrations | Version-based upgrades | Implemented through v12; latest upgrade/device proof pending |
| NFR-10.1.2 | Protocol versioning | `ProtocolMessage.version` plus peer floor | Implemented v2 enforcement; cross-version device proof pending |
| NFR-10.1.3 | Legacy preference cleanup | Retired importer shim | Removes obsolete keys only |
| NFR-10.1.4 | Archive format versioning | Not implemented | Future feature |
| NFR-10.1.5 | API stability | Internal only | Not applicable |

### NFR-10.2: Interoperability
| ID | Requirement | Status | Notes |
|----|-------------|--------|-------|
| NFR-10.2.1 | Cross-platform messaging | Device-gated | Android ↔ iOS has not been demonstrated |
| NFR-10.2.2 | Protocol compatibility | Internal automated coverage | Physical cross-device/version matrix pending |
| NFR-10.2.3 | Different app versions | Partial | Protocol floor exists; compatibility matrix pending |
| NFR-10.2.4 | Third-party implementations | Not claimed | Noise use alone does not define PakConnect envelope interoperability |
| NFR-10.2.5 | Export format portability | Versioned `.pakconnect` v2.1 bundle | Import/export automated coverage; external implementation not claimed |

---

**Document Version**: 1.0
**Last Updated**: 2026-07-14
**Total Non-Functional Requirements**: 105
