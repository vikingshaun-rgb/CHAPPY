# Chappy build 129 — complete go-list

Everything below is in order. Run one command per paste.

---

## 0. Read this first

This package contains **seven new files** and **three small patches**. It does
**not** contain `LiveAIManager.swift`, `TurboMetaHomeView.swift`,
`GeminiLiveService.swift` or `TTSService.swift`, and that is deliberate.

Builds 125–128 — the Live AI crash fix, the voice cache, snap confirmation, the
reminders redesign, the calendar work — all live inside those four files, in
**your** repo. My workspace copies are stale snapshots from before build 125.
Shipping them would compile cleanly and silently delete four builds of work.
Step 3 below verifies yours are intact before you archive.

---

## 1. Files you need to upload to me

I cannot do the remaining work blind. Two files and one screenshot:

| What | Why I need it |
|---|---|
| `CameraAccess/Managers/LiveAIManager.swift` | to apply patches A and B against the real file instead of you hand-editing, and to verify `ChappyDataBridge` against the actual `ChappyReminders` / `ChappyCalendar` API |
| `CameraAccess/Views/TurboMetaHomeView.swift` | to scope the Reminders GUI against the mockup, and to add the Lists tab |
| Screenshot of the Timeline tab | to compare what's on screen to what the mockup promised |

Until I have those, `ChappyDataBridge.swift` is my best guess at six method
signatures. It is the only file that names those types, so if it doesn't
compile the error will point at it and nowhere else.

---

## 2. Unpack

```
cd ~/Desktop/chappy
```

```
unzip -o ~/Downloads/CHAPPY-B129.zip -d /tmp/b129 && ls -la /tmp/b129
```

```
cp /tmp/b129/Chappy{RouterHook,NavMode,Conversation,Proactive,Lists,Timers,DataBridge}.swift CameraAccess/Managers/ && ls -la CameraAccess/Managers/Chappy*.swift
```

If your project uses a file-list rather than folder references, add all seven
to the CameraAccess target in Xcode before building.

---

## 3. Patch A — the hook (one line)

Open `CameraAccess/Managers/LiveAIManager.swift`, find the only
`private func route(_ c: String) async {` and insert one line directly beneath:

```swift
    private func route(_ c: String) async {
        if await ChappyRouterHook.intercept(c) { return }
```

Nothing else in that function changes. If the hook doesn't recognise a command
it returns `false` and your existing router runs exactly as before.

Confirm it landed:

```
grep -n "ChappyRouterHook.intercept" CameraAccess/Managers/LiveAIManager.swift
```

---

## 4. Patch B — stop cutting off long destinations

Same file. Find:

```swift
        let debounce = wordCount <= 3 ? 0.6 : (wordCount <= 6 ? 0.85 : 1.1)
```

Replace with:

```swift
        // Place names run long — "the IGA at Sunset Road near Kuta" is still
        // being said when a 1.1s debounce has already routed half of it.
        let lower = snapshot.lowercased()
        let isNav = ["take me to", "take us to", "drive me to", "drive us to",
                     "walk me to", "walk us to", "navigate to", "navigate me",
                     "get me to", "get us to", "directions to", "route to",
                     "closest", "nearest"].contains { lower.contains($0) }
        let debounce: Double
        if wordCount <= 3      { debounce = 0.6 }
        else if isNav          { debounce = wordCount <= 8 ? 1.3 : 1.7 }
        else if wordCount <= 6 { debounce = 0.85 }
        else                   { debounce = 1.1 }
```

---

## 5. Patch C — app launch

In your `@main` App file:

```swift
@main
struct CameraAccessApp: App {
    init() {
        ChappyProactive.shared.registerBackgroundTask()      // must be pre-launch
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    ChappyProactive.shared.start()
                    ChappyLists.shared.startAtLaunch()
                    ChappyTimers.shared.restoreAfterLaunch()
                }
        }
    }
}
```

`registerBackgroundTask()` **must** run before launching finishes — that's a
`BGTaskScheduler` requirement, not a style preference. With an `AppDelegate`,
it goes in `didFinishLaunchingWithOptions` before `return true`.

`ChappyLists.startAtLaunch()` is not optional. Without it nothing constructs
`ChappyLists` at startup, the location delegate is never set, and every shop
geofence is silently dead after any relaunch.

---

## 6. Info.plist

### This one terminates the app if you skip it

Requesting Reminders access with no usage string is killed by TCC — not a
catchable error, the process just dies. Same class as the missing
`NSPhotoLibraryAddUsageDescription` in build 49.

```
/usr/libexec/PlistBuddy -c "Add :NSRemindersFullAccessUsageDescription string 'Chappy keeps your shopping and errand lists in Reminders so they sync across your devices and can be shared.'" CameraAccess/Info.plist
```

```
/usr/libexec/PlistBuddy -c "Add :NSRemindersUsageDescription string 'Chappy keeps your shopping and errand lists in Reminders so they sync across your devices and can be shared.'" CameraAccess/Info.plist
```

### Background task identifier

```
/usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers array" CameraAccess/Info.plist
```

```
/usr/libexec/PlistBuddy -c "Add :BGTaskSchedulerPermittedIdentifiers:0 string com.smartview.glassai.proactive" CameraAccess/Info.plist
```

### Two extra background modes

```
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes: string fetch" CameraAccess/Info.plist
```

```
/usr/libexec/PlistBuddy -c "Add :UIBackgroundModes: string processing" CameraAccess/Info.plist
```

If any `Add` fails with "Entry Already Exists", that key is already there —
carry on.

### Already present from build 49, don't re-add

`NSPhotoLibraryAddUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`,
`NSSpeechRecognitionUsageDescription`, `NSMicrophoneUsageDescription`,
`NSMotionUsageDescription`, `LSApplicationQueriesSchemes`.

---

## 7. Housekeeping — the duplicate file

```
git rm CameraAccess/Models/OmniRealtimeViewModel.swift
```

Still pinned to `gemini-2.0-flash-exp` and shadowing the live one in
`ViewModels/`.

---

## 8. Verify before you archive

```
bash /tmp/b129/verify-b129.sh
```

It checks 40-odd things: that builds 125–128 markers are still in your tree,
that all seven new files landed, that all four patch points exist, that every
plist key is present, and that the duplicate is gone. It exits non-zero if
anything is missing, so it will stop you archiving a broken tree.

Everything must be green before step 9.

---

## 9. Archive and export

```
cd ~/Desktop/chappy
```

```
set -o pipefail && xcodebuild clean -project CameraAccess.xcodeproj -scheme CameraAccess | tail -3
```

```
set -o pipefail && xcodebuild archive -project CameraAccess.xcodeproj -scheme CameraAccess -configuration Release -archivePath /tmp/chappy-b129.xcarchive CODE_SIGN_IDENTITY="iPhone Distribution" DEVELOPMENT_TEAM=FMM6R5B4AM | tail -30
```

```
set -o pipefail && xcodebuild -exportArchive -archivePath /tmp/chappy-b129.xcarchive -exportPath /tmp/chappy-b129-ipa -exportOptionsPlist ExportOptions.plist | tail -10
```

```
ls -la /tmp/chappy-b129-ipa/
```

```
xcrun altool --upload-app -f /tmp/chappy-b129-ipa/CameraAccess.ipa -t ios --apiKey YOUR_KEY_ID --apiIssuer YOUR_ISSUER_ID
```

---

## 10. Push to GitHub

```
cd ~/Desktop/chappy && git add CameraAccess/Managers/Chappy*.swift CameraAccess/Info.plist
```

```
git add -u && git status --short
```

```
git commit -m "Build 129: distance-aware navigation, on-demand conversation sessions, 8x daily proactive check-ins, iCloud-backed lists with shop geofencing, named timers"
```

```
git push origin main
```

---

## 11. First-run, on the phone

In this order, or things will look broken:

1. Launch. Allow **notifications** — without it the check-ins have nowhere to land.
2. Say *"Chappy, add milk to the corner store list"*. Allow **Reminders**.
3. When it asks for **Always** location, say yes. "While Using" means the shop
   nudge never fires with the phone pocketed.
4. Open Apple Reminders — there should be a list called "Corner store" with
   milk in it. That's your proof EventKit is wired.
5. Say *"Chappy, set a timer for two minutes"*. Lock the phone. It must fire.
6. Say *"Chappy, what's my brief"* — expect "No brief yet today" until a slot runs.

To force a check-in without waiting, temporarily add to any button:

```swift
Task { await ChappyProactive.shared.runNow() }
```

---

## 12. What to watch in the console

| Prefix | Means |
|---|---|
| `🗺️ [NavMode]` | which mode was chosen and why, with the measured distance |
| `💬 [Conversation]` | HTTP errors with the full response body |
| `🔔 [Proactive]` | which slot ran, and why a brief was or wasn't delivered |
| `📍 [Lists]` | how many shops are being monitored, and cooldowns |
| `⏱️ [Timers]` | scheduled and restored counts |

If a proactive pass says `nothing notable — staying quiet`, that is correct
behaviour, not a failure.
