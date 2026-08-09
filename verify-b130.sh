#!/bin/bash
# Chappy build 130 — pre-archive verification.
# Only ever inspects .swift / .plist / .pbxproj, never itself or any document,
# and checks each patch in the specific file it belongs in.
FAIL=0
pass(){ printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail(){ printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=1; }
hr(){ printf "\n\033[1m%s\033[0m\n" "$1"; }

SRC=$(find CameraAccess -name "*.swift" -not -name "Chappy*.swift")
LAM=$(find CameraAccess -name "LiveAIManager.swift" | head -1)
APP=$(find CameraAccess -maxdepth 2 \( -name "*App.swift" -o -name "AppDelegate.swift" \) | head -1)
PLIST=$(find CameraAccess -name "Info.plist" | head -1)
PBX=$(find . -name "project.pbxproj" | head -1)
M=CameraAccess/Managers

hr "1. Existing builds still intact"
for m in VoiceCache warmPhrases SnapFeedback renderShutter saveToCameraRoll \
         ChappyReminders ChappyCalendar ChappyMemory agendaLine briefText \
         RemindersView weekStrip looksUnfinished dreamIfDue; do
  grep -qs -- "$m" $SRC && pass "$m" || fail "$m MISSING from source"
done

hr "1b. Build 128 gap (expected red until rebuilt)"
for m in EventSheet eventLead; do
  grep -qs -- "$m" $SRC && pass "$m" || fail "$m absent — build 128 never landed"
done

hr "1c. Live AI crash guard"
G=$(find CameraAccess -name "GeminiLiveService.swift" | head -1)
grep -qs "sampleRate > 0" "$G" && pass "sampleRate guard" || fail "sampleRate guard MISSING"
grep -qs "deinit" "$G" && pass "deinit present" || fail "deinit MISSING"

hr "2. All twelve Chappy files on disk"
for f in ChappyRouterHook ChappyNavMode ChappyConversation ChappyProactive \
         ChappyLists ChappyTimers ChappyDataBridge ChappyMemoryKeeper \
         ChappyPulse ChappyPhotoIngest ChappyRelevance ChappyMemoryBrowser; do
  [ -f "$M/$f.swift" ] && pass "$f.swift" || fail "$f.swift NOT FOUND in $M"
done

hr "3. Source patches"
grep -qs "^        if await ChappyRouterHook.intercept(c) { return }" "$LAM" \
  && pass "A  router hook in route()" || fail "A  NOT APPLIED — nothing new will run"
grep -qs '"take me to", "take us to", "drive me to"' "$LAM" \
  && pass "B  destination openers" || fail "B  NOT APPLIED"
grep -qs "ChappyRelevance.shared.locationUpdated" "$LAM" \
  && pass "D  relevance on location fixes" || fail "D  NOT APPLIED — memory never volunteers"
for c in "ChappyProactive.shared.registerBackgroundTask()" "ChappyProactive.shared.start()" \
         "ChappyLists.shared.startAtLaunch()" "ChappyTimers.shared.restoreAfterLaunch()" \
         "ChappyPulse.shared.start()" "ChappyPhotoIngest.shared.start()"; do
  grep -qs -- "$c" "$APP" && pass "C  $c" || fail "C  $c MISSING from $APP"
done

hr "4. project.pbxproj registration"
for f in ChappyRouterHook ChappyNavMode ChappyConversation ChappyProactive \
         ChappyLists ChappyTimers ChappyDataBridge ChappyMemoryKeeper \
         ChappyPulse ChappyPhotoIngest ChappyRelevance ChappyMemoryBrowser; do
  b=$(grep -c "$f.swift in Sources \*/ = {isa = PBXBuildFile" "$PBX")
  r=$(grep -c "$f.swift \*/ = {isa = PBXFileReference" "$PBX")
  s=$(grep -c "/\* $f.swift in Sources \*/,$" "$PBX")
  [ "$b$r$s" = "111" ] && pass "$f registered" \
    || fail "$f NOT registered (build=$b ref=$r sources=$s) — will not compile"
done

hr "5. Phase 5 wiring — present but connected?"
grep -qs "ChappyMemoryKeeper.shared.profileBlock()" "$M/ChappyConversation.swift" \
  && pass "Codex → conversation prompt" || fail "Codex NOT injected into conversation"
grep -qs "ChappyMemoryKeeper.shared.nudgeIfDue()" "$M/ChappyProactive.swift" \
  && pass "Codex nudge → proactive pass" || fail "Codex nudge NOT hooked"
grep -qs "ChappyMemoryKeeper.shared.profileBlock()" "$M/ChappyProactive.swift" \
  && pass "Codex → brief prompt" || fail "Codex NOT injected into brief"
grep -qs "ChappyPhotoIngest.shared.ingestIfDue()" "$M/ChappyProactive.swift" \
  && pass "photo ingest → proactive pass" || fail "photo ingest NEVER RUNS"
grep -qs "handleMemoryCommand" "$M/ChappyRouterHook.swift" \
  && pass "dial/boost/browse voice commands" || fail "memory voice commands MISSING"
grep -qs "chappyOpenMemory" "$M/ChappyRouterHook.swift" \
  && pass "voice opens memory (reuses existing notification)" || fail "memory voice hook MISSING"
if grep -rqs "ChappyMemoryBrowser()" CameraAccess --include="*.swift" \
   --exclude="ChappyMemoryBrowser.swift"; then
  pass "browser presented behind showMemory"
else
  fail "browser NOT presented — patch E did not apply; swap MemoryView() by hand"
fi

hr "6. Info.plist"
for k in NSRemindersFullAccessUsageDescription NSRemindersUsageDescription \
         NSLocationAlwaysAndWhenInUseUsageDescription NSPhotoLibraryAddUsageDescription \
         NSPhotoLibraryUsageDescription NSCameraUsageDescription \
         BGTaskSchedulerPermittedIdentifiers UIBackgroundModes; do
  /usr/libexec/PlistBuddy -c "Print :$k" "$PLIST" >/dev/null 2>&1 && pass "$k" || fail "$k MISSING"
done
/usr/libexec/PlistBuddy -c "Print :BGTaskSchedulerPermittedIdentifiers" "$PLIST" 2>/dev/null \
  | grep -q "com.smartview.glassai.proactive" && pass "  ↳ proactive identifier" || fail "  ↳ proactive identifier MISSING"
for m in fetch processing audio location; do
  /usr/libexec/PlistBuddy -c "Print :UIBackgroundModes" "$PLIST" 2>/dev/null | grep -q "$m" \
    && pass "  ↳ mode: $m" || fail "  ↳ mode '$m' MISSING"
done

hr "7. Housekeeping"
[ -f CameraAccess/Models/OmniRealtimeViewModel.swift ] \
  && fail "duplicate OmniRealtimeViewModel — git rm CameraAccess/Models/OmniRealtimeViewModel.swift" \
  || pass "no duplicate OmniRealtimeViewModel"
ls $M/*.md $M/*.sh >/dev/null 2>&1 \
  && fail "docs/scripts inside $M — move them to the repo root" \
  || pass "no stray docs in the source folder"

echo ""
[ $FAIL -eq 0 ] && printf "\033[32m\033[1mALL CHECKS PASSED — safe to archive.\033[0m\n\n" \
                || printf "\033[31m\033[1mFIX THE ✗ LINES ABOVE BEFORE ARCHIVING.\033[0m\n\n"
exit $FAIL
