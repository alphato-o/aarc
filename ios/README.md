# ios/

Xcode workspace for AARC: iOS app + watchOS app + the shared `AARCKit` Swift package + their test targets.

This directory is empty until [Phase 0 — Foundation](../docs/phases/phase-0-foundation.md) creates the Xcode project (task 0.1.2 onwards).

Expected layout once scaffolded:

```
ios/
├── AARC.xcodeproj/                  ← or AARC.xcworkspace if SPM-heavy
├── AARC/                            ← iOS app target
├── AARCWatch Watch App/             ← watchOS app target
├── AARCKit/                         ← local Swift Package (cross-target shared types)
│   └── Package.swift
├── AARCTests/                       ← iOS unit tests
├── AARCUITests/                     ← iOS UI tests
└── AARCWatchTests/                  ← watchOS unit tests
```

Tests live alongside the code, not in a top-level `tests/` directory — that's the iOS convention.
