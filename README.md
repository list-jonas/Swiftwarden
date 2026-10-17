# Swiftwarden

Native, dependency-free Bitwarden client for macOS, written in Swift/SwiftUI.

Work in progress — see below.

## Layout

- Core/Sources/SwiftwardenCore — crypto (AES-CBC+HMAC, RSA-OAEP, PBKDF2, pure-Swift Argon2id), Bitwarden API client, vault model, TOTP, generator, import/export.
- Core/Tests — unit tests plus optional integration tests against a Bitwarden-compatible server.

## Tests

    swift test

Integration (needs a Vaultwarden/Bitwarden server):

    SW_IT_SERVER=http://localhost:8787 SW_IT_EMAIL=you@test.local SW_IT_PASSWORD=... SW_IT_PHASE=1 swift test --filter IntegrationTests
