# SkillCraft

An offline-first agent runtime for Android phones. Skills are plain Markdown
files (mattpocock/skills format: YAML frontmatter with inputs and an output
schema, then instructions). A local Qwen2.5-1.5B-Instruct model runs them
through llama.cpp with grammar-constrained decoding, so every reply is JSON
that matches the skill's schema. Tools such as a SQLite task list, the device
calendar and semantic notes search are MCP servers written in JavaScript and
sandboxed in QuickJS. Nothing leaves the phone.

Built and measured on a vivo V2205 (Snapdragon 680, 8 GB RAM, Android 14).

## What it does

- **Chat with skills.** Type `/` to pick a skill; skills that need several
  inputs open a form. Runs show the JSON as it streams, each tool call, and
  the output as cards. Plain messages get a normal reply, or a
  "Run /skill?" suggestion when a skill matches (never run automatically).
- **Write your own skills** in the Skills tab. The editor validates as you
  type and points at the line with the problem.
- **Tools over MCP.** `local_db` (save, list and update tasks), `calendar`
  (create and list events) and `notes` (remember and search notes by
  meaning). Each server runs in its own QuickJS sandbox and only gets the
  host functions it is granted.
- **Agent loop.** A skill can call tools for up to three steps; the last step
  is constrained to a final answer, so a run always ends. An `on_output` hook
  can call a tool for every item of the result (e.g. save each extracted task).

### Example skill

```markdown
---
name: capture-tasks
description: Extracts actionable tasks from raw text and saves each one.
inputs:
  raw_text:
    type: string
    required: true
on_output:
  tool: save_task_to_db
  for_each: tasks
output_schema:
  type: object
  properties:
    tasks:
      type: array
      items:
        type: object
        properties:
          title: {type: string}
          priority: {type: string, enum: [high, medium, low]}
          due_date: {type: string}
        required: [title, priority]
---

# Instructions
1. Extract only concrete actions someone has to do...
```

`tools: [...]` lists tools the model may call; `on_output` is a SkillCraft
extension that runs a tool deterministically on the result.

## Repository layout

| Path | What it is |
| --- | --- |
| `app/` | Flutter app (Android, arm64-v8a, minSdk 24) |
| `app/assets/skills/` | Bundled skills, copied to the phone on first run |
| `app/assets/tools/` | JavaScript MCP tool servers and their prelude |
| `app/tool/device/` | adb scripts for performance and battery measurements |
| `packages/llama_ffi/` | llama.cpp behind a small C API (`sc_llama`): generation, grammar, embeddings, prompt-prefix reuse |
| `packages/quickjs_ffi/` | QuickJS-ng with an async host bridge for sandboxed tool scripts |
| `packages/sqlite_vec_ffi/` | sqlite-vec registered as an extension of `package:sqlite3` |

Native sources come in as pinned git submodules: llama.cpp `b11983`,
quickjs-ng `v0.17.0`, sqlite-vec `v0.1.9`.

## Building

Requirements: Flutter (stable), Android SDK with platform 36, NDK
`28.2.13676358` and CMake `3.22.1`, `ANDROID_HOME` set.

```bash
git clone https://github.com/jer-hub/skillcraft-mobile.git
cd skillcraft-mobile
git submodule update --init --recursive
cd app
flutter pub get
flutter run --release
```

The first native build compiles llama.cpp and takes 10-20 minutes.

After running integration tests, run `flutter pub get` before a release build:
`flutter test integration_test/...` registers the test-only `integration_test`
plugin in the generated Android plugin list, and a release build (which
leaves dev dependencies out) then fails to compile until it is regenerated.

The Snapdragon 680's Cortex-A73/A53 cores are ARMv8.0-A, so llama.cpp is built
with `-march=armv8-a` and no dotprod/i8mm instructions; a build for newer
cores would crash on it with SIGILL.

## Release signing

Release builds are signed with the upload key named in
`app/android/key.properties` (gitignored). Without that file they fall back
to the debug key, which is fine for testing but must not be published.

Create the keystore once, outside the repo, and **back it up**: if it is lost,
installed copies can no longer be upgraded.

PowerShell:

```powershell
& "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -genkeypair -v -keystore "$HOME\skillcraft-upload.jks" -keyalg RSA -keysize 4096 -validity 10000 -alias upload
```

Git Bash / macOS / Linux (adjust the `keytool` path to your JDK):

```bash
"C:/Program Files/Android/Android Studio/jbr/bin/keytool.exe" -genkeypair -v -keystore "$HOME/skillcraft-upload.jks" -keyalg RSA -keysize 4096 -validity 10000 -alias upload
```

Then create `app/android/key.properties`:

```properties
storeFile=C:/Users/<you>/skillcraft-upload.jks
storePassword=<keystore password>
keyAlias=upload
keyPassword=<key password>
```

Check the signer with
`apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk`
(it must not say `CN=Android Debug`).

## Models

Models are not bundled. On first run SkillCraft offers to **download** them
from Hugging Face or to **import** a file you already have. Downloads come
from URLs pinned to a fixed Hugging Face commit, warn you first on mobile data,
check free space, can be paused and resumed (also from the notification), and
are checked against the published SHA-256 before use:

| Model | Role | Size | Source |
| --- | --- | --- | --- |
| `Qwen2.5-1.5B-Instruct-Q4_K_M.gguf` | Required: skills and chat | 1.12 GB | [Qwen/Qwen2.5-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF) |
| `nomic-embed-text-v1.5.Q4_K_M.gguf` | Optional: notes search, skill suggestions | 84 MB | [nomic-ai/nomic-embed-text-v1.5-GGUF](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF) |

You can also copy them over USB into
`Android/data/com.skillcraft.app/files/models/` with those file names.

**Privacy:** the `INTERNET` permission is used only for these two downloads.
Skills, chat, tool servers and your tasks and notes never leave the phone.

## Testing

```bash
cd app
flutter analyze
flutter test                      # unit and widget tests, no device needed
node tool/js/check_tools.mjs      # tool-server scripts against a fake host
```

On-device integration tests need the phone connected, unlocked and the
models installed:

```bash
flutter test integration_test/runtime_test.dart -d <device> --no-uninstall
```

**Always pass `--no-uninstall`.** Without it Flutter uninstalls the app after
the run, and Android deletes the imported models with it. `flutter drive`
(used for profile-mode runs) does the same and has no flag to prevent it.
Tests install a debug-signed build. If the phone has the release APK signed
with your own key, Flutter uninstalls it first (signatures differ), so the
models go even with `--no-uninstall`; back them up first.
`integration_test/download_test.dart` downloads the embedding model over
Wi-Fi into a temporary folder (pause, resume, SHA-256 check).

| Suite | Checks |
| --- | --- |
| `runtime_test` | QuickJS sandbox, sqlite-vec, tool servers, embeddings, a full agent run |
| `app_test` | The chat UI end to end; skill-suggestion scores |
| `grammar_test` | 50 varied inputs (Taglish, injections, very long text) must all give schema-valid JSON |
| `memory_test` | No memory growth over repeated generations, skill runs and reloads |
| `perf_test` | Engine and UI timings |

Keep the screen on during long device test runs: Android moves an app that
is off screen to the slow cores (about 3x slower), and some phones kill it
after a few minutes. In the app itself, a foreground service with a Stop
action protects each run; `tool/device/background_run.sh` measures a run with
the screen off.

## Measured on the Snapdragon 680

| | Result |
| --- | --- |
| Generation (release build) | 7.0 tok/s (raw llama.cpp: 7.8) |
| Prompt reading | about 11-12 tok/s |
| `/extract-tasks`, first run | about 60-65 s (most of it reading the 550-token prompt) |
| `/extract-tasks`, repeat run | 7-23 s (the shared prompt prefix is reused from the KV cache) |
| Memory while loaded | about 1.4 GB, back to about 250 MB on unload |
| Grammar guarantee | 50/50 inputs schema-valid (one salvaged as partial) |
| Battery | about 6-7 mAh per skill run (~0.13% of 4910 mAh), estimated |
| Release APK | 73 MB |
| `/extract-tasks`, screen off | 118-126 s and not killed, with or without the battery exemption (before the run service: about 170 s, then killed after about 4 min) |

Known limitations of the 1.5B model:

- **Texts with no actions.** The task skills make the model answer a yes/no
  `has_actions` question first, and the grammar ties the list to it (`false`
  forces an empty list). That took no-task inputs from 0 of 6 returning an
  empty list to 4 of 6. News-like text and casual remarks can still produce
  invented tasks.
- **Very long inputs.** When an input is truncated to fit the context, the
  model may lose the part that mattered and copy a task from the skill's
  example instead.
