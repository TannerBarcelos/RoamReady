#if DEBUG
import Foundation
import Darwin
import CampCore
import DocumentSearch
import DocumentVault
#if canImport(FoundationModels)
import AssistantModel
#endif

/// `-assistant-performance-baseline [quick|standard]` measures the Assistant's document pipeline on the device
/// that is running it. It generates invented PDFs (see `SyntheticPDFCorpus`), imports them the way the app does,
/// indexes them through the real `DocumentIndexCoordinator` with Apple's embeddings and text recognition, then
/// searches, answers (when the on-device model is ready), and cancels. It writes a JSON report and logs numbers
/// only. It never reads the library and never logs document text or questions. `docs/assistant-quality-baseline.md`
/// says how to run it and where the report lands.
///
/// Simulator numbers are labeled diagnostic: the Simulator borrows the Mac's CPU, memory, and models.
enum AssistantPerformanceBaseline {
    static let argument = "-assistant-performance-baseline"

    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(argument) }

    private static var tier: Tier {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1) else { return .standard }
        return Tier(rawValue: arguments[index + 1]) ?? .standard
    }

    enum Tier: String {
        case quick, standard
        /// Typed documents added at each step, then the scanned documents added last.
        var textSteps: [Int] { self == .quick ? [3, 3] : [5, 15, 20] }
        var scanPages: Int { self == .quick ? 3 : 24 }
        var warmQueries: Int { self == .quick ? 8 : 20 }
    }

    static func runIfRequested() async {
        guard isRequested else { return }
        let tier = tier
        NSLog("ASSISTANT-PERF: start tier=%@", tier.rawValue)
        do {
            let report = try await run(tier: tier)
            let url = try write(report)
            NSLog("ASSISTANT-PERF: done label=%@ peakFootprintMB=%.0f report=%@", report.label, report.peakFootprintMB, url.path)
        } catch {
            NSLog("ASSISTANT-PERF: FAILED %@", "\(error)")
        }
    }

    // MARK: Report

    struct Report: Codable {
        struct Environment: Codable {
            var device: String, os: String, isSimulator: Bool, isMacCatalyst: Bool
            var physicalMemoryMB: Int, processors: Int, thermalState: String, lowPowerMode: Bool
            var appVersion: String
            var embeddingRevision: String?, embeddingDimension: Int?
            var extractionVersion: Int, chunkingVersion: Int, indexSchemaVersion: Int
            var languageModel: String
        }
        struct Step: Codable {
            var name: String
            var typedDocuments: Int, scannedDocuments: Int, pages: Int, passages: Int
            var importBytes: Int, importSeconds: Double, importMBPerSecond: Double
            var indexWallSeconds: Double
            var textLayerPages: Int, textLayerExtractSeconds: Double, textLayerPagesPerSecond: Double?
            var ocrPages: Int, ocrSeconds: Double, ocrPagesPerSecond: Double?
            var embeddedTexts: Int, embedSeconds: Double, embeddingsPerSecond: Double?
            var documentsReady: Int, documentsNotReady: Int
            var indexBytes: Int
            var warmSearchSeconds: Percentiles
            var topResultCorrect: Int, queriesRun: Int
        }
        struct Percentiles: Codable { var count: Int, p50: Double, p95: Double, max: Double }
        struct Answer: Codable {
            var retrievalSeconds: Double, generationSeconds: Double, totalSeconds: Double, validCitations: Int, coverage: String
        }
        struct Cancellation: Codable {
            var stateWhenCancelled: String, secondsToStop: Double, scanPages: Int
        }
        var label: String
        var tier: String
        var generatedAt: Date
        var environment: Environment
        var steps: [Step]
        /// The first search in this process, right after the first index step. Not an OS-cold read.
        var firstSearchSecondsInProcess: Double
        /// The first search after closing the index and opening it with a new coordinator.
        var firstSearchSecondsAfterReopen: Double
        var answers: [Answer]
        var answersNotRunReason: String?
        var cancellation: Cancellation?
        var peakFootprintMB: Double
        var notes: [String]
    }

    private static func write(_ report: Report) throws -> URL {
        let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = documents.appendingPathComponent("AssistantPerformance", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let stamp = ISO8601DateFormatter().string(from: report.generatedAt).replacingOccurrences(of: ":", with: "-")
        let url = folder.appendingPathComponent("performance-\(stamp).json")
        try data.write(to: url)
        try data.write(to: folder.appendingPathComponent("latest.json"))
        return url
    }

    // MARK: Run

    private static func run(tier: Tier) async throws -> Report {
        let sampler = MemorySampler()
        sampler.start()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("AssistantPerformance-\(UUID().uuidString)", isDirectory: true)
        let files = work.appendingPathComponent("files", isDirectory: true)
        let indexFolder = work.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let counters = Counters()
        let provider = TimedEmbeddings(inner: AppleEmbeddingProvider(), counters: counters)
        let source = SyntheticSource(counters: counters)
        func makeCoordinator() -> DocumentIndexCoordinator {
            DocumentIndexCoordinator(directory: indexFolder, source: source, embedding: provider, extractionVersion: DocumentTextExtractor.version)
        }
        var coordinator = makeCoordinator()
        await coordinator.open()

        var steps: [Report.Step] = []
        var typedTotal = 0, scannedTotal = 0, number = 0
        var firstSearch = 0.0
        var plan: [(name: String, typed: Int, scanned: Int)] = tier.textSteps.enumerated().map { ("step \($0.offset + 1)", $0.element, 0) }
        plan.append(("large scan", 0, 1))

        for (stepIndex, stepPlan) in plan.enumerated() {
            // Generate and write the files (not timed), then time the app's import check over them.
            var items: [SyntheticPDFCorpus.Item] = []
            for _ in 0..<stepPlan.typed { number += 1; items.append(SyntheticPDFCorpus.manual(number: number, pages: 6 + number % 5)) }
            for _ in 0..<stepPlan.scanned { number += 1; items.append(SyntheticPDFCorpus.scan(number: number, pages: tier.scanPages)) }
            var added: [(id: String, item: SyntheticPDFCorpus.Item, checksum: String)] = []
            var importBytes = 0
            var importSeconds = 0.0
            for item in items {
                let url = files.appendingPathComponent(item.name)
                try item.data.write(to: url)
                let started = ContinuousClock.now
                let file = try DocumentPolicy.inspect(fileAt: url, filename: item.name)
                importSeconds += started.duration(to: .now).seconds
                importBytes += file.byteCount
                added.append((UUID().uuidString, item, file.checksum))
            }
            source.add(added.map { ($0.id, $0.item, $0.checksum) })
            typedTotal += stepPlan.typed; scannedTotal += stepPlan.scanned

            counters.reset()
            let started = ContinuousClock.now
            await coordinator.reconcile(.change)
            await coordinator.waitUntilIdle()
            let wall = started.duration(to: .now).seconds
            let snapshot = counters.snapshot()
            let states = await coordinator.documentStates()
            let ready = states.values.filter { $0 == .ready || $0 == .readPartially || $0 == .englishPartial }.count

            if stepIndex == 0 { firstSearch = try await timeFirstSearch(coordinator, source: source) }
            let search = await warmSearches(coordinator, source: source, count: tier.warmQueries)

            steps.append(.init(
                name: stepPlan.name, typedDocuments: typedTotal, scannedDocuments: scannedTotal,
                pages: items.reduce(0) { $0 + $1.pages }, passages: snapshot.embeddedTexts,
                importBytes: importBytes, importSeconds: importSeconds, importMBPerSecond: importSeconds > 0 ? Double(importBytes) / 1_048_576 / importSeconds : 0,
                indexWallSeconds: wall,
                textLayerPages: snapshot.textPages, textLayerExtractSeconds: snapshot.textSeconds,
                textLayerPagesPerSecond: snapshot.textSeconds > 0 ? Double(snapshot.textPages) / snapshot.textSeconds : nil,
                ocrPages: snapshot.ocrPages, ocrSeconds: snapshot.ocrSeconds,
                ocrPagesPerSecond: snapshot.ocrSeconds > 0 ? Double(snapshot.ocrPages) / snapshot.ocrSeconds : nil,
                embeddedTexts: snapshot.embeddedTexts, embedSeconds: snapshot.embedSeconds,
                embeddingsPerSecond: snapshot.embedSeconds > 0 ? Double(snapshot.embeddedTexts) / snapshot.embedSeconds : nil,
                documentsReady: ready, documentsNotReady: states.count - ready,
                indexBytes: indexSize(indexFolder), warmSearchSeconds: search.percentiles,
                topResultCorrect: search.correct, queriesRun: search.percentiles.count))
            NSLog("ASSISTANT-PERF: %@ docs=%d wall=%.1fs ocrPagesPerSec=%.2f embedPerSec=%.1f warmP50=%.3fs indexMB=%.1f",
                  stepPlan.name, typedTotal + scannedTotal, wall, steps.last?.ocrPagesPerSecond ?? 0, steps.last?.embeddingsPerSecond ?? 0,
                  search.percentiles.p50, Double(steps.last?.indexBytes ?? 0) / 1_048_576)
        }

        // Close and reopen with a new coordinator: the first search then pays for opening the file.
        await coordinator.shutdown()
        coordinator = makeCoordinator()
        await coordinator.open()
        let afterReopen = try await timeFirstSearch(coordinator, source: source)

        let (answers, answersReason) = await timeAnswers(coordinator, source: source)

        // Cancellation: start reading one more large scan, then stop the coordinator mid-document.
        let cancel = SyntheticPDFCorpus.scan(number: number + 1, pages: tier.scanPages)
        let cancelID = UUID().uuidString
        source.add([(cancelID, cancel, DocumentDigest.sha256(cancel.data))])
        await coordinator.reconcile(.change)
        var state = "never started"
        for _ in 0..<400 {
            if let current = await coordinator.documentStates()[cancelID], current == .extracting { state = "extracting"; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))
        let stopStarted = ContinuousClock.now
        await coordinator.shutdown()
        let stop = stopStarted.duration(to: .now).seconds
        NSLog("ASSISTANT-PERF: cancel state=%@ secondsToStop=%.2f", state, stop)

        let peak = sampler.stop()
        return Report(
            label: label, tier: tier.rawValue, generatedAt: Date(), environment: await environment(provider: provider), steps: steps,
            firstSearchSecondsInProcess: firstSearch, firstSearchSecondsAfterReopen: afterReopen, answers: answers,
            answersNotRunReason: answersReason, cancellation: .init(stateWhenCancelled: state, secondsToStop: stop, scanPages: tier.scanPages),
            peakFootprintMB: Double(peak) / 1_048_576,
            notes: ["Cold means the first search in this process or after reopening the index; the OS file cache is not flushed. For a colder number, run right after a device restart.",
                    "Text recognition is not cancellable inside one document, so seconds to stop is the time to finish the document being read.",
                    "Peak memory is the process's physical footprint, sampled every 50 ms.",
                    "Synthetic English manuals only; no document text or question is logged or exported."])
    }

    #if targetEnvironment(simulator)
    private static let isSimulator = true
    #else
    private static let isSimulator = false
    #endif
    #if targetEnvironment(macCatalyst)
    private static let isMacCatalyst = true
    #else
    private static let isMacCatalyst = false
    #endif

    private static var label: String {
        #if targetEnvironment(simulator)
        "DIAGNOSTIC (Simulator): not a baseline; it shares the Mac's CPU, memory, and models"
        #elseif targetEnvironment(macCatalyst)
        "Mac (Catalyst) measurement: confirm the Mac was idle and on power"
        #else
        "Device measurement: confirm the device was idle, plugged in, and thermally nominal"
        #endif
    }

    // MARK: Searching

    private static let questionComponents = ["water heater", "furnace", "refrigerator", "awning", "slide-out", "leveling jack", "converter",
                                             "inverter", "propane regulator", "fresh water pump", "black tank valve", "roof air conditioner",
                                             "stabilizer jack", "battery monitor"]

    private static func question(for entry: SyntheticSource.Entry) -> String {
        "What does fault code \(entry.item.code) mean on the \(questionComponents[Int(entry.item.code.dropFirst()).map { $0 % questionComponents.count } ?? 0])?"
    }

    private static func timeFirstSearch(_ coordinator: DocumentIndexCoordinator, source: SyntheticSource) async throws -> Double {
        guard let entry = source.typedEntries().first else { return 0 }
        let started = ContinuousClock.now
        _ = await coordinator.search(question(for: entry), live: source.liveChecksums())
        return started.duration(to: .now).seconds
    }

    private static func warmSearches(_ coordinator: DocumentIndexCoordinator, source: SyntheticSource, count: Int) async -> (percentiles: Report.Percentiles, correct: Int) {
        let entries = source.typedEntries()
        guard !entries.isEmpty else { return (.init(count: 0, p50: 0, p95: 0, max: 0), 0) }
        let live = source.liveChecksums()
        var times: [Double] = []
        var correct = 0
        for i in 0..<count {
            let entry = entries[(i * 7) % entries.count]
            let started = ContinuousClock.now
            let result = await coordinator.search(question(for: entry), live: live)
            times.append(started.duration(to: .now).seconds)
            if result?.hits.first?.documentID == entry.id { correct += 1 }
        }
        times.sort()
        func at(_ q: Double) -> Double { times[min(times.count - 1, Int(Double(times.count) * q))] }
        return (.init(count: times.count, p50: at(0.5), p95: at(0.95), max: times.last ?? 0), correct)
    }

    @MainActor
    private static func timeAnswers(_ coordinator: DocumentIndexCoordinator, source: SyntheticSource) async -> ([Report.Answer], String?) {
        guard CampingAssistant.globalAvailability == .ready else {
            return ([], "not run: the on-device language model is not ready (\(CampingAssistant.globalAvailability))")
        }
        #if canImport(FoundationModels)
        let entries = source.typedEntries()
        let live = source.liveChecksums()
        var answers: [Report.Answer] = []
        var failures = 0
        var lastFailure = ""
        for entry in entries.prefix(3) {
            let text = question(for: entry)
            let started = ContinuousClock.now
            guard let result = await coordinator.search(text, live: live) else { continue }
            let retrieved = started.duration(to: .now).seconds
            let liveDocuments = Dictionary(uniqueKeysWithValues: source.allEntries().compactMap { entry -> (UUID, LiveDocument)? in
                UUID(uuidString: entry.id).map { ($0, LiveDocument(id: $0, title: entry.item.name, category: "Manual", checksum: entry.checksum, isInScope: true)) }
            })
            let candidates = result.hits.compactMap { hit in
                UUID(uuidString: hit.documentID).map {
                    DocumentEvidenceCandidate(documentID: $0, indexedChecksum: hit.checksum, page: hit.page, pageLabel: hit.pageLabel,
                                              section: hit.section, text: hit.text, ocrConfidence: hit.ocrConfidence)
                }
            }
            let evidence = DocumentEvidence.make(question: text, candidates: candidates, live: liveDocuments)
            let request = CampingHelpRequest(question: text, steps: [], rigType: nil, step: nil, scope: .general, documents: evidence)
            let generationStarted = ContinuousClock.now
            do {
                // A new chat per question, as the baseline measures single answers.
                let reply = try await CampingChat(model: AppleCampingChatModel(), counter: AppleTokenCounter()).answer(request)
                answers.append(.init(retrievalSeconds: retrieved, generationSeconds: generationStarted.duration(to: .now).seconds,
                                     totalSeconds: started.duration(to: .now).seconds, validCitations: reply.sources.count, coverage: "\(reply.coverage)"))
            } catch {
                failures += 1
                lastFailure = "\(error)"
            }
        }
        return (answers, failures == 0 ? nil : "\(failures) of 3 answers failed (last: \(lastFailure)); the others are listed")
        #else
        return ([], "not run: FoundationModels is not in this SDK")
        #endif
    }

    private static func indexSize(_ folder: URL) -> Int {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let path = folder.appendingPathComponent(DocumentIndexCoordinator.fileName + suffix).path
            return total + ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
        }
    }

    @MainActor
    private static func environment(provider: any EmbeddingProvider) async -> Report.Environment {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
        let info = ProcessInfo.processInfo
        var profile: EmbeddingProfile?
        if case .available(let found) = await provider.availability() { profile = found }
        let thermal = switch info.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        let bundle = Bundle.main
        return .init(
            device: info.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? sysctl("hw.machine") ?? sysctl("hw.model") ?? "unknown",
            os: info.operatingSystemVersionString,
            isSimulator: isSimulator, isMacCatalyst: isMacCatalyst,
            physicalMemoryMB: Int(info.physicalMemory / 1_048_576), processors: info.activeProcessorCount, thermalState: thermal,
            lowPowerMode: info.isLowPowerModeEnabled,
            appVersion: "\(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") (\(bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?"))",
            embeddingRevision: profile?.revision, embeddingDimension: profile?.dimension,
            extractionVersion: DocumentTextExtractor.version, chunkingVersion: PassageChunker.version,
            indexSchemaVersion: DocumentSearchIndex.schemaVersion, languageModel: "\(CampingAssistant.globalAvailability)")
    }
}

// MARK: - Measuring pieces

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

private final class Counters: @unchecked Sendable {
    struct Snapshot {
        var textPages = 0, ocrPages = 0, embeddedTexts = 0
        var textSeconds = 0.0, ocrSeconds = 0.0, embedSeconds = 0.0
    }
    private let lock = NSLock()
    private var value = Snapshot()

    func reset() { lock.withLock { value = Snapshot() } }
    func snapshot() -> Snapshot { lock.withLock { value } }
    func update(_ change: (inout Snapshot) -> Void) { lock.withLock { change(&value) } }
}

/// Apple's embeddings, timed. The text itself is never recorded.
private struct TimedEmbeddings: EmbeddingProvider {
    let inner: AppleEmbeddingProvider
    let counters: Counters

    func availability() async -> EmbeddingAvailability { await inner.availability() }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        let started = ContinuousClock.now
        let vectors = try await inner.embed(texts)
        let seconds = started.duration(to: .now).seconds
        counters.update { $0.embeddedTexts += texts.count; $0.embedSeconds += seconds }
        return vectors
    }
}

/// The library the coordinator indexes: in-memory bytes, read the way the app reads a stored document (extraction
/// runs in a detached utility task, so cancelling the coordinator cannot interrupt a document mid-read).
private final class SyntheticSource: DocumentIndexSource, @unchecked Sendable {
    struct Entry { var id: String; var item: SyntheticPDFCorpus.Item; var checksum: String }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let counters: Counters

    init(counters: Counters) { self.counters = counters }

    func add(_ new: [(String, SyntheticPDFCorpus.Item, String)]) {
        lock.withLock { entries += new.map { Entry(id: $0.0, item: $0.1, checksum: $0.2) } }
    }

    func allEntries() -> [Entry] { lock.withLock { entries } }
    func typedEntries() -> [Entry] { allEntries().filter { !$0.item.isScanned } }
    func liveChecksums() -> [String: String] { Dictionary(uniqueKeysWithValues: allEntries().map { ($0.id, $0.checksum) }) }

    func library() async throws -> [LibraryDocument] {
        allEntries().map { LibraryDocument(id: $0.id, checksum: $0.checksum, availability: .ready) }
    }

    func read(_ document: LibraryDocument) async throws -> DocumentReadResult {
        guard let entry = allEntries().first(where: { $0.id == document.id }), entry.checksum == document.checksum else { return .changed }
        let counters = counters
        return try await Task.detached(priority: .utility) {
            let started = ContinuousClock.now
            let extraction = DocumentTextExtractor.extract(from: entry.item.data)
            let seconds = started.duration(to: .now).seconds
            switch extraction.outcome {
            case .noUsableText(let reason): return .noUsableText(reason)
            case .retryLater: throw CocoaError(.fileReadUnknown)
            case .ready(let recognized, let skipped):
                counters.update {
                    if entry.item.isScanned { $0.ocrPages += recognized; $0.ocrSeconds += seconds }
                    else { $0.textPages += extraction.pages.count; $0.textSeconds += seconds }
                }
                return .text(ExtractedDocument(pages: extraction.pages, language: extraction.language,
                                               isEnglish: extraction.isEnglish, skippedPages: skipped))
            }
        }.value
    }
}

/// Polls the process's physical footprint, the number the system uses to judge memory use, and keeps the peak.
private final class MemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var task: Task<Void, Never>?

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        task = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                let now = Self.footprint()
                lock.withLock { peak = max(peak, now) }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func stop() -> UInt64 {
        task?.cancel()
        return lock.withLock { max(peak, Self.footprint()) }
    }
}
#endif
