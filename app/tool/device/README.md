# Device measurement scripts

Run on the phone over adb (Git Bash: set `MSYS_NO_PATHCONV=1` first). Start
with the phone unlocked and SkillCraft installed with its models.

```bash
adb push tool/device/perf_drive.sh /data/local/tmp/ && adb shell sh /data/local/tmp/perf_drive.sh
```

- `perf_drive.sh`: two `/extract-tasks` runs through the chat UI (cold, then
  with prompt reuse) and Engine debug tok/s. Install a release or debug build
  with `adb install -r` (keeps the models; `flutter drive` does not).
- `battery_run.sh`: 10 varied `/extract-tasks` runs while Android is told the
  phone is on battery (`dumpsys battery unplug`, always undone by a trap), then
  SkillCraft's batterystats line. Set `UID_TAG` to the app's uid
  (`adb shell pm list packages -U | grep skillcraft`).

Measured on vivo V2205 (Snapdragon 680), 2026-10-30, debug build:
10 runs in 345 s (first 61 s cold, then 7-23 s with 526 prompt tokens
reused). batterystats: screen 15.4 mAh. Its CPU figure (0.67 mAh) is not
usable: this phone ships a generic power profile (one cluster, max 1.55 GHz).
From 982 s of CPU time at ~155-207 mA per busy Cortex-A73 core, CPU is about
42-56 mAh, so roughly 6-7 mAh per run (~0.13% of 4910 mAh).
