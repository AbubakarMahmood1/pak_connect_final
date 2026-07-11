# High-Level Use Cases

Brief summaries of all use cases for quick reference.

## UC-1: Send Message
**Actor**: User
**Description**: User sends an encrypted message to a contact via BLE
**Outcome**: Message delivered or queued for later delivery

## UC-2: Encrypt Message
**Actor**: System
**Description**: System encrypts plaintext using Noise Protocol session
**Outcome**: Ciphertext ready for transmission

## UC-3: Queue Offline Message
**Actor**: System
**Description**: System queues message when recipient is offline
**Outcome**: Message persisted with retry schedule

## UC-4: Receive Message
**Actor**: BLE System
**Description**: Device receives encrypted message via BLE notification
**Outcome**: Message decrypted and displayed to user

## UC-5: Decrypt Message
**Actor**: System
**Description**: System decrypts ciphertext using Noise Protocol
**Outcome**: Plaintext message extracted

## UC-6: Relay Message
**Actor**: System
**Description**: System forwards message to next hop in mesh network
**Outcome**: Message relayed toward final destination

## UC-7: Add Contact via QR
**Actor**: User
**Description**: User scans QR code to add new contact
**Outcome**: Contact saved with established Noise session

## UC-8: Perform Noise Handshake
**Actor**: System
**Description**: System executes XX or KK handshake pattern
**Outcome**: Encrypted session established

## UC-9: Verify Contact
**Actor**: User
**Description**: User verifies contact identity via PIN or fingerprint
**Outcome**: Security level upgraded to MEDIUM or HIGH

## UC-10: Delete Contact
**Actor**: User
**Description**: User removes contact from contact list
**Outcome**: Contact and associated data deleted

## UC-11: Mark Favorite
**Actor**: User
**Description**: User marks contact as favorite
**Outcome**: Contact appears in favorites list

## UC-12: Search Contacts
**Actor**: User
**Description**: User searches contacts by name or public key
**Outcome**: Filtered list of matching contacts displayed

## UC-13: Open Chat
**Actor**: User
**Description**: User opens conversation with a contact
**Outcome**: Chat history displayed

## UC-14: Archive Chat
**Actor**: User/System
**Description**: Chat moved to archive storage
**Outcome**: Chat hidden from main list, searchable in archives

## UC-15: Pin Chat
**Actor**: User
**Description**: User pins chat to top of list
**Outcome**: Chat appears at top regardless of last message time

## UC-16: Delete Chat
**Actor**: User
**Description**: User deletes entire conversation
**Outcome**: Chat and all messages removed

## UC-17: Export Chat
**Actor**: User
**Description**: User exports chat history to file
**Outcome**: JSON or text file created and shared

## UC-18: Search Messages
**Actor**: User
**Description**: User searches for messages by content
**Outcome**: Matching messages displayed with context

## UC-19: Star Message
**Actor**: User
**Description**: User marks message as starred/important
**Outcome**: Message accessible via starred messages list

## UC-20: Create Broadcast List
**Actor**: User
**Description**: User creates a local named recipient list
**Outcome**: Empty sender-local list created, ready for recipients

## UC-21: Add Recipient to List
**Actor**: User
**Description**: User adds a contact to an existing local list
**Outcome**: Contact receives future broadcasts as ordinary direct messages

## UC-22: Remove Recipient from List
**Actor**: User
**Description**: User removes a contact from the local list
**Outcome**: Contact no longer receives future broadcasts from that list

## UC-23: Send Broadcast
**Actor**: User
**Description**: User queues the same content for all list recipients
**Outcome**: Individual direct messages are queued for each recipient; no
shared group conversation is created on recipient devices

## UC-24: View Recipient Queue Status
**Actor**: User
**Description**: User checks each recipient's local queue-submission status
**Outcome**: Status list displays pending, queued, or failed; correlated
delivery receipts are not currently wired

## UC-25: Generate Identity Keys
**Actor**: System
**Description**: System generates X25519 static keypair on first launch
**Outcome**: Identity keys stored in secure storage

## UC-26: Initiate Handshake (XX Pattern)
**Actor**: System
**Description**: 3-message handshake for new contacts
**Outcome**: Mutual authentication, session established

## UC-27: Initiate Handshake (KK Pattern)
**Actor**: System
**Description**: 2-message handshake for known contacts
**Outcome**: Fast session re-establishment

## UC-28: Rekey Session
**Actor**: System
**Description**: System regenerates ephemeral keys after 10k messages or 1 hour
**Outcome**: Forward secrecy maintained

## UC-29: Upgrade Security Level
**Actor**: User
**Description**: User upgrades contact from LOW to MEDIUM/HIGH security
**Outcome**: Persistent keys exchanged, verification completed

## UC-30: Rotate Ephemeral Keys
**Actor**: System
**Description**: System periodically generates new ephemeral IDs
**Outcome**: Privacy enhanced, old keys cleaned up

## UC-31: Process Incoming Relay Message
**Actor**: System
**Description**: System decides whether to relay or deliver received message
**Outcome**: Message delivered locally or forwarded

## UC-32: Relay to Next Hop
**Actor**: System
**Description**: System forwards message using smart routing
**Outcome**: Message sent to optimal next hop

## UC-33: Deliver to Self
**Actor**: System
**Description**: System delivers relay message intended for current node
**Outcome**: Message saved to repository, user notified

## UC-34: Block Duplicate
**Actor**: System
**Description**: System detects and drops duplicate relay messages
**Outcome**: Message dropped, network flood prevented

## UC-35: Prevent Spam
**Actor**: System
**Description**: System enforces rate limits on relay messages
**Outcome**: Spam messages blocked

## UC-36: Sync Message Queues
**Actor**: System
**Description**: System synchronizes offline queues between devices
**Outcome**: Missing messages exchanged, queues consistent

---

**Total Use Cases**: 36
**Actor Distribution**: User (17), System (19)
**Last Updated**: 2025-01-19
