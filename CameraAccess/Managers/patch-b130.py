#!/usr/bin/env python3
"""
Chappy build 130 — Phase 5 steps 2, 3, 4 and 4.5.

Registers all twelve Chappy files in project.pbxproj, applies the source
patches, and wires the new modules into launch and the location stream.
Idempotent: run twice and the second run reports what was already done.
Backs up every file it touches first.
"""
import os, re, sys, shutil, hashlib, datetime

LAM = "CameraAccess/Managers/LiveAIManager.swift"
PBX = "CameraAccess.xcodeproj/project.pbxproj"
APP = next((c for c in ["CameraAccess/TurboMetaApp.swift",
                        "CameraAccess/CameraAccessApp.swift",
                        "CameraAccess/AppDelegate.swift"] if os.path.exists(c)), None)

for f in (LAM, PBX):
    if not os.path.exists(f):
        sys.exit(f"ABORT: {f} not found. Run from the repo root (~/Desktop/chappy).")
if APP is None:
    sys.exit("ABORT: no App file found under CameraAccess/")

FILES = ["ChappyRouterHook", "ChappyNavMode", "ChappyConversation", "ChappyProactive",
         "ChappyLists", "ChappyTimers", "ChappyDataBridge", "ChappyMemoryKeeper",
         "ChappyPulse", "ChappyPhotoIngest", "ChappyRelevance", "ChappyMemoryBrowser"]

stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
bak = f"../chappy-backup-{stamp}"
os.makedirs(bak, exist_ok=True)
for f in (LAM, APP, PBX):
    shutil.copy2(f, os.path.join(bak, os.path.basename(f)))
print(f"backup -> {os.path.abspath(bak)}\n")

done, skip = [], []

# ── LiveAIManager: hook, debounce openers, relevance on every fix ───────
p = open(LAM, encoding="utf-8").read()

A = "        if await ChappyRouterHook.intercept(c) { return }"
if A in p:
    skip.append("A  router hook")
else:
    anc = "    private func route(_ c: String) async {\n"
    if p.count(anc) != 1: sys.exit(f"ABORT: route() anchor x{p.count(anc)}")
    p = p.replace(anc, anc +
        "        // BUILD 129: everything new lives behind one entry point.\n"
        + A + "\n\n", 1)
    done.append("A  router hook")

if '"take me to", "take us to", "drive me to"' in p:
    skip.append("B  destination openers")
else:
    anc = '        "let\'s talk", "lets talk", "take me home", "get me home", "go home",\n'
    if p.count(anc) != 1: sys.exit(f"ABORT: extendableCommands anchor x{p.count(anc)}")
    p = p.replace(anc, anc +
        '        // BUILD 129: destination openers get the grace "navigate" already has.\n'
        '        "take me to", "take us to", "drive me to", "drive us to",\n'
        '        "walk me to", "walk us to", "get me to", "get us to",\n'
        '        "navigate to", "navigate me to", "directions to", "route to",\n'
        '        "closest", "nearest",\n', 1)
    done.append("B  destination openers")

# D: relevance rides the existing location stream — no new CLLocationManager.
D = "ChappyRelevance.shared.locationUpdated(loc)"
if D in p:
    skip.append("D  relevance on location updates")
else:
    anc = "        Task { @MainActor in NavEngine.shared.updateLocation(loc) }"
    if p.count(anc) != 1: sys.exit(f"ABORT: location anchor x{p.count(anc)}")
    p = p.replace(anc, anc +
        "\n        // BUILD 130: memory volunteers on arrival. Rides the fixes that\n"
        "        // already exist rather than starting a second location manager.\n"
        "        Task { @MainActor in " + D + " }", 1)
    done.append("D  relevance on location updates")
open(LAM, "w", encoding="utf-8").write(p)

# ── App file: launch wiring ─────────────────────────────────────────────
a = open(APP, encoding="utf-8").read()

if "ChappyProactive.shared.registerBackgroundTask()" in a:
    skip.append("C1 registerBackgroundTask")
else:
    m = re.search(r'(\n\s*init\(\)\s*\{\n)', a)
    if not m: sys.exit("ABORT: no init() in " + APP)
    ind = re.search(r'([ \t]*)init\(\)', m.group(1)).group(1) + "  "
    a = a[:m.end(1)] + (
        f"{ind}// BGTaskScheduler REQUIRES registration before launch finishes.\n"
        f"{ind}ChappyProactive.shared.registerBackgroundTask()\n\n") + a[m.end(1):]
    done.append("C1 registerBackgroundTask")

if "ChappyPulse.shared.start()" in a:
    skip.append("C2 launch calls")
else:
    m = re.search(r'\n(\s*)(MainAppView\([^\n]*\)|ContentView\(\))\n', a)
    if not m: sys.exit("ABORT: no MainAppView/ContentView anchor in " + APP)
    ind = m.group(1) + "  "
    a = a[:m.end(0) - 1] + (
        f"\n{ind}.onAppear {{\n"
        f"{ind}  ChappyProactive.shared.start()            // 8 scheduled check-ins\n"
        f"{ind}  ChappyLists.shared.startAtLaunch()        // re-arm shop geofences\n"
        f"{ind}  ChappyTimers.shared.restoreAfterLaunch()  // re-arm spoken timers\n"
        f"{ind}  ChappyPulse.shared.start()                // ambient memory dial\n"
        f"{ind}  ChappyPhotoIngest.shared.start()          // wi-fi monitor for ingest\n"
        f"{ind}}}") + a[m.end(0) - 1:]
    done.append("C2 launch calls (5)")
open(APP, "w", encoding="utf-8").write(a)

# ── Home view: point the EXISTING memory plumbing at the new browser ────
# TurboMetaHomeView already has showMemory, a fullScreenCover and a
# .chappyOpenMemory voice hook. Nothing new is needed — only the view behind
# them changes, so this is one line and trivially reversible.
THV = next((p for p in ["CameraAccess/Views/TurboMetaHomeView.swift",
                        "CameraAccess/TurboMetaHomeView.swift"] if os.path.exists(p)), None)
if THV is None:
    skip.append("E  home view not found — swap MemoryView() by hand")
else:
    shutil.copy2(THV, os.path.join(bak, os.path.basename(THV)))
    v = open(THV, encoding="utf-8").read()
    if "ChappyMemoryBrowser()" in v:
        skip.append("E  browser already presented")
    else:
        anc = "$showMemory) {\n                MemoryView()"
        if v.count(anc) == 1:
            v = v.replace(anc, "$showMemory) {\n                // BUILD 130: the new browser — map view, detail cards with\n                // navigate-back, and an ambient filter so Pulse frames don't\n                // bury the photos he actually chose to take.\n                ChappyMemoryBrowser()", 1)
            open(THV, "w", encoding="utf-8").write(v)
            done.append("E  showMemory now presents ChappyMemoryBrowser")
        else:
            skip.append(f"E  MemoryView() anchor x{v.count(anc)} — swap by hand")

# ── pbxproj ─────────────────────────────────────────────────────────────
x = open(PBX, encoding="utf-8").read()
missing = [f for f in FILES if f"{f}.swift */ = {{isa = PBXFileReference" not in x]
if not missing:
    skip.append(f"PBX all {len(FILES)} files")
else:
    uid = lambda s: hashlib.md5(("chappy130-" + s).encode()).hexdigest()[:24].upper()
    bl, rl, cl, sl = [], [], [], []
    for f in missing:
        b, r = uid(f + "-build"), uid(f + "-ref")
        bl.append(f'\t\t{b} /* {f}.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {r} /* {f}.swift */; }};')
        rl.append(f'\t\t{r} /* {f}.swift */ = {{isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.swift; name = {f}.swift; path = Managers/{f}.swift; sourceTree = "<group>"; }};')
        cl.append(f'\t\t\t\t{r} /* {f}.swift */,')
        sl.append(f'\t\t\t\t{b} /* {f}.swift in Sources */,')
    x = x.replace("/* Begin PBXBuildFile section */", "/* Begin PBXBuildFile section */\n" + "\n".join(bl), 1)
    x = x.replace("/* Begin PBXFileReference section */", "/* Begin PBXFileReference section */\n" + "\n".join(rl), 1)
    m = re.search(r'([ \t]*[0-9A-F]{24} /\* LiveAIManager\.swift \*/,\n)', x)
    if not m: sys.exit("ABORT: Managers group anchor not found")
    x = x[:m.end(1)] + "\n".join(cl) + "\n" + x[m.end(1):]
    m = re.search(r'([ \t]*[0-9A-F]{24} /\* LiveAIManager\.swift in Sources \*/,\n)', x)
    if not m: sys.exit("ABORT: Sources phase anchor not found")
    x = x[:m.end(1)] + "\n".join(sl) + "\n" + x[m.end(1):]
    open(PBX, "w", encoding="utf-8").write(x)
    done.append(f"PBX registered {len(missing)}: " + ", ".join(missing))

print("APPLIED:")
for t in done: print("  +", t)
if skip:
    print("SKIPPED (already done):")
    for t in skip: print("  =", t)

print("""
STILL TO DO BY HAND — one line, because it is a UI decision:
  present the memory browser from your Records/home view:

      @State private var showMemory = false
      ...
      .sheet(isPresented: $showMemory) { ChappyMemoryBrowser() }
      .onReceive(NotificationCenter.default.publisher(for: .chappyOpenMemoryBrowser)) { _ in
          showMemory = true
      }

Then:  bash verify-b130.sh
""")
