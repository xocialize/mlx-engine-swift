// voice-shell-bench — Release measurements for AB-A-0308 / AB-A-0311, through AppVoiceClient
// (one MLXServeEngine, Kokoro + Nemotron + Qwen3.5 co-resident).
//
// Usage: voice-shell-bench --store DIR [--llm 4b|0.8b|9b] [--stt-right N] [--runs N]
//
// Grep the output for [MEM] [TTS] [LLM-TTFT] [LLM-LINE] [LLM-VERDICT] [STT] [CONTENDED].

import AppVoiceClient
import Foundation
import MLXEngineTestKit
import MLXNemotronSTT
import MLXQwenLLM
import MLXServeCore
import MLXToolKit
import Tokenizers

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let store = option("--store").map { URL(fileURLWithPath: $0) }
let runs = option("--runs").flatMap(Int.init) ?? 10
let sttRight = option("--stt-right").flatMap(Int.init) ?? 3
let llmModel: QwenModel = switch option("--llm") ?? "4b" {
case "0.8b": QwenModel(size: .b0_8, quant: .int8)
case "9b": QwenModel(size: .b9, quant: .int4)
default: QwenModel(size: .b4, quant: .int4)
}

func gb(_ b: UInt64?) -> String { String(format: "%.2f", Double(b ?? 0) / 1_073_741_824) }
func ms(_ s: Double) -> String { String(format: "%.0f", s * 1000) }
func stats(_ xs: [Double]) -> (median: Double, p90: Double, min: Double, max: Double) {
    let s = xs.sorted()
    guard !s.isEmpty else { return (0, 0, 0, 0) }
    let p90 = s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.up)) - 1)]
    return (s[s.count / 2], p90, s.first!, s.last!)
}
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

let sampler = MemorySampler(intervalMs: 20)
sampler.start(initial: HostMemory.physFootprint())

let client = await AppVoiceClient(modelStore: store)
let t0 = now()
try await client.prepare(llm: llmModel, sttRightContext: sttRight)
print("[MEM] prepared tts+stt+llm (\(llmModel.displayName), stt acs=[56,\(sttRight)]) in \(String(format: "%.1f", now() - t0))s phys=\(gb(HostMemory.physFootprint()))GB")

if let only = option("--tts-only") {
    _ = try await client.speak("Warm up.")
    let s = now()
    let l = try await client.speak(only)
    print("[TTS-ONLY] chars=\(only.count) words=\(only.split(separator: " ").count) timedWords=\(l.words.count) audio=\(String(format: "%.2f", l.duration))s wall=\(ms(now() - s))ms lastWord=\(l.words.last?.text ?? "-")")
    exit(0)
}

// MARK: TTS — a 10-word line with word timings

let line10 = "Stay close, the bridge ahead is not safe after dark."
for voice in ["af_heart", "am_adam"] {
    for _ in 0..<3 { _ = try await client.speak(line10, voice: voice) }   // warm-up
    var times: [Double] = []
    var last: AppVoiceClient.SpokenLine?
    for _ in 0..<(runs * 2) {
        let s = now()
        last = try await client.speak(line10, voice: voice)
        times.append(now() - s)
    }
    let st = stats(times)
    let l = last!
    print("[TTS] voice=\(voice) words=\(l.words.count) audio=\(String(format: "%.2f", l.duration))s sr=\(l.sampleRate) n=\(times.count) median=\(ms(st.median))ms p90=\(ms(st.p90))ms min=\(ms(st.min))ms max=\(ms(st.max))ms rtfx=\(String(format: "%.1f", l.duration / st.median))")
    print("      words: " + l.words.map { "\($0.text)@\(String(format: "%.2f", $0.start))" }.joined(separator: " "))
}

// MARK: LLM — director-shaped prompt (persona + scene + memory + the person's line)

let system = """
You are Mira, a wry, warm lighthouse keeper on a storm-battered island in a small adventure game. \
You speak in short, vivid sentences, never more than two at a time, and you never mention being an AI \
or a character. You are protective of visitors, curious about where they come from, and you tease \
them gently when they are reckless. Your knowledge: the old bridge to the north washed out last winter \
and is only half repaired; the lamp room key hangs by the stove; supply boats come on Thursdays; the \
cliffs west of the lighthouse are unstable after rain. Scene: dusk, heavy rain, the visitor has just \
come in from the north path, soaked. You are by the stove, holding a kettle. Things you remember about \
the visitor: their name is Sam; they are looking for their brother, who came to the island a week ago. \
Answer only with what Mira says aloud.
"""
let userLines = [
    "I'm going to cross the north bridge tonight, my brother might be on the other side.",
    "Have you seen anyone else come through here this week?",
    "Can I borrow the lamp room key? I want to signal the mainland.",
    "Why are you smiling at me like that?",
    "The supply boat comes tomorrow, right? Maybe he left on it.",
]
@MainActor func chat(_ u: String) -> [ChatMessage] { [ChatMessage(role: .system, content: system), ChatMessage(role: .user, content: u)] }

let verdictSchema = """
{"type":"object","properties":{"remember":{"type":["string","null"]},"action":{"type":["object","null"],"properties":{"kind":{"enum":["lookAt","goTo"]},"target":{"type":"string"}}},"gesture":{"enum":["none","nod","shake","wave","point","shrug"]},"emotion":{"enum":["neutral","happy","worried","amused","stern","sad"]},"end":{"type":"boolean"}},"required":["remember","action","gesture","emotion","end"]}
"""
@MainActor func verdictChat(_ u: String, _ said: String) -> [ChatMessage] {
    [ChatMessage(role: .system, content: system + "\n\nNow, instead of speaking, output ONE JSON object describing Mira's reaction, matching this JSON Schema exactly:\n" + verdictSchema + "\nOnly put a fact in \"remember\" if its words appear in the visitor's line; otherwise null."),
     ChatMessage(role: .user, content: "Visitor said: \(u)\nMira replied: \(said)")]
}

for i in 0..<2 { _ = try await client.respond(chat(userLines[i]), maxTokens: 60, seed: UInt64(i)) }   // warm-up
_ = try await client.verdict(verdictChat(userLines[0], "Not tonight, Sam."), schema: verdictSchema)

// mlx-qwen-llm-swift 0.7.0 returns no LLMUsage (AB-A-0217): count tokens with the model's tokenizer.
guard let repo = llmModel.weightsRepo, let repoDir = ModelStore(root: store).directory(for: repo) else { fatalError("no LLM snapshot") }
let snapshots = repoDir.appending(path: "snapshots")
let dir = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil).first) ?? repoDir
let tokenizer = try await AutoTokenizer.from(modelFolder: dir)
@MainActor func tokens(_ s: String) -> Int { tokenizer.encode(text: s, addSpecialTokens: false).count }

// Time to first token = a 1-token reply (prefill + one decode step + engine overhead).
var ttft: [Double] = []
var prefill: [Double] = []
var promptTokens = 0
for i in 0..<runs {
    let s = now()
    let r = try await client.respond(chat(userLines[i % userLines.count]), maxTokens: 1, seed: UInt64(100 + i))
    ttft.append(now() - s)
    prefill.append(r.usage?.promptSeconds ?? 0)
    promptTokens = tokens(system) + tokens(userLines[i % userLines.count])
}
let tt = stats(ttft), pf = stats(prefill)
let tt0 = tt
print("[LLM-TTFT] model=\(llmModel.displayName) promptTokens≈\(promptTokens) n=\(runs) wall(maxTokens=1) median=\(ms(tt.median))ms p90=\(ms(tt.p90))ms usagePrefill median=\(ms(pf.median))ms (0 = package reports no usage)")

var lineTimes: [Double] = []
var lineTokens: [Int] = []
var decodeTPS: [Double] = []
var lines: [String] = []
for i in 0..<runs {
    let s = now()
    let r = try await client.respond(chat(userLines[i % userLines.count]), maxTokens: 60, seed: UInt64(200 + i))
    lineTimes.append(now() - s)
    let n = r.usage?.generationTokens ?? tokens(r.text)
    lineTokens.append(n)
    if n > 1 { decodeTPS.append(Double(n - 1) / max(0.001, lineTimes.last! - tt0.median)) }
    lines.append(r.text)
}
let lt = stats(lineTimes)
let meanTok = Double(lineTokens.reduce(0, +)) / Double(max(1, lineTokens.count))
print("[LLM-LINE] n=\(runs) maxTokens=60 meanTokens=\(String(format: "%.1f", meanTok)) median=\(ms(lt.median))ms p90=\(ms(lt.p90))ms decode≈\(String(format: "%.0f", stats(decodeTPS).median))tok/s (tokens−1 over wall−TTFT)")
for (i, l) in lines.prefix(3).enumerated() { print("      line\(i): \(l.replacingOccurrences(of: "\n", with: " "))") }

// A full ~60-token reply: ask for a longer answer so the 60-token cap is what stops it.
var longTimes: [Double] = []
var longTokens: [Int] = []
for i in 0..<runs {
    var m = chat(userLines[i % userLines.count])
    m[0] = ChatMessage(role: .system, content: system + " This time, answer at length: four or five full sentences.")
    let s = now()
    let r = try await client.respond(m, maxTokens: 60, seed: UInt64(400 + i))
    longTimes.append(now() - s)
    longTokens.append(r.usage?.generationTokens ?? tokens(r.text))
}
let lg = stats(longTimes)
print("[LLM-LINE60] n=\(runs) maxTokens=60 meanTokens=\(String(format: "%.1f", Double(longTokens.reduce(0, +)) / Double(runs))) median=\(ms(lg.median))ms p90=\(ms(lg.p90))ms")

var verdictTimes: [Double] = []
var verdictTokens: [Int] = []
var parsed = 0, complete = 0
var sample = ""
for i in 0..<runs {
    let u = userLines[i % userLines.count]
    let said = lines[i % lines.count]
    let s = now()
    let r = try await client.verdict(verdictChat(u, said), schema: verdictSchema, seed: UInt64(300 + i))
    verdictTimes.append(now() - s)
    verdictTokens.append(r.usage?.generationTokens ?? tokens(r.text))
    if let obj = try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any] {
        parsed += 1
        if ["remember", "action", "gesture", "emotion", "end"].allSatisfy({ obj.keys.contains($0) }) { complete += 1 }
    }
    if i == 0 { sample = r.text }
}
let vt = stats(verdictTimes)
print("[LLM-VERDICT] n=\(runs) parsed=\(parsed)/\(runs) allKeys=\(complete)/\(runs) meanTokens=\(String(format: "%.1f", Double(verdictTokens.reduce(0, +)) / Double(runs))) median=\(ms(vt.median))ms p90=\(ms(vt.p90))ms")
print("      sample: \(sample.replacingOccurrences(of: "\n", with: " "))")

// MARK: STT — live session, fed in real time like a microphone (100 ms buffers every 100 ms)

let passage = "I came in from the north path. The bridge is half gone and the river is loud. Have you seen my brother? He came here a week ago."
let spoken = try await client.speak(passage, voice: "am_adam")
let mono16k = try AudioDecode.monoSamples(from: Audio(format: .wav, data: spoken.wav), targetRate: 16_000)

struct LiveResult { var wordLatency: [Double]; var firstPartial: Double; var finalAfterFinish: Double; var partials: Int; var text: String; var overruns: Int }

/// Word latency = wall time the k-th word first appears in a partial − wall time the k-th word's
/// audio finished being pushed (Kokoro's own word end times locate it in the clip).
@MainActor func liveSession(contend: (@Sendable () async throws -> Void)? = nil) async throws -> LiveResult {
    let handle = try await client.listen(language: "en-US")
    let rate = handle.expectedSampleRate
    let start = now()
    let collector = Task { () -> [(t: Double, words: Int, text: String, final: Bool)] in
        var seen: [(Double, Int, String, Bool)] = []
        for try await chunk in handle.updates {
            let n = chunk.text.split(whereSeparator: \.isWhitespace).count
            seen.append((now() - start, n, chunk.text, chunk.isFinal))
        }
        return seen
    }
    let contender = contend.map { work in Task { try await work() } }
    var cursor = 0, overruns = 0
    let buffer = rate / 10
    var next = start
    while cursor < mono16k.count {
        let end = min(cursor + buffer, mono16k.count)
        if handle.push(Array(mono16k[cursor..<end]), sampleRate: rate) == .overrun { overruns += 1 }
        cursor = end
        next += 0.1
        let wait = next - now()
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
    }
    let finishAt = now() - start
    handle.finish()
    let seen = try await collector.value
    try await contender?.value
    var latencies: [Double] = []
    for (k, w) in spoken.words.enumerated() {
        let audioEnd = w.start + w.duration
        if let hit = seen.first(where: { $0.words >= k + 1 && !$0.final }) {
            latencies.append(hit.t - audioEnd)
        } else if let fin = seen.first(where: { $0.final }) {
            latencies.append(fin.t - audioEnd)   // only surfaced by the final flush
        }
    }
    let finalT = seen.first(where: { $0.final })?.t ?? finishAt
    return LiveResult(wordLatency: latencies, firstPartial: seen.first(where: { !$0.final && $0.words > 0 })?.t ?? 0,
                      finalAfterFinish: finalT - finishAt, partials: seen.filter { !$0.final }.count,
                      text: seen.last?.text ?? "", overruns: overruns)
}

_ = try await liveSession()   // warm-up
var allLat: [Double] = []
var finals: [Double] = []
var text = ""
for _ in 0..<3 {
    let r = try await liveSession()
    allLat += r.wordLatency
    finals.append(r.finalAfterFinish)
    text = r.text
}
let sl = stats(allLat)
print("[STT] acs=[56,\(sttRight)] clip=\(String(format: "%.1f", spoken.duration))s words=\(spoken.words.count) sessions=3 wordLatency median=\(ms(sl.median))ms p90=\(ms(sl.p90))ms max=\(ms(sl.max))ms finalAfterFinish median=\(ms(stats(finals).median))ms")
print("      final: \(text)")

// MARK: Contended — one live session while a line, a verdict and a spoken line run

let contended = try await liveSession(contend: {
    let s = now()
    let r = try await client.respond(chat(userLines[1]), maxTokens: 60, seed: 9)
    let a = now()
    _ = try await client.verdict(verdictChat(userLines[1], r.text), schema: verdictSchema, seed: 9)
    let b = now()
    _ = try await client.speak(line10, voice: "af_heart")
    let c = now()
    print("[CONTENDED] under live STT: line=\(ms(a - s))ms verdict=\(ms(b - a))ms tts=\(ms(c - b))ms")
})
let cl = stats(contended.wordLatency)
print("[CONTENDED] stt wordLatency median=\(ms(cl.median))ms p90=\(ms(cl.p90))ms max=\(ms(cl.max))ms overruns=\(contended.overruns)")

sampler.stop()
print("[MEM] end phys=\(gb(HostMemory.physFootprint()))GB samplerPeak=\(gb(sampler.peak))GB lifetimePeak=\(gb(HostMemory.physFootprintLifetimePeak()))GB")
