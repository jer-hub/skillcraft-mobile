#!/system/bin/sh
# Starts /capture-tasks in the installed SkillCraft, turns the screen off,
# and reports how the run fares in the background: whether RunService is in
# the foreground, the app's cpuset over time, kills, and the run time.
#
#   adb push tool/device/background_run.sh /data/local/tmp/ && adb shell sh /data/local/tmp/background_run.sh
UI=/data/local/tmp/ui.xml
NOTE='/extract-tasks Weekly sync. Ana sends the revised budget to finance by Friday. Ben books the venue for the December workshop. Carla reviews the vendor contract before Nov 15. Dev renews the SSL certificate this week.'

dump() { for i in 1 2 3 4 5; do rm -f $UI; uiautomator dump $UI >/dev/null 2>&1; grep -q "<node" $UI && return; sleep 1; done; }
bounds() { grep -oE "<node [^>]*$1[^>]*>" $UI | head -1 | grep -oE 'bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | grep -oE '[0-9]+'; }
wait_tap() {
  for i in $(seq 1 $2); do
    input keyevent KEYCODE_WAKEUP; dump; b=$(bounds "$1")
    if [ -n "$b" ]; then set -- $b; input tap $(( ($1 + $3) / 2 )) $(( ($2 + $4) / 2 )); return 0; fi
    sleep 1
  done
  echo "NOT FOUND: $1"; exit 1
}

input keyevent KEYCODE_WAKEUP
am force-stop com.skillcraft.app
logcat -c; logcat -c -b events
am start -W -n com.skillcraft.app/.MainActivity >/dev/null
wait_tap 'class="android.widget.EditText"' 60; sleep 1
input text "$(echo "$NOTE" | sed 's/ /%s/g')"; sleep 1
input keyevent KEYCODE_BACK; sleep 1
dump; grep -q com.skillcraft.app $UI || { echo "left the app"; exit 1; }
wait_tap 'content-desc="Send"' 10
start=$(date +%s)
sleep 5
pid=$(pidof com.skillcraft.app)
echo "service: $(dumpsys activity services com.skillcraft.app | grep -m1 -oE 'isForeground=[a-z]+')"
echo "cpuset on screen: $(cat /proc/$pid/cpuset)"
input keyevent KEYCODE_SLEEP
echo "screen off at +$(( $(date +%s) - start ))s"

while true; do
  sleep 20
  t=$(( $(date +%s) - start ))
  # kill -0 fails for the shell user on another app's pid, so ask pidof.
  if [ "$(pidof com.skillcraft.app)" != "$pid" ]; then echo "+${t}s PROCESS GONE"; break; fi
  echo "+${t}s cpuset $(cat /proc/$pid/cpuset) screen $(dumpsys power | grep -o 'mWakefulness=[A-Za-z]*')"
  logcat -d -s flutter | grep -q SKILL_RUN && break
  [ $t -gt 420 ] && { echo "TIMEOUT"; break; }
done

logcat -d -s flutter | grep SKILL_RUN | sed 's/.*SKILL_RUN/SKILL_RUN/'
logcat -d -b events | grep -E 'am_kill.*skillcraft' | tail -3
# Only the live "Wake Locks:" table; the rest of dumpsys power is history.
echo "wake lock held now: $(dumpsys power | sed -n '/^Wake Locks: size=/,/^$/p' | grep -c 'SkillCraft:run')"
echo "service after run: $(dumpsys activity services com.skillcraft.app | grep -c 'ServiceRecord.*RunService')"
input keyevent KEYCODE_WAKEUP
