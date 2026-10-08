# MyChat native Build 102 — quality workstream

This directory is the self-contained, current native client snapshot. The older
root-level client is deliberately preserved. Open `MyChatIOS.xcodeproj` **inside
this directory**; do not use the root client's deployment script for this build.

## Scope

- Keeps MyChat's brand, AppIcon, Logo and Dot assets; no backend or Web changes.
- UIKit keyboard layout, 44-point composer controls, a stable opaque writing
  surface, legal OFL Newsreader reading faces and improved secondary contrast.
- Conversation-scoped reading-position restoration, user-owned scrolling, and
  horizontal square photo thumbnails that retain their own pan gesture.
- Semantic system haptics with a persisted user preference. Simulator tests do
  not establish physical haptic quality or equivalence to Claude's internals.
- Existing authentication, chat/SSE/recovery, voice, memory, projects,
  artifacts and Code source paths remain. This branch is not the separate cloud
  Code workspace rewrite, and does not claim unsupported backend capabilities.

## Reproduce

Use Xcode with the iOS 27 runtime installed for this workstream's simulator
acceptance. The inherited deployment target is unchanged; older iOS runtimes
have not been tested in this workstream.

```sh
cd NativeApp
xcodebuild -project MyChatIOS.xcodeproj -scheme MyChatIOS \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MyChatIOS.xcodeproj -scheme MyChatIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MyChatIOS.xcodeproj -scheme MyChatIOS \
  -configuration Debug -destination 'platform=iOS Simulator,id=<your-iOS-27-device-id>' \
  -parallel-testing-enabled NO -collect-test-diagnostics never test
```

Tests using `NativeRuntimeFixture` are explicitly network-isolated. They validate
the production AppModel and UI against controlled services, not real model
availability, actual uploads or network latency. Live tests are separately
opt-in and require a signed-in test account. Never commit tokens or Keychain data.

## Provenance and distribution

The local development tree inherited a newer native snapshot, not a descendant
of this repository's old `main`. Its accepted source was checkpointed at
`30fa2d67b3c0716c7c49d50a528f97a68437e253` before this quality work. This export
keeps the repository's upstream ancestry without publishing the local old-font
history or attributing all inherited functionality to the quality workstream.
The quality increment is local commit
`d39bec0b091ece414f37951e3b75ccc89a4503ef`. All 122 exported source/resource files
match that tree by SHA-256, excluding only the documented old fonts and Xcode
user state. This export itself also passed a clean Debug simulator build.

The export omits the inherited `Resources/ResponseFonts` directory because no
redistribution grant was found. The active `Resources/ReadingFonts` files are
unmodified Newsreader faces distributed with OFL and NOTICE. No reference
repository code or Claude brand assets were copied for these changes.

This is a development branch, not a production release. Device installation,
subjective haptic acceptance, and real-network acceptance must be reported
separately from compilation and fixture-based tests.

## Acceptance snapshot — 2026-10-08

- Final large-device run: 88 runtime tests and 5 UI tests passed; one live
  custom-endpoint test skipped because it is explicitly opt-in.
- Across the full UI run and targeted repairs, all 29 distinct UI cases have
  passed. This is an aggregate result, not a claim of a new single all-green run.
- iPhone SE (3rd generation), iOS 27: image pan/preview and XXXL text/rotation
  tested. A stricter geometry test exposed a real landscape overlap; the new
  measured composer growth budget fixed it and its targeted rerun passed.
- Fresh Release device build passed unsigned. No App Store/TestFlight release
  or physical-device installation was performed by this workstream.
- Standalone real-network probe could not start: the isolated simulator had
  no stored account. Actual upload/network/recovery and physical haptic feel
  remain pending; fixture responses are not live-service proof.
- The old local `scripts/verify_native_contracts.py` encodes superseded static
  layout expectations and did not pass. It is not included or represented as
  the acceptance runner for this snapshot.
