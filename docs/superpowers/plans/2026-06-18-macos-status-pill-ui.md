# macOS Status Pill UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small, bottom-center, black-and-white macOS status pill that appears while dictation is active and gives subtle visual feedback during recording and transcription.

**Architecture:** Keep the app as a single Swift binary with no app bundle and no new runtime dependencies. Add an AppKit `NSPanel` overlay owned by the existing accessory app, plus a lightweight custom `NSView` that renders text and animated dots/bars. Drive it from the existing recording/transcription lifecycle by dispatching UI updates onto the main queue.

**Tech Stack:** Swift, AppKit/Cocoa, `NSPanel`, `NSView`, `Timer`, existing `swiftc` build, existing launchd agents.

---

## File Structure

- Modify `mac/codex-dictate.swift`
  - Add `PillState`, `StatusPillView`, and `StatusPillController`.
  - Add `showPill(_:)`, `hidePillSoon()`, and lifecycle calls from recording/transcription/paste paths.
  - Keep all AppKit UI work on the main thread.
- Modify `mac/test-client-config.sh`
  - Add static checks for the new status pill symbols and lifecycle state calls.
- Modify `mac/README.md`
  - Document the UI behavior and the environment variable to disable it.
- Optional modify `README.md`
  - Mention the macOS status pill in the macOS quick start if the docs update needs a top-level pointer.

## Design Requirements

- The overlay is a small black pill near the bottom center of the active screen.
- It is black/white only, compact, and non-interactive.
- It appears while recording starts, remains visible while transcribing, and hides shortly after paste/failure.
- It has subtle animation while recording: three white vertical bars or dots with low-amplitude pulsing.
- It must not require extra permissions beyond the current app permissions.
- It must not steal focus or activate the app.
- It must not interfere with clipboard/paste behavior.
- It must degrade cleanly if the window cannot be shown: dictation should still work.
- It should be possible to disable with `CODEX_DICTATE_SHOW_UI=0`.
- It should use status-bar level, ignore mouse events, and avoid Space/cycle
  surprises with `.stationary` and `.ignoresCycle` collection behavior.

---

### Task 1: Add Static Test Coverage First

**Files:**
- Modify: `mac/test-client-config.sh`

- [ ] **Step 1: Write the failing static checks**

Add these lines after the existing `src` checks:

```bash
grep -q 'CODEX_DICTATE_SHOW_UI' "$src"
grep -q 'enum PillState' "$src"
grep -q 'final class StatusPillView' "$src"
grep -q 'final class StatusPillController' "$src"
grep -q 'showPill(.recording)' "$src"
grep -q 'showPill(.transcribing)' "$src"
grep -q 'hidePillSoon' "$src"
grep -q 'NSPanel' "$src"
grep -q 'NSScreen' "$src"
grep -q 'level = .statusBar' "$src"
grep -q 'ignoresMouseEvents = true' "$src"
grep -q 'collectionBehavior' "$src"
grep -q '.stationary' "$src"
grep -q '.ignoresCycle' "$src"
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash mac/test-client-config.sh
```

Expected: exit code `1`, because `CODEX_DICTATE_SHOW_UI`, `PillState`, and `StatusPillController` do not exist yet.

- [ ] **Step 3: Commit only if working in an isolated branch**

Do not commit on `main` until the implementation passes. This repo currently has no test framework, so this static test is the lightweight regression gate.

---

### Task 2: Add the AppKit Pill Types

**Files:**
- Modify: `mac/codex-dictate.swift`

- [ ] **Step 1: Add UI config near the existing config section**

Add this after `let transcribeTimeout = ...`:

```swift
let showStatusUI = ProcessInfo.processInfo.environment["CODEX_DICTATE_SHOW_UI"] != "0"
```

Update the env override comment at the top:

```swift
//   CODEX_DICTATE_SHOW_UI (default: 1; set 0 to disable the bottom status pill)
```

- [ ] **Step 2: Add `PillState` and `StatusPillView` before the recording section**

Insert this block after `let work = DispatchQueue(label: "codex-dictate.work")`:

```swift
// ---- Status pill UI ---------------------------------------------------------

enum PillState {
    case recording
    case transcribing
    case ready
    case error

    var label: String {
        switch self {
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .ready: return "Done"
        case .error: return "Not pasted"
        }
    }
}

final class StatusPillView: NSView {
    private var state: PillState = .recording
    private var phase = 0
    private var timer: Timer?

    override var isFlipped: Bool { true }

    func setState(_ newState: PillState) {
        state = newState
        needsDisplay = true
        if newState == .recording {
            startAnimation()
        } else {
            stopAnimation()
        }
    }

    private func startAnimation() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase = (self.phase + 1) % 3
            self.needsDisplay = true
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopAnimation() {
        timer?.invalidate()
        timer = nil
        phase = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds
        NSColor.black.withAlphaComponent(0.86).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()

        drawIndicator(in: bounds)
        drawLabel(in: bounds)
    }

    private func drawIndicator(in bounds: NSRect) {
        let baseX: CGFloat = 15
        let baseY: CGFloat = 12
        let widths: [CGFloat] = [3, 3, 3]
        let heights: [CGFloat] = [8, 13, 10]
        for i in 0..<3 {
            let active = state == .recording && i == phase
            let height = active ? heights[i] + 5 : heights[i]
            let rect = NSRect(x: baseX + CGFloat(i) * 6, y: baseY + (18 - height) / 2, width: widths[i], height: height)
            NSColor.white.withAlphaComponent(active ? 1.0 : 0.62).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawLabel(in bounds: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92)
        ]
        let text = NSString(string: state.label)
        let size = text.size(withAttributes: attrs)
        let rect = NSRect(x: 42, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        text.draw(in: rect, withAttributes: attrs)
    }
}
```

- [ ] **Step 3: Add `StatusPillController` below `StatusPillView`**

Add this block immediately after `StatusPillView`:

```swift
final class StatusPillController {
    private let window: NSPanel
    private let pillView: StatusPillView
    private var hideWorkItem: DispatchWorkItem?

    init() {
        pillView = StatusPillView(frame: NSRect(x: 0, y: 0, width: 146, height: 36))
        window = NSPanel(
            contentRect: pillView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = pillView
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func show(_ state: PillState) {
        hideWorkItem?.cancel()
        pillView.setState(state)
        position()
        window.orderFrontRegardless()
    }

    func hideSoon(after delay: TimeInterval = 0.75) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.window.orderOut(nil)
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func position() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 28
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
```

- [ ] **Step 4: Add global helpers**

Add this below `StatusPillController`:

```swift
var statusPill: StatusPillController?

func statusPillController() -> StatusPillController? {
    precondition(Thread.isMainThread)
    guard showStatusUI else { return nil }
    if statusPill == nil {
        statusPill = StatusPillController()
    }
    return statusPill
}

func showPill(_ state: PillState) {
    DispatchQueue.main.async {
        statusPillController()?.show(state)
    }
}

func hidePillSoon(after delay: TimeInterval = 0.75) {
    DispatchQueue.main.async {
        statusPillController()?.hideSoon(after: delay)
    }
}
```

- [ ] **Step 5: Run parse check**

Run:

```bash
swiftc -parse mac/codex-dictate.swift
```

Expected: exit code `0`.

---

### Task 3: Wire UI Into Recording and Transcription Lifecycle

**Files:**
- Modify: `mac/codex-dictate.swift`

- [ ] **Step 1: Show recording pill when recording starts**

In `startRecording()`, after the line:

```swift
FileHandle.standardError.write("[codex-dictate] recording… inputs=\(inputList)\n".data(using: .utf8)!)
```

add:

```swift
showPill(.recording)
```

- [ ] **Step 2: Show transcribing pill after recording stops**

In `finishRecordingAndTranscribe()`, immediately after:

```swift
recording = false
```

add:

```swift
showPill(.transcribing)
```

- [ ] **Step 3: Hide pill when no usable audio exists**

In the `guard let choice = chooseAudio(from: finished) else` block, before `return`, add:

```swift
hidePillSoon(after: 0.9)
```

- [ ] **Step 4: Hide pill when transcription returns empty**

In the `guard let text = transcribe(wav: choice.wav)?... else` block, before `return`, add:

```swift
showPill(.error)
hidePillSoon(after: 1.2)
```

- [ ] **Step 5: Hide pill after paste or clipboard fallback**

At the end of `paste(_:)`, after scheduling clipboard restore, add:

```swift
hidePillSoon()
```

Inside the `AXIsProcessTrusted()` failure branch in `paste(_:)`, before `return`, add:

```swift
showPill(.error)
hidePillSoon(after: 1.5)
```

- [ ] **Step 6: Hide pill when there are no recording inputs**

In `startRecording()`, inside:

```swift
guard !recordings.isEmpty else {
```

before `return`, add:

```swift
showPill(.error)
hidePillSoon(after: 1.2)
```

- [ ] **Step 7: Run parse and static checks**

Run:

```bash
swiftc -parse mac/codex-dictate.swift
bash mac/test-client-config.sh
```

Expected: both exit code `0`.

---

### Task 4: Document the Status Pill

**Files:**
- Modify: `mac/README.md`

- [ ] **Step 1: Add the environment variable row**

In the tuning table, add:

```markdown
| `CODEX_DICTATE_SHOW_UI` | `1` | show the small bottom-center recording/transcribing status pill; set `0` to disable |
```

- [ ] **Step 2: Add a note about behavior**

In `## Notes / limits`, add:

```markdown
- **Status pill**: while recording or transcribing, the client shows a compact
  black-and-white pill near the bottom center of the screen. It is non-interactive,
  does not take focus, and can be disabled with `CODEX_DICTATE_SHOW_UI=0`.
```

- [ ] **Step 3: Add static README checks**

In `mac/test-client-config.sh`, add:

```bash
grep -q 'CODEX_DICTATE_SHOW_UI' "$readme"
grep -q 'bottom-center' "$readme"
grep -q 'Status pill' "$readme"
```

- [ ] **Step 4: Run docs/static check**

Run:

```bash
bash mac/test-client-config.sh
```

Expected: exit code `0`.

---

### Task 5: Build, Install, Runtime Verify

**Files:**
- Build output only: `~/.local/bin/codex-dictate`
- LaunchAgent output only: `~/Library/LaunchAgents/io.codexdictate.client.plist`

- [ ] **Step 1: Build**

Run:

```bash
./mac/build.sh
```

Expected:

```text
==> building client -> /Users/sicko/.local/bin/codex-dictate
==> signing client ...
```

Ad-hoc signing is acceptable on this machine, but note it can invalidate macOS Input Monitoring and Accessibility grants after each rebuild.

- [ ] **Step 2: Install/reload agents**

Run:

```bash
./mac/install-agents.sh
```

Expected:

```text
wrote /Users/sicko/Library/LaunchAgents/io.codexdictate.proxy.plist
wrote /Users/sicko/Library/LaunchAgents/io.codexdictate.client.plist
Loaded.
```

- [ ] **Step 3: Verify services**

Run:

```bash
curl -sS http://127.0.0.1:8377/
launchctl print gui/$(id -u)/io.codexdictate.client | rg 'state =|CODEX_DICTATE'
ps aux | rg '[s]ox .*codex-dictate|[c]odex-dictate'
```

Expected:

```text
{"status":"ok","upstream":"https://chatgpt.com/backend-api/transcribe"}
state = running
CODEX_DICTATE_FALLBACK_INPUT_DEVICE => MacBook Pro Microphone
```

The `ps` command should show `codex-dictate` and `codex-dictate-proxy`, and no lingering `sox` process unless the user is actively holding the hotkey.

- [ ] **Step 4: Manual visual verification**

Run:

```bash
tail -n 80 -f ~/Library/Logs/io.codexdictate.client.log
```

Then hold `fn` for 2-4 seconds and speak. Expected:

- A small black pill appears near the bottom center.
- Its white indicator animates while holding `fn`.
- The pill changes to transcribing state after release.
- It disappears after paste or clipboard fallback.
- Logs include `recording… inputs=...`, `using input=...`, and either `transcribed chars=...` or a concise error.

- [ ] **Step 5: Verify disable switch**

Temporarily edit `~/Library/LaunchAgents/io.codexdictate.client.plist` or run the client manually with:

```bash
CODEX_DICTATE_SHOW_UI=0 ~/.local/bin/codex-dictate
```

Expected: dictation behavior remains, but no status pill appears.

---

## Self-Review

- Spec coverage: The plan covers the user’s requested bottom-screen black pill, minimal black/white style, recording animation, transcribing visibility, disable switch, and verification.
- Panel behavior coverage: The plan verifies `.statusBar` level,
  `ignoresMouseEvents = true`, `NSScreen` positioning, `.stationary`, and
  `.ignoresCycle`.
- Placeholder scan: No TBD/TODO placeholders remain.
- Type consistency: `PillState`, `StatusPillView`, `StatusPillController`, `showPill`, and `hidePillSoon` names are consistent across tasks and static tests.
