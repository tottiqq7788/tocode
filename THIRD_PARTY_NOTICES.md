# Third-Party Notices

## Pi coding agent

- Project: `earendil-works/pi`
- Source: https://github.com/earendil-works/pi
- Vendored commit: `581e7ba78141a4d8b61cc9d11b8b22ae7e59195e`
- License: MIT
- Copyright: 2025 Mario Zechner

The complete MIT license is preserved at `Vendor/pi-agent/LICENSE` and is copied
into `Tocode.app/Contents/Resources/Togent/PI_LICENSE` by the build.

The standalone Pi executable also contains its locked JavaScript/native runtime
dependencies. Their exact versions and declared license metadata are preserved
in `Vendor/pi-agent/package-lock.json`; the corresponding source manifests are
kept in the vendored snapshot. Tocode does not download or update these
dependencies at runtime.

## Bun

- Project: `oven-sh/bun`
- Source: https://github.com/oven-sh/bun
- Build/runtime version: `1.3.13`
- License: MIT

Bun is locked as a vendored development dependency and compiles the standalone
Pi executable. Its runtime is embedded in that executable; users do not need a
separate Bun installation. Bun's official runtime/linked-library notice is
preserved at `Vendor/pi-agent/BUN_LICENSE.md` and copied into the App resources.
