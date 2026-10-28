import Foundation
import NaturalLanguage
import AssistantEval
import DocumentSearch
#if canImport(FoundationModels)
import FoundationModels
#endif

// Manual retrieval eval: swift run assistant-eval [--mode apple|lexical|fake] [--subset dev|heldout|all] [--out DIR] [--corpus FILE]
// Exit status: 0 every required case passed, 1 a required case failed, 2 not run (Apple's embedding is unavailable), 64 bad usage.

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
    FileHandle.standardError.write(Data("\(message)\nusage: assistant-eval [--mode apple|lexical|fake] [--subset dev|heldout|all] [--out DIR] [--corpus FILE]\n".utf8))
    exit(64)
}

var mode = "apple", subset = "all", output = "EvalReports", corpusPath: String?
var arguments = CommandLine.arguments.dropFirst()
while let flag = arguments.popFirst() {
    guard let value = arguments.popFirst() else { usage("\(flag) needs a value") }
    switch flag {
    case "--mode": mode = value
    case "--subset": subset = value
    case "--out": output = value
    case "--corpus": corpusPath = value
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
case "lexical": retrieval = .lexicalOnly
default: usage("unknown mode \(mode)")
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
