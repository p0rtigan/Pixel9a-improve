#!/usr/bin/env bash
# Pixel 9a slowdown diagnostics.
# Requirements: adb (Android platform-tools) and USB debugging enabled
# (Settings > About phone > tap "Build number" 7x, then
#  Settings > System > Developer options > USB debugging).
# Usage: ./diagnose.sh            -> prints a report and saves it to report-<timestamp>.txt
set -uo pipefail

command -v adb >/dev/null || { echo "adb not found. Install Android platform-tools first."; exit 1; }
adb get-state >/dev/null 2>&1 || { echo "No device found. Plug in the phone and accept the USB debugging prompt."; exit 1; }

OUT="report-$(date +%Y%m%d-%H%M%S).txt"
sh() { adb shell "$@" 2>/dev/null | tr -d '\r'; }
section() { printf '\n===== %s =====\n' "$1"; }
warn() { printf '  !! %s\n' "$1"; }

{
section "Device"
echo "Model:   $(sh getprop ro.product.model)"
echo "Android: $(sh getprop ro.build.version.release)  (build $(sh getprop ro.build.id), patch $(sh getprop ro.build.version.security_patch))"
echo "Uptime:  $(sh uptime)"
up_days=$(sh cat /proc/uptime | awk '{print int($1/86400)}')
[ "${up_days:-0}" -ge 7 ] && warn "Phone hasn't restarted in ${up_days} days. A restart often helps."

section "Storage (a nearly full /data slows down the whole phone)"
sh df -h /data
used_pct=$(sh df /data | awk 'NR==2{gsub("%","",$5); print $5}')
if [ -n "${used_pct:-}" ] && [ "$used_pct" -ge 85 ]; then
  warn "Storage is ${used_pct}% full. Above ~85-90%, the flash storage gets much slower. Free up space."
fi
echo "--- largest app/data categories ---"
sh dumpsys diskstats | grep -E 'App Size|App Data Size|App Cache Size|Photos Size|Videos Size|Audio Size|Downloads Size|System Size|Other Size' | head -20

section "Memory"
sh cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree'
avail_kb=$(sh cat /proc/meminfo | awk '/MemAvailable/{print $2}')
[ -n "${avail_kb:-}" ] && [ "$avail_kb" -lt 1000000 ] && warn "Less than 1 GB RAM available. Too many background apps or a memory hog (see below)."
echo "--- top memory users (PSS) ---"
sh dumpsys meminfo | sed -n '/Total PSS by process/,/^$/p' | head -15
echo "--- low-memory kills recorded ---"
sh dumpsys activity lmk 2>/dev/null | head -5

section "Thermals (Tensor G4 slows itself down when it gets hot)"
sh dumpsys thermalservice | grep -E 'Thermal Status|IsStatusOverride|mValue|Temperature\{' | head -25
status=$(sh dumpsys thermalservice | awk -F': ' '/Thermal Status/{print $2; exit}')
[ -n "${status:-}" ] && [ "$status" -ge 1 ] 2>/dev/null && warn "Thermal status is ${status} (0 = none). The phone is throttling right now."

section "Battery"
sh dumpsys battery | grep -E 'level|health|temperature|status|Charge counter|cycle'
echo "(temperature is in tenths of °C)"
psave=$(sh settings get global low_power)
[ "$psave" = "1" ] && warn "Battery Saver is ON. It limits CPU speed and background work."

section "CPU: top processes right now"
sh top -b -n 1 -m 15 -o PID,USER,%CPU,%MEM,NAME
echo "--- CPU load averaged over recent minutes ---"
sh dumpsys cpuinfo | head -20

section "Animation & developer settings"
for k in window_animation_scale transition_animation_scale animator_duration_scale; do
  echo "$k = $(sh settings get global $k)"
done
echo "Background process limit: $(sh settings get global background_process_limit 2>/dev/null)"

section "Apps"
echo "Third-party apps installed: $(sh pm list packages -3 | wc -l)"
echo "--- apps that wake the phone most / heavy background users (batterystats summary) ---"
sh dumpsys batterystats --charged | grep -E 'Uid u0a[0-9]+:' | sort -t'(' -k1 -rn | head -10
echo "--- recent app-not-responding (ANR) / crash entries ---"
sh dumpsys dropbox --print 2>/dev/null | grep -E '^[0-9-]+ [0-9:.]+ (data_app_anr|data_app_crash|system_app_anr)' | tail -15

section "Pending system update"
sh dumpsys activity service com.google.android.gms/.update.SystemUpdateService 2>/dev/null | grep -iE 'status|state' | head -5
echo "(also check Settings > System > Software updates. Updates downloading or optimizing apps in the background cause temporary slowness)"

section "Done"
echo "Look for lines marked '!!' above. They point to the most likely causes."
} | tee "$OUT"

echo
echo "Report saved to $OUT"
