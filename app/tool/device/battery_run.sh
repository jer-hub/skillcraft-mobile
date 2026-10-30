#!/system/bin/sh
# Battery estimate for 10 /extract-tasks runs through the chat UI.
# Android is told the phone is on battery (simulated; it still charges), so
# batterystats attributes energy to apps. Always restored on exit.
UI=/data/local/tmp/ui.xml
UID_TAG=u0a282

trap 'dumpsys battery reset; echo "battery state reset"' EXIT INT TERM

stats() { dumpsys batterystats --charged com.skillcraft.app | grep -E "UID $UID_TAG:" | head -1; }
dump() { uiautomator dump $UI >/dev/null 2>&1; }
tap() {
  what=$1
  dump
  b=$(grep -oE "<node [^>]*$what[^>]*>" $UI | head -1 | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+')
  set -- $b
  [ -z "$4" ] && { echo "NOT FOUND: $what"; return 1; }
  input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 ))
}
wait_ui() { for i in $(seq 1 $2); do dump; grep -qE "$1" $UI && return 0; sleep 1; done; echo "TIMEOUT ui $1"; return 1; }
runs() { logcat -d -s flutter | grep -c SKILL_RUN; }
wait_run() { for i in $(seq 1 150); do [ "$(runs)" -ge "$1" ] && return 0; sleep 2; done; echo "TIMEOUT run $1"; }

input keyevent KEYCODE_WAKEUP
am force-stop com.skillcraft.app
logcat -c
dumpsys battery unplug
echo "BEFORE $(stats)"
start=$(date +%s)

am start -W -n com.skillcraft.app/.MainActivity >/dev/null
wait_ui 'class="android.widget.EditText"' 90
wait_ui 'extract-tasks' 60
ready=$(date +%s)

n=0
while IFS= read -r note; do
  [ -z "$note" ] && continue
  n=$((n + 1))
  tap 'class="android.widget.EditText"'; sleep 1
  input text "$(echo "/extract-tasks $note" | sed 's/ /%s/g')"; sleep 1
  input keyevent KEYCODE_BACK; sleep 1
  tap 'content-desc="Send"'
  wait_run $n
done <<'NOTES'
Sprint review. Jo will fix the login timeout by Thursday. Mark updates the release notes.
Budget call: Priya sends the Q3 forecast to finance by Oct 31. Leo confirms the vendor quote this week.
Kickoff: Ana drafts the project charter by Nov 5. Ben sets up the repo. Carla books the workshop room.
Please submit your timesheets by 5pm Friday. Kevin, restock the printer paper.
For the trip: book flights by Sunday and send me your dietary needs.
Tomorrow: dentist at 9, pick up laundry, finish chapter 4 of the report.
Meeting kanina: si Mark mag-aayos ng projector bago Lunes.
Retro actions: add a staging smoke test and write a runbook for rollbacks.
Client meeting: they want the revised SOW by end of month. Sam schedules a follow-up demo.
Need to renew car registration by Dec 1 and get the oil changed sometime.
NOTES

end=$(date +%s)
sleep 3
echo "AFTER $(stats)"
echo "WALL total $((end - start))s, runs $((end - ready))s for $n runs"
logcat -d -s flutter | grep SKILL_RUN | sed 's/.*SKILL_RUN/SKILL_RUN/'
dumpsys batterystats --charged com.skillcraft.app | grep -m1 'Estimated battery capacity'
