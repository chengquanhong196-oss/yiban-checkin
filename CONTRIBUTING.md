# Contributing to yiban-checkin

Thanks for your interest in contributing! Here's how to get started.

## Before You Start

1. **Search existing issues & PRs** — both open AND closed. Your idea may already be in progress.
2. **Open an issue first** — describe your idea or bug report before writing code. This prevents wasted effort.
3. **Keep it focused** — one feature or bug fix per PR. Don't bundle unrelated changes.

## Development Setup

```bash
git clone https://github.com/<your-username>/yiban-checkin.git
cd yiban-checkin
swift build -c release
```

**Requirements:**
- macOS 13+ (Ventura or later)
- Xcode 15+ or Swift 5.9+ toolchain
- No external Swift dependencies — pure Apple frameworks only

## Project Structure

```
Sources/
├── Core/             # Shared library (CLI + GUI)
│   ├── YibanAPI.swift           # REST API client
│   ├── AppAutomator.swift       # OCR + mouse/keyboard automation
│   ├── CheckinOrchestrator.swift # Unified checkin workflow
│   ├── LocationChecker.swift    # CoreLocation geofencing
│   ├── ScreenCapture.swift      # Screenshot utilities
│   ├── VerificationSolver.swift # CAPTCHA recognition
│   ├── Config.swift             # Configuration management
│   ├── Keychain.swift           # macOS Keychain wrapper
│   ├── Logger.swift             # Logging module
│   ├── Notifier.swift           # System notifications + push
│   ├── PermissionChecker.swift  # Permission diagnostics
│   └── CheckinHistory.swift     # Check-in history & stats
├── CLI/              # Command-line executable
│   └── main.swift
└── GUI/              # macOS app (SwiftUI)
    ├── YibanCheckinApp.swift
    ├── MenuBarController.swift
    ├── ContentView.swift
    ├── DashboardView.swift
    ├── SettingsView.swift
    ├── CheckinManager.swift
    └── LogViewer.swift
```

## Coding Guidelines

- **Match the existing style** — same indentation, naming, and comment density
- **No external dependencies** — this project is zero-dependency by design. Use Apple frameworks only
- **Add logging** — use `Logger.info/warn/error/success` for meaningful events
- **Handle errors explicitly** — avoid `try?` in production paths; use proper `do/catch` with recovery
- **Keep modules focused** — each file under Core/ should have one clear responsibility

## Testing

```bash
# Run the test suite
swift test

# Build for release
swift build -c release

# Run CLI diagnostics
.build/release/yiban-checkin --diagnose

# Test API connectivity
.build/release/yiban-checkin --check-api
```

## Pull Request Checklist

- [ ] One feature/fix per PR
- [ ] Code matches project style
- [ ] No new external dependencies
- [ ] Builds cleanly: `swift build -c release` with no warnings
- [ ] Tested on macOS 13+ with Xcode 15+
- [ ] Related issue linked in PR description
- [ ] README updated if user-facing changes

## Communication

- Use Issues for bug reports and feature requests
- Be respectful and constructive
- This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md)

## License

By contributing, you agree that your contributions will be licensed under the [GPL-3.0 License](LICENSE).
