# MyChat Native iPhone Client

This repository is the native iOS client. It shares the production HTTPS API
with the web product, but its source code, Git history, releases, and device
deployments are independent from `aa339519589-cpu/mychat`.

## Release boundary

- Native repository: `aa339519589-cpu/mychat-ios`
- Default branch: `main`
- Native commits and device releases belong only in this repository.
- Web, server, Supabase, and Render changes belong only in
  `aa339519589-cpu/mychat`.
- A native iteration is complete only after commit, GitHub push, signed device
  build, install, launch, and device-side verification.

## Architecture

- SwiftUI renders the app shell, history, model menu, messages, and composer.
- `URLSession` talks directly to the existing HTTPS API and durable SSE stream.
- Supabase access and refresh tokens are stored in the iOS Keychain.
- The application shell and interaction are native SwiftUI. A message-scoped
  `WKWebView` is used only for sandboxed rich response rendering such as
  Markdown, formulas, SVG, Mermaid, Vega, and artifacts.

## Native UI contract

- The app uses a continuous, content-first editorial layout in light and dark
  appearances.
- The composer shell is restored from commit `4c0dd66`; attachment and speech
  states extend that shell without replacing its dimensions or keyboard inset.
- Settings use a navigation hierarchy for account, memory, models, system
  prompt, and usage.
- `scripts/verify-ui-contract.sh` guards the composer geometry, Thinking
  indicator, settings order, project sources, and removal of the retired
  deep-network mode.

## Repeatable device deployment

With the developer iPhone connected and unlocked:

```bash
scripts/deploy-device.sh
```

The deployment script now fetches and fast-forwards to `origin/main`, rejects
uncommitted or divergent source, verifies the UI contract, deletes old
DerivedData, performs a clean build with a revision-specific build number, and
blocks installation if retired sidebar content appears in the compiled app.

To remove the installed copy before reinstalling the exact current build:

```bash
git pull --ff-only && MYCHAT_FRESH_INSTALL=1 scripts/deploy-device.sh
```

Override the device when necessary:

```bash
MYCHAT_DEVICE_ID="<device identifier>" scripts/deploy-device.sh
```
