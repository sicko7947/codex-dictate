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
//   CODEX_DICTATE_INPUT_DEVICE (CoreAudio input device name; disables auto selection)
//   CODEX_DICTATE_FALLBACK_INPUT_DEVICE (default: none; e.g. MacBook Pro Microphone)
//   CODEX_DICTATE_SILENCE_RMS_DB (default: -75)
//   CODEX_DICTATE_FALLBACK_MARGIN_DB (default: 9)
//   CODEX_DICTATE_MAX_RECORDING_SECONDS (default: 60)
//   CODEX_DICTATE_TRANSCRIBE_TIMEOUT (default: 180)
//   CODEX_DICTATE_KEYCODE    (default 63 = the physical fn / Globe key)
//   CODEX_DICTATE_LANG       (default auto)

import Cocoa
import ApplicationServices
import Darwin

// ---- Config -----------------------------------------------------------------

let proxyURL = ProcessInfo.processInfo.environment["CODEX_DICTATE_PROXY_URL"]
    ?? "http://127.0.0.1:8377/v1/audio/transcriptions"

let language = ProcessInfo.processInfo.environment["CODEX_DICTATE_LANG"] ?? "auto"

func cleanEnv(_ key: String) -> String? {
    guard let v = ProcessInfo.processInfo.environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
          !v.isEmpty else { return nil }
    return v
}

func doubleEnv(_ key: String, _ fallback: Double) -> Double {
    guard let v = ProcessInfo.processInfo.environment[key],
          let n = Double(v) else { return fallback }
    return n
}

let explicitInputDevice = cleanEnv("CODEX_DICTATE_INPUT_DEVICE")
let fallbackInputDevice = cleanEnv("CODEX_DICTATE_FALLBACK_INPUT_DEVICE")
let silenceRMSDB = doubleEnv("CODEX_DICTATE_SILENCE_RMS_DB", -75)
let fallbackMarginDB = doubleEnv("CODEX_DICTATE_FALLBACK_MARGIN_DB", 9)
let maxRecordingSeconds = doubleEnv("CODEX_DICTATE_MAX_RECORDING_SECONDS", 60)
let transcribeTimeout = doubleEnv("CODEX_DICTATE_TRANSCRIBE_TIMEOUT", 180)

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

let recDir = NSTemporaryDirectory()

// All record start/stop + network work runs on this serial queue so the main
// run loop (and the fn-key monitor) never blocks on sox or the HTTP round-trip.
let work = DispatchQueue(label: "codex-dictate.work")

// ---- Recording (sox) --------------------------------------------------------

struct Recording {
    let label: String
    let path: String
    let process: Process
}

struct AudioChoice {
    let label: String
    let path: String
    let wav: Data
    let rmsDB: Double
    let peakDB: Double
}

var recordings: [Recording] = []
var recording = false
var recordingID = 0

func argsForInput(label: String) -> [String] {
    if label == "default" { return ["-d"] }
    return ["-t", "coreaudio", label]
}

func sanitized(_ label: String) -> String {
    label.map { ch in
        ch.isLetter || ch.isNumber ? ch : "-"
    }.reduce("") { $0 + String($1) }
}

func startRecording() {
    work.async {
        if recording {
            FileHandle.standardError.write("[codex-dictate] already recording; stopping\n".data(using: .utf8)!)
            finishRecordingAndTranscribe()
            return
        }
        recordings.removeAll()
        recordingID += 1
        let thisRecordingID = recordingID

        let labels: [String]
        if let explicitInputDevice {
            labels = [explicitInputDevice]
        } else if let fallbackInputDevice {
            labels = ["default", fallbackInputDevice]
        } else {
            labels = ["default"]
        }

        for label in labels {
            let path = recDir + "codex-dictate-\(sanitized(label)).wav"
            try? FileManager.default.removeItem(atPath: path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: soxPath)
            p.arguments = argsForInput(label: label) + ["-q", "-r", "16000", "-c", "1", "-b", "16",
                                                        "-e", "signed-integer", path]
            do {
                try p.run()
                recordings.append(Recording(label: label, path: path, process: p))
            } catch {
                FileHandle.standardError.write(
                    "[codex-dictate] failed to start sox input=\(label) at \(soxPath): \(error)\n"
                        .data(using: .utf8)!)
            }
        }

        guard !recordings.isEmpty else {
            FileHandle.standardError.write("[codex-dictate] no recording inputs available\n".data(using: .utf8)!)
            return
        }
        recording = true
        let inputList = recordings.map(\.label).joined(separator: ", ")
        FileHandle.standardError.write("[codex-dictate] recording… inputs=\(inputList)\n".data(using: .utf8)!)

        work.asyncAfter(deadline: .now() + maxRecordingSeconds) {
            guard recording, recordingID == thisRecordingID else { return }
            FileHandle.standardError.write("[codex-dictate] max recording duration reached; stopping\n".data(using: .utf8)!)
            finishRecordingAndTranscribe()
        }
    }
}

func stopRecordingAndTranscribe() {
    work.async {
        finishRecordingAndTranscribe()
    }
}

func finishRecordingAndTranscribe() {
    guard recording else { return }
    recording = false

    let finished = recordings
    recordings.removeAll()
    for r in finished {
        r.process.interrupt()        // SIGINT lets sox finalize the WAV header
    }
    for r in finished {
        let deadline = Date().addingTimeInterval(2)
        while r.process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if r.process.isRunning {
            FileHandle.standardError.write("[codex-dictate] sox did not stop after SIGINT; terminating\n".data(using: .utf8)!)
            r.process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
        }
        if r.process.isRunning {
            FileHandle.standardError.write("[codex-dictate] sox did not terminate; killing\n".data(using: .utf8)!)
            kill(r.process.processIdentifier, SIGKILL)
        }
        r.process.waitUntilExit()
    }

    guard let choice = chooseAudio(from: finished) else {
        FileHandle.standardError.write("[codex-dictate] no/too-short audio, skipping\n".data(using: .utf8)!)
        return
    }
    FileHandle.standardError.write(
        String(format: "[codex-dictate] using input=%@ rms=%.1f dB peak=%.1f dB\n",
               choice.label, choice.rmsDB, choice.peakDB).data(using: .utf8)!)
    guard let text = transcribe(wav: choice.wav)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        FileHandle.standardError.write("[codex-dictate] empty transcript\n".data(using: .utf8)!)
        return
    }
    FileHandle.standardError.write("[codex-dictate] transcribed chars=\(text.count)\n".data(using: .utf8)!)
    DispatchQueue.main.async { paste(text) }
}

func chooseAudio(from recordings: [Recording]) -> AudioChoice? {
    let choices = recordings.compactMap { r -> AudioChoice? in
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: r.path)),
              wav.count > 1024,
              let metrics = wavMetrics(wav) else { return nil }
        return AudioChoice(label: r.label, path: r.path, wav: wav, rmsDB: metrics.rmsDB, peakDB: metrics.peakDB)
    }
    guard !choices.isEmpty else { return nil }
    guard choices.count > 1 else { return choices[0] }

    let sorted = choices.sorted { $0.rmsDB > $1.rmsDB }
    guard let defaultChoice = choices.first(where: { $0.label == "default" }),
          let best = sorted.first else { return sorted.first }

    if defaultChoice.rmsDB <= silenceRMSDB {
        return best
    }
    if best.label != "default" && best.rmsDB >= defaultChoice.rmsDB + fallbackMarginDB {
        return best
    }
    return defaultChoice
}

func wavMetrics(_ b: Data) -> (rmsDB: Double, peakDB: Double)? {
    guard b.count >= 44,
          String(data: b[0..<4], encoding: .ascii) == "RIFF",
          String(data: b[8..<12], encoding: .ascii) == "WAVE" else { return nil }

    var off = 12
    while off + 8 <= b.count {
        let id = String(data: b[off..<off + 4], encoding: .ascii) ?? ""
        let sz = Int(b[off + 4]) | Int(b[off + 5]) << 8 | Int(b[off + 6]) << 16 | Int(b[off + 7]) << 24
        let body = off + 8
        if id == "data" {
            guard sz > 1, body + sz <= b.count else { return nil }
            let samples = sz / 2
            var sumSq = 0.0
            var peak = 0.0
            for i in 0..<samples {
                let lo = UInt16(b[body + 2 * i])
                let hi = UInt16(b[body + 2 * i + 1]) << 8
                let sample = Int16(bitPattern: lo | hi)
                let amp = abs(Double(sample))
                peak = max(peak, amp)
                sumSq += amp * amp
            }
            guard samples > 0 else { return nil }
            let rms = sqrt(sumSq / Double(samples))
            func db(_ v: Double) -> Double {
                guard v > 0 else { return -120 }
                return 20 * log10(v / 32768.0)
            }
            return (db(rms), db(peak))
        }
        off = body + sz + (sz & 1)
    }
    return nil
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
    req.timeoutInterval = transcribeTimeout
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = body

    let sem = DispatchSemaphore(value: 0)
    var result: String?
    URLSession.shared.dataTask(with: req) { data, response, err in
        defer { sem.signal() }
        if let err = err {
            FileHandle.standardError.write("[codex-dictate] proxy error: \(err)\n".data(using: .utf8)!)
            return
        }
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["text"] as? String else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyPreview = preview(data)
            FileHandle.standardError.write(
                "[codex-dictate] bad proxy response status=\(status) bodyPreview=\(bodyPreview)\n"
                    .data(using: .utf8)!)
            return
        }
        result = t
    }.resume()
    sem.wait()
    return result
}

func preview(_ data: Data?, limit: Int = 500) -> String {
    guard let data, !data.isEmpty else { return "<no body>" }
    let prefix = data.prefix(limit)
    let text = String(data: prefix, encoding: .utf8) ?? "<non-utf8 body>"
    let suffix = data.count > limit ? "…<\(data.count - limit) bytes omitted>" : ""
    return text.replacingOccurrences(of: "\n", with: "\\n") + suffix
}

// ---- Paste at the cursor (clipboard + Cmd+V, then restore) ------------------

func paste(_ text: String) {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    pb.clearContents()
    pb.setString(text, forType: .string)

    guard AXIsProcessTrusted() else {
        FileHandle.standardError.write(
            "[codex-dictate] Accessibility not trusted; left transcript on clipboard\n"
                .data(using: .utf8)!)
        return
    }

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

func requestAccessibilityIfNeeded() {
    if AXIsProcessTrusted() { return }
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(opts)
    FileHandle.standardError.write(
        "[codex-dictate] Accessibility permission required for auto-paste\n"
            .data(using: .utf8)!)
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
requestAccessibilityIfNeeded()
FileHandle.standardError.write(
    "[codex-dictate] ready — hold fn to dictate (input: \(explicitInputDevice ?? "auto"), fallback: \(fallbackInputDevice ?? "none"), proxy: \(proxyURL))\n"
        .data(using: .utf8)!)
app.run()
