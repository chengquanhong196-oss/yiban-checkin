# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] — Unreleased

### Added
- **macOS app** with SwiftUI dashboard, menu bar icon, and system notifications
- **CLI tool** for headless use with launchd scheduling
- **API mode** — pure REST client for login + evening check-in (based on Qs315490/fyiban)
- **OCR mode** — Vision framework text recognition + CGEvent mouse simulation with automatic fallback
- **CAPTCHA solver** — color/shape detection for automatic verification bypass
- **Location checking** — CoreLocation geofencing with Haversine distance calculation
- **Keychain integration** — secure storage for passwords and API keys
- **Permission diagnostics** — startup check for Accessibility, Location, and app installation
- **Check-in history** — streak tracking, monthly stats, and 7-day status view
- **Menu bar controller** — at-a-glance status icon with quick actions
- **Server酱 push** — WeChat notification for check-in results
- **Cloud backup** — Python script + GitHub Actions workflow for server-side API check-in
- **Debug tools** — `--inspect` (UI explorer), `--diagnose` (permission check), `--check-api` (API test)
- **iPhone Shortcut** — semi-automated iOS workflow (README only)

### Changed
- Refactored 1370-line `AppAutomator.swift` into 3 focused modules (AppAutomator, ScreenCapture, VerificationSolver)
- Extracted shared check-in flow into `CheckinOrchestrator` (used by both CLI and GUI)
- Moved hardcoded check-in time window to `Config`
- Improved API error discrimination (permanent vs retryable errors)

### Fixed
- Base64 password encoding in URL query parameters
- Race condition in LocationChecker continuation (double-resume crash)
- Plaintext password storage → macOS Keychain
- Session expiration auto-re-login in API mode
- Hardcoded username path in `com.yiban.checkin.plist`

### Security
- Passwords and API keys stored in macOS Keychain, not plaintext JSON config
- Config file excludes sensitive fields via Codable CodingKeys
