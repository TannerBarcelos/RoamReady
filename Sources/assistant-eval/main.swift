import Foundation
import NaturalLanguage
import AssistantEval
import CampCore
import DocumentSearch
import AssistantModel
#if canImport(FoundationModels)
import FoundationModels
#endif

// Manual retrieval eval: swift run assistant-eval [--mode apple|lexical|fake] [--subset dev|heldout|all] [--out DIR] [--corpus FILE]
// Exit status: 0 every required case passed, 1 a required case failed, 2 not run (Apple's embedding is unavailable), 64 bad usage.
//
// Generated-answer review: swift run assistant-eval --mode generation [--samples N] [--scenarios id,id] [--out DIR] [--corpus FILE]
// Needs Apple's on-device language model. Writes review sheets with empty rubrics and scores nothing.
// Exit status: 0 sheets written, 2 not run (the model is unavailable), 64 bad usage.

/// Apple's English sentence embeddings, as the app reads them. Revision and dimension come from the model.
struct AppleEmbeddings: EmbeddingProvider {
    private func model() -> NLEmbedding? { NLEmbedding.sentenceEmbedding(for: .english) }

    func availability() async -> EmbeddingAvailability {
        guard let model = model(), model.dimension > 0 else { return .unavailable }
        return .available(EmbeddingProfile(revision: "NLEmbedding.sentence.en.\(model.revision)", dimension: model.dimension))
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let model = model() else { throw CocoaError(.featureUnsupported) }
        let neutral = [Float](repeating: 1 / Float(model.dimension).squareRoot(), count: model.dimension)
        return texts.map { text in
            guard let vector = model.vector(for: String(text.prefix(1_000))), vector.count == model.dimension, vector.allSatisfy(\.isFinite) else { return neutral }
            return vector.map { Float($0) }
        }
    }
}

func generationNote() -> String {
    var note = "The generated-answer suite is a manual human-rubric review and is not automated by this command."
    #if canImport(FoundationModels)
    if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available: note += " The Apple language model is available on this Mac."
        case .unavailable(let reason): note += " The Apple language model is unavailable (\(reason))."
        }
    } else {
        note += " This macOS has no Apple language model."
    }
    #else
    note += " The Apple language model framework is not present in this SDK."
    #endif
    return note
}

@MainActor
func appleBackend() -> GenerationBackend {
    let unavailable = { (reason: String) in
        GenerationBackend(availability: .unavailable(reason: reason), label: "Apple on-device language model (SystemLanguageModel.default)",
                          generator: UnavailableGenerator())
    }
    #if canImport(FoundationModels)
    if #available(macOS 27.0, *) {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            guard model.supportsLocale() else { return unavailable("The Apple language model does not support this Mac's locale.") }
            return GenerationBackend(
                availability: .available(details: ["contextSize": String(model.contextSize), "locale supported": "yes"]),
                label: "Apple on-device language model (SystemLanguageModel.default, general-purpose)",
                model: AppleCampingChatModel(), counter: AppleTokenCounter(), counterLabel: "SystemLanguageModel.tokenCount")
        case .unavailable(let reason):
            return unavailable("The Apple language model is unavailable (\(reason)).")
        }
    }
    return unavailable("This macOS has no Apple language model.")
    #else
    return unavailable("The Apple language model framework is not present in this SDK.")
    #endif
}

struct UnavailableGenerator: CampingResponseGenerating {
    func respond(to prompt: String, instructions: String) async throws -> String { throw CampingChatFailure.notReady }
}

func gitCommit() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["rev-parse", "--short", "HEAD"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return output?.isEmpty == false ? output : nil
}

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\nusage: assistant-eval [--mode apple|lexical|fake|generation] [--subset dev|heldout|all] [--out DIR] [--corpus FILE] [--samples N] [--scenarios id,id]\n".utf8))
    exit(64)
}

var mode = "apple", subset = "all", output = "EvalReports", corpusPath: String?, samples = 3, scenarioList: String?
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard let value = arguments.popFirst() else { usage("\(flag) needs a value") }
    switch flag {
    case "--mode": mode = value
    case "--subset": subset = value
    case "--out": output = value
    case "--corpus": corpusPath = value
    case "--samples":
        guard let count = Int(value), (1...50).contains(count) else { usage("--samples needs a number from 1 to 50") }
        samples = count
    case "--scenarios": scenarioList = value
    default: usage("unknown option \(flag)")
    }
}

var options = EvalOptions()
options.commit = gitCommit()
options.generationNote = generationNote()
switch subset {
case "all": break
case "dev": options.subsets = [.dev]
case "heldout": options.subsets = [.heldout]
default: usage("unknown subset \(subset)")
}

let retrieval: EvalRetrieval
switch mode {
case "apple": retrieval = .embedding(AppleEmbeddings(), label: "Apple NLEmbedding sentence (English)")
case "fake": retrieval = .embedding(DeterministicEmbeddingProvider(), label: "deterministic fake embeddings")
case "lexical", "generation": retrieval = mode == "lexical" ? .lexicalOnly : .embedding(AppleEmbeddings(), label: "Apple NLEmbedding sentence (English)")
default: usage("unknown mode \(mode)")
}

if mode == "generation" {
    do {
        let corpus = try corpusPath.map { try EvalCorpus.load(from: URL(fileURLWithPath: $0)) } ?? EvalCorpus.bundled()
        var generation = GenerationEvalOptions()
        generation.commit = options.commit
        generation.samples = samples
        generation.scenarioIDs = scenarioList.map { Set($0.split(separator: ",").map(String.init)) }
        let review = try await GenerationEvalRunner.run(corpus: corpus, retrieval: retrieval, backend: appleBackend(), options: generation)
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let sheets = directory.appendingPathComponent("generation", isDirectory: true)
        try FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        try review.json().write(to: directory.appendingPathComponent("generation-review.json"))
        try review.markdown().write(to: directory.appendingPathComponent("generation-review.md"), atomically: true, encoding: .utf8)
        for scenario in review.scenarios {
            var single = review; single.scenarios = [scenario]
            try single.json().write(to: sheets.appendingPathComponent("\(scenario.id).json"))
            try scenario.markdown(in: review).write(to: sheets.appendingPathComponent("\(scenario.id).md"), atomically: true, encoding: .utf8)
        }
        if review.status == GenerationReview.notRun {
            print("NOT RUN: \(review.notRunReason ?? "unavailable")")
            print("Reports: \(directory.path)/generation-review.{json,md}")
            exit(2)
        }
        let answers = review.scenarios.flatMap { $0.turns.flatMap(\.answers) }
        print("Generated \(answers.count) answers (\(answers.filter { $0.status == "failed" }.count) failed) across \(review.scenarios.count) scenarios, \(samples) sample(s) each. Nothing is scored.")
        print("Sheets: \(sheets.path)/<scenario>.{json,md}; index: \(directory.path)/generation-review.{json,md}")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("assistant-eval failed: \(error)\n".utf8))
        exit(1)
    }
}

do {
    let corpus = try corpusPath.map { try EvalCorpus.load(from: URL(fileURLWithPath: $0)) } ?? EvalCorpus.bundled()
    let report = try await EvalRunner.run(corpus: corpus, retrieval: retrieval, options: options)
    let directory = URL(fileURLWithPath: output, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stem = "retrieval-\(mode)-\(subset)"
    try report.json().write(to: directory.appendingPathComponent("\(stem).json"))
    try report.markdown().write(to: directory.appendingPathComponent("\(stem).md"), atomically: true, encoding: .utf8)

    switch report.outcome {
    case .notRun:
        print("NOT RUN: \(report.notRunReason ?? "unavailable")")
        print("Reports: \(directory.path)/\(stem).{json,md}")
        exit(2)
    case .passed, .failed:
        let r = report.required
        print("Required cases: \(r.passed)/\(r.cases) passed. Hit@5 \(r.hitAt5 ?? 0), Recall@5 \(r.recallAt5 ?? 0), MRR \(r.mrr ?? 0), "
              + "scope violations \(r.scopeViolations), stale \(r.staleEvidence), false positives \(r.noEvidenceFalsePositives)")
        let c = report.challenge
        print("Challenge cases (reported apart): \(c.passed)/\(c.cases) passed")
        if !r.failedCases.isEmpty { print("Failing required cases: \(r.failedCases.joined(separator: ", "))") }
        print("Outcome: \(report.outcome.rawValue.uppercased())")
        print("Reports: \(directory.path)/\(stem).{json,md}")
        exit(report.outcome == .passed ? 0 : 1)
    }
} catch {
    FileHandle.standardError.write(Data("assistant-eval failed: \(error)\n".utf8))
    exit(1)
}
