# Changelog

## 1.0.0 (unreleased)

First public release.

- Run Markdown skills (mattpocock/skills format) fully on the phone with
  Qwen2.5-1.5B-Instruct through llama.cpp. Every reply is JSON that matches the
  skill's schema (grammar-constrained decoding).
- Chat: `/` autocomplete, input forms, live run cards with tool calls, skill
  suggestions for plain messages (never run automatically), plain chat.
- Skills tab with a live-validating editor.
- Tool servers (MCP over JSON-RPC, sandboxed in QuickJS): tasks in SQLite,
  device calendar, notes with semantic search (sqlite-vec + nomic-embed).
- Bundled skills: `/extract-tasks`, `/capture-tasks` (saves each task).
- Measured on a Snapdragon 680: 7.0 tok/s, repeat skill runs in 7-23 s thanks
  to prompt-prefix reuse, about 1.4 GB of memory while a model is loaded.
