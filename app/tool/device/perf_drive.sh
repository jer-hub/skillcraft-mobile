#!/system/bin/sh
# Same work on whichever SkillCraft build is installed: two /extract-tasks
# runs through the chat UI, then Engine debug's plain-generation tok/s.
UI=/data/local/tmp/ui.xml
CMD='/extract-tasks Jo fixes the login bug by Thursday. Mark updates the release notes.'

dump() { uiautomator dump $UI >/dev/null 2>&1; }
tap() {
  what=$1
  dump
  b=$(grep -oE "<node [^>]*$what[^>]*>" $UI | head -1 | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+')
  set -- $b
  [ -z "$4" ] && { echo "NOT FOUND: $what"; return 1; }
  input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}
wait_ui() {  # pattern, seconds
  for i in $(seq 1 $2); do input keyevent KEYCODE_WAKEUP; dump; grep -qE "$1" $UI && return 0; sleep 1; done
  echo "TIMEOUT ui $1"; return 1
}
runs() { logcat -d -s flutter | grep -c SKILL_RUN; }
wait_run() {
  for i in $(seq 1 120); do input keyevent KEYCODE_WAKEUP; [ "$(runs)" -ge "$1" ] && return 0; sleep 2; done
  echo "TIMEOUT run $1"
}

input keyevent KEYCODE_WAKEUP
am force-stop com.skillcraft.app
logcat -c
am start -W -n com.skillcraft.app/.MainActivity >/dev/null
wait_ui 'class="android.widget.EditText"' 90
wait_ui 'extract-tasks' 60   # skills listed = chat deps ready

for n in 1 2; do
  tap 'class="android.widget.EditText"'; sleep 1
  input text "$(echo "$CMD" | sed 's/ /%s/g')"; sleep 1
  input keyevent KEYCODE_BACK; sleep 1
  tap 'content-desc="Send"'
  wait_run $n
done
logcat -d -s flutter | grep SKILL_RUN | sed 's/.*SKILL_RUN/SKILL_RUN/'

# Engine debug: plain generation with the default prompt.
tap 'content-desc="Settings'; sleep 2
for i in 1 2 3 4; do input swipe 540 1800 540 600 300; sleep 1; done
tap 'Engine debug'; sleep 2
tap 'content-desc="Use installed model"'; sleep 1
tap 'content-desc="(Re)?[Ll]oad model'
wait_ui 'Loaded in' 60
tap 'content-desc="Generate"'
wait_ui 'tok/s' 240
grep -oE 'content-desc="[^"]*(tok/s|Loaded in)[^"]*"' $UI
