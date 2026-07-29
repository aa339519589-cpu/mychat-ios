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

## Repeatable device deployment

With the developer iPhone connected and unlocked:

```bash
scripts/deploy-device.sh
```

Override the device when necessary:

```bash
MYCHAT_DEVICE_ID="<device identifier>" scripts/deploy-device.sh
```
