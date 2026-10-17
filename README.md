# Swiftwarden

A native, dependency-free Bitwarden client for macOS written in Swift and SwiftUI. It works with bitwarden.com, bitwarden.eu and self-hosted servers (official Bitwarden or Vaultwarden), autofills logins into other Mac apps through the Accessibility API, and unlocks with Touch ID.

The release app is about 5 MB (universal arm64 + x86_64) and has no third-party dependencies: all crypto (AES-CBC + HMAC, RSA-OAEP, PBKDF2, HKDF and a pure-Swift Argon2id) uses CommonCrypto, CryptoKit and Security.framework.

## Features

- **Accounts**: log in with master password (PBKDF2 or Argon2id), two-step login (authenticator app, email, YubiKey OTP, remember device), new-device email verification, personal API key login, account creation, password hint.
- **Unlock**: master password, Touch ID, PIN (optionally requiring the master password after restart), auto-lock after system idle, on sleep or on screen lock, lock or log out as timeout action.
- **Vault**: logins, cards, identities, secure notes and SSH keys; folders; favorites; organizations and collections; trash with restore and permanent delete; custom fields (text, hidden, checkbox, linked); multiple URIs with match detection; password history; master password re-prompt; attachments (upload, download, delete); clone; move to organization; per-item cipher keys.
- **TOTP**: live codes with countdown ring, otpauth:// and Steam keys, copy after autofill.
- **Passkeys**: passkeys stored in Bitwarden are shown and preserved on edit.
- **Security report**: weak, reused, http-only, and exposed passwords (Have I Been Pwned, k-anonymity).
- **Generator**: passwords, passphrases (EFF wordlist), usernames (random word, plus-addressed, catch-all, forwarded aliases via addy.io, SimpleLogin, DuckDuckGo, Firefox Relay, Forward Email), encrypted local history.
- **Send**: text and file Sends with deletion/expiry dates, max access count, password, hide email, disable.
- **Import / export**: Bitwarden JSON, CSV and password-protected JSON; generic CSV from Chrome, Edge, Firefox, Safari, 1Password and others.
- **Autofill in other apps**: when a password (or username) field gets focus in any app, a small panel offers matching logins. Websites are matched by the browser's page URL, native apps by bundle id or name (store `macapp://com.example.app` as a URI for an exact match). The quick-fill shortcut (default ⇧⌘L) opens a searchable palette for the focused field. Fill by typing keystrokes, setting the field value, or pasting.
- **Menu bar**: search, copy username/password/code, generate a password, lock.
- **Other**: fingerprint phrase, launch at login, clipboard auto-clear (marked concealed for clipboard managers), website icons, appearance.

## Build

Requirements: Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

    scripts/build.sh            # Release build into dist/Swiftwarden.app
    scripts/build.sh Debug

Without `SIGN_IDENTITY` the app is ad-hoc signed and macOS asks for Accessibility access again after every build. Sign with a stable identity to keep it:

    SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build.sh

macOS can still drop the grant after re-signing; toggle Swiftwarden off and on in System Settings → Privacy & Security → Accessibility if autofill stops reacting.

To work in Xcode, run `xcodegen generate` and open `Swiftwarden.xcodeproj`.

## Layout

    Core/                       Swift package, no UI
      Sources/SwiftwardenCore/
        Crypto/                 EncString, AES/HMAC, RSA + DER, KDFs, Argon2id
        API/                    server environments, HTTP client, token refresh
        Vault/                  models, VaultService, TOTP, generator, import/export, URL matching
      Tests/                    unit tests + integration tests
    App/Sources/
      App/                      app entry, AppModel (state, lock, sync), storage, preferences
      Views/                    SwiftUI screens
      Autofill/                 Accessibility observer, floating panels, hotkey, fill methods

## Tests

    cd Core && swift test

Unit tests cover BLAKE2b, Argon2id (RFC 9106 vector), PBKDF2, EncString, RSA, TOTP (RFC 6238), the generator, strength scoring, URL matching, CSV parsing and encrypted export.

Integration tests run against a real server. A throwaway Vaultwarden works:

    docker run -d --name vw -e SIGNUPS_ALLOWED=true -p 8787:80 vaultwarden/server
    cd Core
    SW_IT_EMAIL=it@test.local SW_IT_PASSWORD='Integration-Pass-123!' SW_IT_PHASE=1 swift test --filter IntegrationTests
    SW_IT_EMAIL=it@test.local SW_IT_PASSWORD='Integration-Pass-123!' SW_IT_PHASE=2 swift test --filter IntegrationTests
    SW_SEED_EMAIL=demo@test.local SW_SEED_PASSWORD='Demo-Password-123!' swift test --filter 'SeedTests|OrgTests'

Phase 1 registers an Argon2id account and writes items, history, attachments and a Send. Phase 2 reads items written by the official `bw` CLI (which uses per-item cipher keys), imports and trashes. The org test creates an organization and checks RSA org keys, collections and moving items into the org.

## Not supported yet

- Duo and FIDO2/WebAuthn as two-step login methods (they need a browser flow; use authenticator/email or API key login).
- SSO, trusted-device and Key Connector logins.
- Creating passkeys and the system-wide AutoFill credential provider (needs an app extension with Apple-provisioned entitlements).
- Several accounts logged in at once.
- Bitwarden's SSH agent.

Swiftwarden is an independent project and is not affiliated with Bitwarden Inc.
