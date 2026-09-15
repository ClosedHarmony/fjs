# Precompiled fjs binaries (fork operations guide)

This fork publishes **signed precompiled generations** of the `libfjs` Rust
crate for every platform the Luotopia app ships, so app developers never need
a local Rust/NDK toolchain or 10+ minute cargo builds.

## What is published

`Build All Platforms` (and the reusable `Precompile Binaries` workflow it
calls) builds one complete *generation* per crate-hash and publishes it as a
GitHub release:

- Tag: `precompiled_<generation-hash>` (sha256 over the pinned hash inputs)
- Assets: `<rust-triple>_<artifact>` for every pinned target, each with an
  Ed25519 `<asset>.sig`, plus `completion.json` / `completion.json.sig`
  (the signed manifest), plus the SwiftPM composite
  (`fjs.xcframework.zip(.checksum)`).

Pinned targets (`libfjs/cargokit.yaml` → `build_recipe.rust_targets`):

| Platform | Rust triples |
| --- | --- |
| iOS | `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios` |
| macOS | `aarch64-apple-darwin`, `x86_64-apple-darwin` |
| Android | `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` (minSdk 21, NDK 28.2.13676358) |
| Windows | `x86_64-pc-windows-msvc` |
| Linux | `x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-gnu` |

Toolchain pins: Rust 1.97.1, Flutter 3.35.3, Xcode 16.4 (iOS SDK 18.5 /
macOS SDK 15.5). The minimum supported Flutter is 3.35.3: FRB 2.13.0
requires Dart >= 3.9.2, which first shipped in that release.

## Pipeline layout

`precompile-binaries.yml` runs one fragment builder per runner family, then
merges, signs and publishes:

1. `generation-status` — `verify-binaries`; if the generation for the current
   hash is already published, every later job is skipped (idempotent).
2. `darwin` (macos-15) — five Apple targets + the SwiftPM xcframework
   composite via `tool/build_fjs_xcframework.sh`.
3. `android-linux` (ubuntu) — three Android ABIs (NDK cross) + native Linux
   x64 via `build-precompiled-generation --android-sdk-location …
   --android-ndk-version … --android-min-sdk-version …`.
4. `linux-arm64` (ubuntu ARM) — native Linux arm64 on the hosted ARM runner.
5. `windows` — native MSVC x64.
6. `publish` (ubuntu) — `tool/merge_generations.dart` re-verifies every asset
   (length + sha256) and merges the fragments into one generation;
   `publish-precompiled-generation` signs it with
   `PRECOMPILE_BINARIES_PRIVATE_KEY` and uploads to the release; a final
   `verify-binaries` proves the published bytes.

Fragments must all come from the same commit: the generation hash covers
`cargokit/build_tool/lib`, `libfjs/**` sources, `libfjs/cargokit.yaml`, the
crate manifests/lockfile, the FRB-generated files, the darwin Package.swift
and the `tool/` build scripts (`hash_inputs` in `libfjs/cargokit.yaml`).

## Consumer side (the app)

CargoKit's built-in default is *"use precompiled binaries only when rustup is
absent"*. The app repository therefore ships a `cargokit_options.yaml` at its
root:

```yaml
precompiled_binaries_mode: auto
```

CargoKit finds it by walking parent directories from the platform root
project (`android/`, `windows/`, `linux/`, `ios/`, `macos/`), so one file
covers all platforms. `auto` downloads and signature-verifies the generation,
falling back to a local Rust build only when the download fails; use
`required` in reproducible-CI contexts and `disabled` to force local builds.

Downloads come from `url_prefix` in `libfjs/cargokit.yaml` (this fork's
release assets). Cached under the crate's CargoKit temp dir, keyed by
generation hash.

## Re-publishing after crate changes

Any change to a hashed input produces a new generation hash; pushing to
`main` triggers `Build All Platforms`, which publishes the new generation
after the quality gates. To publish without waiting for the gates, run the
`Precompile Binaries` workflow manually (`workflow_dispatch` on any branch
whose tree matches what consumers will pin).

Verify a published generation locally:

```sh
cd cargokit/build_tool && dart pub get
dart run bin/build_tool.dart verify-binaries --manifest-dir=../../libfjs
```

## Signing key management

- Public key: `precompiled_binaries.public_key` in `libfjs/cargokit.yaml`.
- Private key: repo secret `PRECOMPILE_BINARIES_PRIVATE_KEY` (Ed25519,
  64-byte hex). Never commit it.
- Rotation: `dart run bin/build_tool.dart gen-key`, update the secret and the
  `public_key` field (this changes the generation hash), push, and let the
  workflow re-publish. Old releases keep verifying for consumers pinned to
  older commits.
