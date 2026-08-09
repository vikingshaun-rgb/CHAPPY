# Chappy build 130 — Phase 5 steps 2, 3, 4 and 4.5

Twelve Swift files, two scripts, this document. **No uploads needed from you.**
I recovered your `LiveAIManager.swift`, `TurboMetaApp.swift` and
`project.pbxproj` from your own GitHub repo, and the patch script edits your
real copies in place.

---

## ⚠️ One new Info.plist key — do this first

Step 3 reads your photo library. You have `NSPhotoLibraryAddUsageDescription`
(writing) from build 49, but not the **read** key. Without it the app is
terminated by TCC the first time ingest runs — not a declined prompt, a crash.

```
/usr/libexec/PlistBuddy -c "Add :NSPhotoLibraryUsageDescription string 'Chappy reads photos you take with the glasses capture button so they become searchable memories with their real time and place.'" CameraAccess/Info.plist
```

Everything else in the plist you already did this morning.

---

## The five commands

### 1. Get the files in

```
cd ~/Desktop/chappy && Z=$(for z in ~/Downloads/*.zip; do unzip -l "$z" 2>/dev/null | grep -q "ChappyPulse.swift" && echo "$z"; done | tail -1) && echo "using $Z" && rm -rf /tmp/b130 && unzip -o "$Z" -d /tmp/b130 && cp /tmp/b130/Chappy*.swift CameraAccess/Managers/ && cp /tmp/b130/patch-b130.py /tmp/b130/verify-b130.sh . && ls CameraAccess/Managers/Chappy*.swift | wc -l
```

Should print **12**.

### 2. Patch

```
python3 patch-b130.py
```

### 3. The one thing the script can't do

Presenting the browser is a UI decision, so it's yours. In
`TurboMetaHomeView.swift`, wherever the Records tab or main view lives:

```swift
@State private var showMemory = false
```

and on that view:

```swift
.sheet(isPresented: $showMemory) { ChappyMemoryBrowser() }
.onReceive(NotificationCenter.default.publisher(for: .chappyOpenMemoryBrowser)) { _ in
    showMemory = true
}
```

Add a button that sets `showMemory = true` and you have it on screen as well as
by voice. Verify stays red until this is in.

### 4. Verify

```
bash verify-b130.sh
```

**Section 1b will fail on purpose** — `EventSheet` and `eventLead` still aren't
in your source. Everything else must be green.

### 5. Archive and export

```
cd ~/Desktop/chappy && set -o pipefail && xcodebuild clean -project CameraAccess.xcodeproj -scheme CameraAccess | tail -3
```

```
cd ~/Desktop/chappy && set -o pipefail && xcodebuild archive -project CameraAccess.xcodeproj -scheme CameraAccess -configuration Release -archivePath /tmp/chappy-b130.xcarchive CODE_SIGN_IDENTITY="iPhone Distribution" DEVELOPMENT_TEAM=FMM6R5B4AM | tail -40
```

```
ls -la /tmp/chappy-b130.xcarchive/Products/Applications/ && echo "--- ARCHIVE OK ---"
```

```
cd ~/Desktop/chappy && set -o pipefail && xcodebuild -exportArchive -archivePath /tmp/chappy-b130.xcarchive -exportPath /tmp/chappy-b130-ipa -exportOptionsPlist ExportOptions.plist | tail -10
```

```
ls -la /tmp/chappy-b130-ipa/
```

### 6. Commit and push

```
cd ~/Desktop/chappy && git add -A && git commit -m "Build 130: Phase 5 steps 2-4.5 — intensity dial and Pulse ambient memory, glasses photo ingest, relevance engine, memory browser, Codex profile" && git push origin main
```

---

## What each new file does

| File | Phase 5 step | |
|---|---|---|
| `ChappyPulse.swift` | 2 | Off/Light/Standard/Dense/Deep dial, Pulse ambient capture, live cost |
| `ChappyPhotoIngest.swift` | 3 | Glasses capture-button photos → captioned memories, app closed |
| `ChappyRelevance.swift` | 4a | Volunteers a remembered place when you arrive near it |
| `ChappyMemoryBrowser.swift` | 4b | Browse, search, map, and navigate back to any memory |
| `ChappyMemoryKeeper.swift` | 4.5 | The Codex — curated durable facts injected into every prompt |

---

## New voice commands

| Say | Does |
|---|---|
| "Chappy, memory standard" (or light / dense / deep) | sets the dial |
| "Chappy, remember everything for the next hour" | temporary boost, reverts itself |
| "Chappy, stop remembering" | Pulse off, immediately |
| "Chappy, memory status" | tier, frames kept, cents spent today |
| "Chappy, show my memory" | opens the browser |
| "Chappy, catch up on my photos" | runs photo ingest now |
| "Chappy, stop telling me about places" | relevance engine off |

---

## Defaults, and why

**Pulse is OFF. The relevance engine is OFF.** Both are opt-in.

Microsoft shipped Recall on by default in 2024 and spent eighteen months
walking it back. By July 2026 Ray-Ban Meta glasses had earned the nickname
"pervert glasses", DEF CON had banned them outright, and Instagram was removing
accounts over covert recording. Ambient capture that arrives switched on is how
a good feature becomes a deleted app.

The glasses' own capture indicator is never suppressed, and one command kills
Pulse instantly.

---

## Cost

| | |
|---|---|
| Pulse at Standard, a full day | ~1c |
| Pulse at Deep, a full day | ~1.5c |
| Photo ingest, ~40 photos/day | ~0.2c |
| Codex consolidation, 1/day | ~0.7c |
| Proactive briefs, 8/day | ~5c |
| Conversation sessions, ~20/day | ~10c |
| **Per month, all in** | **under $5** |

Captioning goes to Gemini Flash-Lite, not Claude — about $0.04 per thousand
images against roughly $0.50 for Haiku, because Haiku tokenises images by area
rather than capping resolution. At this frequency that difference is the
feature being affordable or not.

---

## Two free gates before any spend

Before Pulse wakes the camera it asks whether you've moved. If `ContextEngine`
says you've been still, it doesn't wake it at all — a stationary wearer is
where camera-session overhead hurts most and the frame is worth least.

Then, before it sends anything, Vision's `VNGenerateImageFeaturePrintRequest`
compares the frame against the last one actually captioned, on-device and free.
Thirty frames of the same road cost nothing.

---

## The measurement I could not make for you

Meta publishes **nothing** about what it costs to open and close a DAT camera
session. The Gen 2 runs on a 154 mAh cell where merely disabling voice-wake
moves real runtime from ~3–4 hours to ~5–8, and there's a known SDK issue where
sessions failed in a `starting → stopping → stopped` loop — which implies a real
handshake, not a cheap one.

So Pulse takes several frames per wake rather than one, to amortise it. Whether
that's the right trade is a number only you can get:

1. Run a day at **Light** (15 min). Note the glasses battery at start and end.
2. Run a day at **Dense** (5 min). Same.
3. If Dense costs more than about 10% extra, raise `framesPerWake` and widen the
   intervals — same coverage, fewer handshakes.

`framesPerWake` and every interval are at the top of `ChappyPulse.swift`,
deliberately, because this is the one thing the research couldn't settle.

---

## Phase 5 after this build

| Step | State |
|---|---|
| 1 — MemoryStore + query_memory | done (JSONL rather than SQLite; `recall` tool) |
| 2 — Intensity Dial + Pulse | **this build** |
| 3 — Photo ingest + Dreaming | **this build** (`dreamIfDue` already existed) |
| 4 — Relevance + Browser | **this build** |
| 4.5 — Codex | **this build** |
| 5 — Guards, ledger, journal map | not started |

Step 5 is what's left: scam guard, allergy shield driven by the Codex, a
multi-currency trip spend tracker, and the clustered "everywhere I've been" map.
The allergy shield is now a small job, because the Codex it needs finally exists.

Still carried: `EventSheet` and the Lists tab, the Phase 4 certification walk,
and rotating those burned API keys.
