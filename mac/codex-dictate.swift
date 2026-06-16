// codex-dictate — fn-key push-to-talk dictation client for macOS.
//
// The Linux flow uses Voxtype to capture the hotkey, record the mic, and type
// the result at the cursor. macOS has no Voxtype, so this single-file Swift
// binary replaces exactly that layer and reuses the same Go proxy:
//
//   hold fn -> sox records 16 kHz mono WAV
//   release fn -> POST the WAV to the local proxy (127.0.0.1:8377)
//                 -> proxy adds the ChatGPT token + browser UA, transcribes
//                 -> paste the text at the cursor (clipboard + Cmd+V, restored)
//
// Dependencies: `sox` (brew install sox) + the codex-dictate-proxy binary.
// No Xcode project, no app bundle, no Hammerspoon/Karabiner. Build with:
//
//   swiftc -O codex-dictate.swift -o codex-dictate
//
// Permissions (System Settings -> Privacy & Security):
//   - Input Monitoring  : to observe the fn key (NSEvent global monitor)
//   - Accessibility     : to synthesize Cmd+V (CGEvent)
//   - Microphone        : sox triggers the mic prompt on first run
//
// Env overrides:
//   CODEX_DICTATE_PROXY_URL  (default http://127.0.0.1:8377/v1/audio/transcriptions)
//   CODEX_DICTATE_SOX        (default: first of /opt/homebrew/bin/sox, /usr/local/bin/sox, sox)
//   CODEX_DICTATE_KEYCODE    (default 63 = the physical fn / Globe key)
//   CODEX_DICTATE_LANG       (default auto)

import Cocoa

// ---- Config -----------------------------------------------------------------

let proxyURL = ProcessInfo.processInfo.environment["CODEX_DICTATE_PROXY_URL"]
    ?? "http://127.0.0.1:8377/v1/audio/transcriptions"

let language = ProcessInfo.processInfo.environment["CODEX_DICTATE_LANG"] ?? "auto"

let hotKeyCode: UInt16 = {
    if let v = ProcessInfo.processInfo.environment["CODEX_DICTATE_KEYCODE"],
       let n = UInt16(v) { return n }
    return 63 // kVK_Function — the physical fn / Globe key
}()

let soxPath: String = {
    if let v = ProcessInfo.processInfo.environment["CODEX_DICTATE_SOX"] { return v }
    for c in ["/opt/homebrew/bin/sox", "/usr/local/bin/sox", "/usr/bin/sox"] {
        if FileManager.default.isExecutableFile(atPath: c) { return c }
    }
    return "sox"
}()

let recPath = NSTemporaryDirectory() + "codex-dictate.wav"

// All record start/stop + network work runs on this serial queue so the main
// run loop (and the fn-key monitor) never blocks on sox or the HTTP round-trip.
let work = DispatchQueue(label: "codex-dictate.work")

// ---- Recording (sox) --------------------------------------------------------

var soxProcess: Process?
var recording = false

func startRecording() {
    work.async {
        if recording { return }
        try? FileManager.default.removeItem(atPath: recPath)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: soxPath)
        // -d = default input device; matches the 16 kHz mono PCM16 the proxy expects.
        p.arguments = ["-d", "-q", "-r", "16000", "-c", "1", "-b", "16",
                       "-e", "signed-integer", recPath]
        do {
            try p.run()
            soxProcess = p
            recording = true
            FileHandle.standardError.write("[codex-dictate] recording…\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write(
                "[codex-dictate] failed to start sox at \(soxPath): \(error)\n".data(using: .utf8)!)
        }
    }
}

func stopRecordingAndTranscribe() {
    work.async {
        guard recording, let p = soxProcess else { return }
        recording = false
        p.interrupt()        // SIGINT lets sox finalize the WAV header
        p.waitUntilExit()
        soxProcess = nil

        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: recPath)),
              wav.count > 1024 else {
            FileHandle.standardError.write("[codex-dictate] no/too-short audio, skipping\n".data(using: .utf8)!)
            return
        }
        guard let text = transcribe(wav: wav)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            FileHandle.standardError.write("[codex-dictate] empty transcript\n".data(using: .utf8)!)
            return
        }
        DispatchQueue.main.async { paste(text) }
    }
}

// ---- Transcription (POST to the local proxy) --------------------------------

func transcribe(wav: Data) -> String? {
    let boundary = "codexDictateBoundary\(ProcessInfo.processInfo.processIdentifier)"
    var body = Data()
    func add(_ s: String) { body.append(s.data(using: .utf8)!) }

    add("--\(boundary)\r\n")
    add("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
    add("Content-Type: audio/wav\r\n\r\n")
    body.append(wav)
    add("\r\n")

    add("--\(boundary)\r\n")
    add("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
    add("whisper-1\r\n")

    if language.lowercased() != "auto" {
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
        add("\(language)\r\n")
    }
    add("--\(boundary)--\r\n")

    guard let url = URL(string: proxyURL) else { return nil }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 60
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body

    let sem = DispatchSemaphore(value: 0)
    var result: String?
    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        if let err = err {
            FileHandle.standardError.write("[codex-dictate] proxy error: \(err)\n".data(using: .utf8)!)
            return
        }
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["text"] as? String else {
            let s = data.flatMap { String(data: $0, encoding: .utf8) } ?? "<no body>"
            FileHandle.standardError.write("[codex-dictate] bad proxy response: \(s)\n".data(using: .utf8)!)
            return
        }
        result = t
    }.resume()
    sem.wait()
    return result
}

// ---- Paste at the cursor (clipboard + Cmd+V, then restore) ------------------

func paste(_ text: String) {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)

    let src = CGEventSource(stateID: .combinedSessionState)
    let kVMV: CGKeyCode = 9 // 'v'
    if let down = CGEvent(keyboardEventSource: src, virtualKey: kVMV, keyDown: true),
       let up = CGEvent(keyboardEventSource: src, virtualKey: kVMV, keyDown: false) {
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // Restore the user's prior clipboard once the paste has landed.
    if let saved = saved {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pb.clearContents()
            pb.setString(saved, forType: .string)
        }
    }
}

// ---- fn-key monitor ---------------------------------------------------------

// The physical fn key emits a flagsChanged event with keyCode 63: .function is
// present on press, absent on release. (Arrow/F-keys also set .function, hence
// the keyCode guard so only the real fn key drives push-to-talk.)
let monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
    guard event.keyCode == hotKeyCode else { return }
    if event.modifierFlags.contains(.function) {
        startRecording()
    } else {
        stopRecordingAndTranscribe()
    }
}

if monitor == nil {
    FileHandle.standardError.write(
        "[codex-dictate] could not install the key monitor — grant Input Monitoring in System Settings.\n"
            .data(using: .utf8)!)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // background agent, no Dock icon
FileHandle.standardError.write(
    "[codex-dictate] ready — hold fn to dictate (proxy: \(proxyURL))\n".data(using: .utf8)!)
app.run()
