# SkillCraft

Offline-first Android agent runtime: Markdown skills (mattpocock/skills format) executed by a local
Qwen2.5-1.5B-Instruct Q4_K_M model via llama.cpp, with grammar-constrained JSON output dispatched to
MCP-style tools hosted in QuickJS. Target device: Snapdragon 680 / 8 GB RAM.

## Layout

| Path | Purpose |
| --- | --- |
| `app/` | Flutter application (Android, arm64-v8a, minSdk 24) |
| `packages/llama_ffi/` | Flutter FFI plugin wrapping llama.cpp (`third_party/llama.cpp` submodule) |

## Getting started

```bash
git submodule update --init --recursive
cd app && flutter pub get
flutter run
```

Requirements: Flutter (stable), Android SDK, Android NDK r26+ (set `ANDROID_HOME`).

The model file (`Qwen2.5-1.5B-Instruct-Q4_K_M.gguf`) is imported on first run, not bundled.

## Build notes

The Snapdragon 680 cores (Cortex-A73/A53) are ARMv8.0-A: llama.cpp is built with
`-march=armv8-a` and **no** dotprod/i8mm flags, otherwise it crashes with SIGILL.
