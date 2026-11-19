import AVFoundation
import HexplateCore
import UIKit

/* The end-of-rest sound, the buzz and the spoken cues (Settings → Timer alerts). The sounds are
   openGym's (ios/App/App/RestTone.swift, copied as is below): rendered once to Library/Sounds,
   where a notification can play them too. "Play even on silent" plays through the ring switch;
   either way other audio only ducks for a moment (RestAlertPlugin tone/speak). */

@MainActor
enum AlertAudio {
    private static var player: AVAudioPlayer?
    private static let speech = AVSpeechSynthesizer()
    private static let quiet = SpeechEnd()

    /// The sound ids and their names (lib/rest-sounds.js REST_SOUND_LABEL).
    static let sounds: [(id: String, name: LocalizedStringResource)] = [
        ("chime", "Chime (louder)"), ("classic", "Classic beeps"), ("bell", "Bell"), ("beep", "Beep-beep"), ("whistle", "Whistle"), ("soft", "Soft"),
    ]

    private static func session(onSilent: Bool, voice: Bool = false) {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(onSilent ? .playback : .ambient, mode: voice ? .voicePrompt : .default,
                           options: onSilent ? [.mixWithOthers, .duckOthers] : [.duckOthers])
        try? s.setActive(true)
    }

    /// Music back up once nothing is playing or being said.
    fileprivate static func release() {
        guard player?.isPlaying != true, !speech.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    static func tone(_ kind: String, onSilent: Bool) {
        guard let url = RestTone.soundFile(kind), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        session(onSilent: onSilent)
        player = p
        p.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + p.duration + 0.1) { release() }
    }

    /// Says `text` in the app's language (Cantonese for Chinese). `flush` cuts off what is still being said.
    static func say(_ text: String, rate: Double, onSilent: Bool, flush: Bool = false) {
        guard !text.isEmpty else { return }
        session(onSilent: onSilent, voice: true)
        if flush && speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
        speech.delegate = quiet
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: Theme.language == "en" ? "en-US" : "zh-HK") ?? AVSpeechSynthesisVoice(language: "zh-TW")
        u.rate = max(AVSpeechUtteranceMinimumSpeechRate, min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(rate)))
        speech.speak(u)
    }

    /// Slow, normal or fast (lib/speech.js SPEECH_RATES).
    nonisolated static func rate(_ s: [String: JSONValue]) -> Double {
        switch s["speechRate"]?.stringValue { case "slow": 0.8; case "fast": 1.25; default: 1 }
    }

    /// The buzz: a strong one, felt in a pocket.
    static func buzz() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

private final class SpeechEnd: NSObject, AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { MainActor.assumeIsolated { AlertAudio.release() } }
    }
}

/// openGym ios/App/App/RestTone.swift, unchanged.
enum RestTone {
    static let rate = 22050
    /** Silence after the tone, as on Android: Bluetooth earbuds still hold the last note. */
    static let tailSec = 0.6
    static let kinds = ["chime", "classic", "bell", "beep", "whistle", "soft"]

    private static let bright: [Double] = [1, 0.6, 0.35, 0.2]
    private static let bellTimbre: [Double] = [1, 0.25, 0.5, 0.1, 0.3]
    private static let sine: [Double] = [1]

    // {freq, dur, when} or {freq, dur, when, glideTo}
    private static let chime: [[Double]] = [[1319, 0.16, 0], [988, 0.16, 0.22], [1319, 0.5, 0.44]]
    private static let bellNotes: [[Double]] = [[1319, 0.9, 0], [1047, 1.3, 0.4]]
    private static let beepNotes: [[Double]] = [[1760, 0.08, 0], [1760, 0.08, 0.13], [1760, 0.08, 0.4], [1760, 0.08, 0.53]]
    private static let whistleNotes: [[Double]] = [[1300, 0.16, 0, 2100], [1500, 0.42, 0.22, 2500]]
    private static let softNotes: [[Double]] = [[659, 0.4, 0], [784, 0.4, 0.2], [988, 0.8, 0.4]]

    /** A name it does not know plays the chime, as everywhere else. */
    static func normalised(_ kind: String?) -> String {
        guard let k = kind, kinds.contains(k) else { return "chime" }
        return k
    }

    static func render(_ kind: String) -> [Int16] {
        switch normalised(kind) {
        case "classic": return withTail(renderBeeps())
        case "bell": return withTail(renderNotes(bellNotes, peak: 0.55, hold: 0, harmonics: bellTimbre))
        case "beep": return withTail(renderNotes(beepNotes, peak: 0.8, hold: 0.8, harmonics: bright))
        case "whistle": return withTail(renderNotes(whistleNotes, peak: 0.7, hold: 0.55, harmonics: sine))
        case "soft": return withTail(renderNotes(softNotes, peak: 0.3, hold: 0, harmonics: sine))
        default: return withTail(renderNotes(chime, peak: 0.9, hold: 0.6, harmonics: bright))
        }
    }

    static func renderNotes(_ notes: [[Double]], peak: Double, hold: Double, harmonics: [Double]) -> [Int16] {
        let end = notes.map { $0[2] + $0[1] }.max() ?? 0
        var mix = [Double](repeating: 0, count: Int((end * Double(rate)).rounded(.up)))
        let norm = wavePeak(harmonics)
        for n in notes {
            let freq = n[0], dur = n[1], to = n.count > 3 ? n[3] : n[0]
            let start = Int((n[2] * Double(rate)).rounded())
            let len = Int(dur * Double(rate))
            var s = 0
            while s < len && start + s < mix.count {
                let t = Double(s) / Double(rate)
                let cycles = freq * t + (to - freq) * t * t / (2 * dur)
                var wave = 0.0
                for (k, h) in harmonics.enumerated() { wave += h * sin(2 * Double.pi * cycles * Double(k + 1)) }
                mix[start + s] += wave / norm * gain(t, dur, peak, hold)
                s += 1
            }
        }
        return mix.map { Int16(max(-32767, min(32767, ($0 * 32767).rounded()))) }
    }

    static func gain(_ t: Double, _ dur: Double, _ peak: Double, _ hold: Double) -> Double {
        let floor = 0.001, attack = 0.02, holdEnd = max(attack, dur * hold)
        if t < 0 { return 0 }
        if t < attack { return floor * pow(peak / floor, t / attack) }
        if t < holdEnd { return peak }
        if t < dur { return peak * pow(floor / peak, (t - holdEnd) / (dur - holdEnd)) }
        return 0
    }

    private static func wavePeak(_ harmonics: [Double]) -> Double {
        var top = 0.0
        for i in 0..<4096 {
            let x = 2 * Double.pi * Double(i) / 4096
            var v = 0.0
            for (k, h) in harmonics.enumerated() { v += h * sin(Double(k + 1) * x) }
            top = max(top, abs(v))
        }
        return top
    }

    /** The classic beeps (880, 880, 1320), flat at 0.85 of full scale as on Android. */
    static func renderBeeps() -> [Int16] {
        let freq: [Double] = [880, 880, 1320], dur = [0.15, 0.15, 0.40], gap = [0.10, 0.10, 0]
        var out: [Int16] = []
        let fade = max(1, rate / 200)
        for i in 0..<freq.count {
            let n = Int(Double(rate) * dur[i])
            for s in 0..<n {
                var env = 1.0
                if s < fade { env = Double(s) / Double(fade) } else if s > n - fade { env = Double(n - s) / Double(fade) }
                let wave = sin(2 * Double.pi * freq[i] * Double(s) / Double(rate))
                out.append(Int16(max(-32767, min(32767, wave * env * 0.85 * 32767))))
            }
            out.append(contentsOf: [Int16](repeating: 0, count: Int(Double(rate) * gap[i])))
        }
        return out
    }

    static func withTail(_ tone: [Int16]) -> [Int16] {
        tone + [Int16](repeating: 0, count: Int(tailSec * Double(rate)))
    }

    static func wav(_ samples: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let bytes = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(bytes)
        for s in samples { var x = s.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        return d
    }

    /**
     * "rest-chime-v1.wav" etc., written to Library/Sounds the first time it is asked for. The
     * version goes up with any change to the sounds above, so a phone never keeps an old file.
     */
    static func soundName(_ kind: String) -> String {
        "rest-\(normalised(kind))-v1.wav"
    }

    static func soundFile(_ kind: String) -> URL? {
        let k = normalised(kind)
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = lib.appendingPathComponent("Sounds", isDirectory: true)
        let url = dir.appendingPathComponent(soundName(k))
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try wav(render(k)).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

/// What the spoken cues say when a rest starts (lib/spoken-cues.js restStartText): the next set,
/// "Set 3, 80 kilos, 8 reps", with the exercise's name first when it is another exercise's.
@MainActor
enum Cues {
    static func restStart(_ model: AppModel, after at: Int) -> String {
        let entries = model.activeEntries
        guard let next = next(entries, after: at) else { return "" }
        let e = entries[next.idx], sets = e["sets"]?.arrayValue ?? [], row = sets[next.i]
        let s = row.object ?? [:], target = e["target"]?.object ?? [:], id = e["id"]?.stringValue ?? ""
        var probe = target; probe["id"] = e["id"]
        let mode = RoutineOps.mode(probe, catalog: model.catalog)
        let warm = Session.isWarmup(row)
        let number = sets[...next.i].filter { Session.isWarmup($0) == warm }.count
        var parts = [warm ? tr("Warm-up") : tr("Set {0}", number)]
        let w = s["w"]?.numberValue ?? 0
        let kilos = { (w: Double) in model.settings.unit == "lb" ? WrappedCards.plural("{0} pound", "{0} pounds", w, Format.number(w)) : WrappedCards.plural("{0} kilo", "{0} kilos", w, Format.number(w)) }
        switch mode {
        case "cardio":
            if let m = s["min"]?.numberValue, m > 0 { parts.append(WrappedCards.plural("{0} minute", "{0} minutes", m, Format.number(m))) }
        case "time":
            if w > 0 { parts.append(kilos(w)) }
            if let sec = s["sec"]?.numberValue ?? target["sec"]?.numberValue, sec > 0 { parts.append(WrappedCards.plural("{0} second", "{0} seconds", sec, Int(sec))) }
        default:
            if w > 0 { parts.append(kilos(w)) }
            if Session.isSideSet(row) {
                if let r = s["sides"]?.object?["L"]?.object?["r"]?.numberValue, r > 0 { parts.append(WrappedCards.plural("{0} rep per side", "{0} reps per side", r, Int(r))) }
            } else if let r = s["r"]?.numberValue, r > 0 {
                parts.append(WrappedCards.plural("{0} rep", "{0} reps", r, Int(r)))
            }
        }
        let line = parts.joined(separator: ", ")
        return next.idx != at ? "\(model.catalog[id]?.displayName ?? id). \(line)" : line
    }

    /// The set after a rest started by entry `at` (nextSetAfter): round a superset, else the same
    /// exercise, else the next one down with a set left.
    static func next(_ entries: [[String: JSONValue]], after at: Int) -> (idx: Int, i: Int)? {
        guard entries.indices.contains(at) else { return nil }
        func firstOpen(_ idx: Int) -> (idx: Int, i: Int)? {
            (entries[idx]["sets"]?.arrayValue ?? []).firstIndex { !SetTrend.isDone($0) }.map { (idx, $0) }
        }
        let unit = ActiveEdit.units(entries.map { .object($0) }).first { $0.contains(at) } ?? [at]
        if unit.count > 1, let k = unit.firstIndex(of: at) {
            for j in 1...unit.count { if let hit = firstOpen(unit[(k + j) % unit.count]) { return hit } }
        } else if let hit = firstOpen(at) { return hit }
        for j in 1..<max(1, entries.count) { if let hit = firstOpen((at + j) % entries.count) { return hit } }
        return nil
    }
}
