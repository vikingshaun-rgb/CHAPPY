#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────
# Chappy build 129 — pre-archive verification
#
# Run from the repo root:   bash verify-b129.sh
#
# Checks, in order:
#   1. builds 125-128 are still present in YOUR tree (nothing was reverted)
#   2. the seven new build-129 files are in place
#   3. the three source patches were applied
#   4. every required Info.plist key exists
#   5. the duplicate OmniRealtimeViewModel is gone
#
# Exits non-zero if anything is missing, so it can gate the archive.
# ─────────────────────────────────────────────────────────────────────────

FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=1; }

hr() { printf "\n\033[1m%s\033[0m\n" "$1"; }

hr "1. Builds 125-128 still present (nothing reverted)"
for m in VoiceCache warmPhrases SnapFeedback renderShutter saveToCameraRoll \
         ChappyReminders ChappyCalendar eventLead agendaLine RemindersView \
         EventSheet weekStrip briefText; do
  if grep -rqs "$m" CameraAccess/; then pass "$m"; else fail "$m  — build 125-128 marker MISSING"; fi
done

hr "1b. Live AI crash guard (the SIGABRT on installTap)"
if grep -qs "sampleRate > 0" CameraAccess/Services/GeminiLiveService.swift; then
  pass "sampleRate guard"
else fail "sampleRate guard MISSING — the crash fix is not in this tree"; fi
if grep -qs "deinit" CameraAccess/Services/GeminiLiveService.swift; then
  pass "deinit present (observer cleanup)"
else fail "deinit MISSING — stale instances will fight for the mic"; fi

hr "2. Build 129 new files"
for f in ChappyRouterHook ChappyNavMode ChappyConversation ChappyProactive \
         ChappyLists ChappyTimers ChappyDataBridge; do
  if find CameraAccess -name "$f.swift" | grep -q .; then pass "$f.swift"
  else fail "$f.swift NOT FOUND in CameraAccess/"; fi
done

hr "3. Source patches applied"
if grep -rqs "ChappyRouterHook.intercept" CameraAccess/; then
  pass "Patch A — hook line in route()"
else fail "Patch A MISSING — nothing in build 129 will run"; fi

if grep -rqs "isNav ? (wordCount <= 8" CameraAccess/ || grep -rqs "else if isNav" CameraAccess/; then
  pass "Patch B — nav debounce stretch"
else fail "Patch B MISSING — long destinations will still be cut off"; fi

if grep -rqs "ChappyProactive.shared.registerBackgroundTask" CameraAccess/; then
  pass "Patch C1 — registerBackgroundTask at launch"
else fail "Patch C1 MISSING — scheduled check-ins will never fire"; fi

if grep -rqs "ChappyProactive.shared.start" CameraAccess/; then
  pass "Patch C2 — ChappyProactive.start()"
else fail "Patch C2 MISSING"; fi

if grep -rqs "ChappyLists.shared.startAtLaunch" CameraAccess/; then
  pass "Patch C3 — ChappyLists.startAtLaunch()"
else fail "Patch C3 MISSING — shop nudges will be dead after any relaunch"; fi

if grep -rqs "ChappyTimers.shared.restoreAfterLaunch" CameraAccess/; then
  pass "Patch C4 — ChappyTimers.restoreAfterLaunch()"
else fail "Patch C4 MISSING — timers won't speak after a relaunch"; fi

hr "4. Info.plist keys"
PLIST=$(find . -name "Info.plist" -path "*CameraAccess*" | head -1)
if [ -z "$PLIST" ]; then
  fail "Info.plist not found"
else
  echo "  (using $PLIST)"
  for k in NSRemindersFullAccessUsageDescription NSRemindersUsageDescription \
           NSLocationAlwaysAndWhenInUseUsageDescription \
           NSPhotoLibraryAddUsageDescription \
           BGTaskSchedulerPermittedIdentifiers UIBackgroundModes; do
    if /usr/libexec/PlistBuddy -c "Print :$k" "$PLIST" >/dev/null 2>&1; then pass "$k"
    else fail "$k MISSING"; fi
  done
  if /usr/libexec/PlistBuddy -c "Print :BGTaskSchedulerPermittedIdentifiers" "$PLIST" 2>/dev/null \
     | grep -q "com.smartview.glassai.proactive"; then
    pass "  ↳ contains com.smartview.glassai.proactive"
  else fail "  ↳ com.smartview.glassai.proactive NOT in the identifier array"; fi
  for m in fetch processing audio location; do
    if /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$PLIST" 2>/dev/null | grep -q "$m"; then
      pass "  ↳ background mode: $m"
    else fail "  ↳ background mode '$m' MISSING"; fi
  done
fi

hr "5. Housekeeping"
if [ -f CameraAccess/Models/OmniRealtimeViewModel.swift ]; then
  fail "duplicate CameraAccess/Models/OmniRealtimeViewModel.swift still present — run: git rm CameraAccess/Models/OmniRealtimeViewModel.swift"
else
  pass "no duplicate OmniRealtimeViewModel"
fi

echo ""
if [ $FAIL -eq 0 ]; then
  printf "\033[32m\033[1mALL CHECKS PASSED — safe to archive.\033[0m\n\n"
else
  printf "\033[31m\033[1mSOMETHING IS MISSING — fix the ✗ lines above before archiving.\033[0m\n\n"
fi
exit $FAIL
