import Foundation

extension GenerationReview {
    /// The index: run metadata and one line per scenario. The per-scenario sheets hold the answers.
    public func markdown() -> String {
        var out = "# Generated-answer review\n\n"
        out += "**Status: \(status.uppercased()).** "
        if let notRunReason {
            out += "\(notRunReason)\n\nNo answers were generated and nothing was scored. A run that did not happen is not a pass.\n\n"
        } else {
            out += "Answers are generated but **not scored**. A person fills in each rubric. Model judges are not used.\n\n"
        }
        out += "## Run record\n\n| | |\n| --- | --- |\n"
        let m = metadata
        let rows: [(String, String)] = [
            ("Corpus", "\(m.corpusVersion), SHA-256 \(m.corpusChecksum)"), ("Commit", m.commit ?? "unknown"),
            ("OS", m.operatingSystem), ("Hardware", m.hardware), ("Retrieval", m.retrieval),
            ("Embedding revision / dimension", "\(m.embeddingRevision ?? "none (lexical only)") / \(m.embeddingDimension.map(String.init) ?? "none")"),
            ("Extraction / chunking / index schema", "\(m.extractionVersion) / \(m.chunkingVersion) / \(m.indexSchemaVersion)"),
            ("sqlite-vec", m.sqliteVecVersion), ("Ranker", m.ranker), ("Evidence limits", m.evidenceLimits),
            ("Model", generation.model), ("Model details", generation.modelDetails.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; ")),
            ("Samples per scenario", String(generation.samplesPerScenario)), ("Max response tokens", String(generation.maximumResponseTokens)),
            ("Token counter", generation.tokenCounter), ("Session policy", generation.sessionPolicy), ("Prompt version", generation.promptVersion),
            ("Generated", ISO8601DateFormatter().string(from: m.generatedAt))
        ]
        for (name, value) in rows { out += "| \(name) | \(value.replacingOccurrences(of: "|", with: "\\|")) |\n" }

        func table(_ kind: String) -> String {
            let items = scenarios.filter { $0.kind == kind }
            guard !items.isEmpty else { return "_None._\n\n" }
            var t = "| Scenario | Group | Turns | Samples | Cross-scope/excluded | Stale | Rejected citation IDs |\n| --- | --- | --- | --- | --- | --- | --- |\n"
            for s in items {
                let crossScope = s.turns.reduce(0) { $0 + $1.crossScopeOrExcludedSources.count }
                let stale = s.turns.reduce(0) { $0 + $1.staleSources.count }
                let rejected = s.turns.flatMap(\.answers).reduce(0) { $0 + $1.rejectedCitationIDs }
                t += "| [\(s.id)](generation/\(s.id).md) | \(s.group) | \(s.turns.count) | \(s.turns.first?.answers.count ?? 0) | \(crossScope) | \(stale) | \(rejected) |\n"
            }
            return t + "\n"
        }
        out += "\n## Required release cases\n\n" + table("required")
        out += "## Challenge cases (reported apart)\n\n" + table("challenge")
        out += "Cross-scope, excluded, and stale sources must be 0 in every row. Rejected citation IDs count IDs the model invented that the Assistant dropped; the camper never sees them, but record the rate.\n"
        return out
    }
}

extension GenerationReview.Scenario {
    /// One scenario's review sheet.
    public func markdown(in review: GenerationReview) -> String {
        var out = "# \(id)\n\n**Group:** \(group) · **Kind:** \(kind)\n\n\(purpose)\n\n"
        out += "Run: commit \(review.metadata.commit ?? "unknown") · corpus \(review.metadata.corpusVersion) \(review.metadata.corpusChecksum.prefix(12)) · "
        out += "\(review.metadata.hardware) · \(review.metadata.operatingSystem) · \(review.metadata.retrieval) · prompt \(review.generation.promptVersion.prefix(40))…\n\n"
        for (index, turn) in turns.enumerated() {
            out += "## Turn \(index + 1): \(turn.label)\n\n"
            out += "- **Question:** \(turn.question)\n- **Scope:** \(turn.scope)\n"
            if let readiness = turn.readiness { out += "- **Readiness when asked:** \(readiness)\n" }
            out += "- **Saved trip facts supplied:** \(turn.savedTripFactsSupplied ? "yes (own block, not a document)" : "no")\n"
            if let notice = turn.englishOnlyNotice {
                out += "- **Fixed notice shown, model not called:** \(notice)\n\n"
                continue
            }
            out += "\n**Evidence actually supplied to the model**\n\n"
            if turn.supplied.isEmpty { out += "_No excerpts were supplied._\n" }
            for s in turn.supplied {
                out += "- `[\(s.sourceID)]` \(s.title) (\(s.document) @ \(s.version)) page \(s.page.map(String.init) ?? "?"):\n  > \(s.text.replacingOccurrences(of: "\n", with: "\n  > "))\n"
            }
            out += "\n- Cross-scope or excluded sources: \(turn.crossScopeOrExcludedSources.isEmpty ? "0" : turn.crossScopeOrExcludedSources.map { "\($0.title) (\($0.reason))" }.joined(separator: "; "))\n"
            out += "- Stale sources: \(turn.staleSources.isEmpty ? "0" : turn.staleSources.map { "\($0.title) (\($0.reason))" }.joined(separator: "; "))\n"
            if !turn.expectedEvidence.isEmpty {
                out += "\n**Labeled evidence (corpus)**\n\n" + turn.expectedEvidence.map { "- \($0)" }.joined(separator: "\n") + "\n"
            }
            out += "\n**Look for**\n\n" + turn.lookFor.map { "- \($0)" }.joined(separator: "\n") + "\n"
            for a in turn.answers {
                out += "\n### Sample \(a.sample)\(a.status == "failed" ? " — FAILED (\(a.failure ?? "unknown"))" : "")\n\n"
                out += "> \(a.rawText.isEmpty ? "(no text)" : a.rawText.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
                let cited = a.validatedCitations.map { "[\($0.id)] \($0.title) p.\($0.page.map(String.init) ?? "?")" }.joined(separator: "; ")
                out += "- Validated citations: \(cited.isEmpty ? "none" : cited)\n"
                out += "- Rejected citation IDs: \(a.rejectedCitationIDs) · Coverage: \(a.coverage) · Saved trip listed: \(a.usedSavedTrip) · Compact retry: \(a.usedCompactRetry) · \(String(format: "%.1f", a.seconds)) s\n\n"
                out += """
                | Rubric | Pass / Fail / n/a |
                | --- | --- |
                | Supported facts (every claim is in the supplied sources) | |
                | Correct attribution (the right document, page, or saved trip) | |
                | No invented specifications or booking details | |
                | Appropriate missing-evidence response | |
                | Safety preserved | |
                | **Overall** | |

                Notes:

                """
            }
            out += "\n"
        }
        return out
    }
}
