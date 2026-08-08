// Loads provider credentials from Secrets.json or the environment.

import Foundation

enum SecretsStore {

    private static let embedded: [String: String] = [:]

    private static let values: [String: String] = {
        var merged: [String: String] = [:]

        func absorb(_ source: [String: String]) {
            for (key, value) in source where !value.isEmpty && merged[key] == nil {
                merged[key] = value
            }
        }

        var candidates: [URL] = []

        if let raw = ProcessInfo.processInfo.environment["WAYZYY_KEYS"],
           let data = raw.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            absorb(parsed)
        }

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Secrets.json")
        candidates.append(root)

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: String]
            else { continue }
            absorb(parsed)
        }

        absorb(embedded)
        return merged
    }()

    static var providerDescription: String {
        if groq != nil { return "Groq (live)" }
        if gemini != nil { return "Gemini (live)" }
        return "Offline fixtures — no key configured"
    }

    static func key(_ name: String) -> String? { values[name] }

    static var gemini: String? { key("gemini") }
    static var groq: String? { key("groq") }

    static var hasAnyProvider: Bool { gemini != nil || groq != nil }
}

extension RemoteJudge.Configuration {

    static let geminiFallbackModels = [
        "gemini-2.5-flash-lite",
        "gemini-2.0-flash-lite",
        "gemini-2.0-flash",
        "gemini-2.5-flash",
    ]

    static let groqFallbackModels = [
        "openai/gpt-oss-safeguard-20b",
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "qwen/qwen3.6-27b",
        "llama-3.3-70b-versatile",
        "llama-3.1-8b-instant",
    ]

    static let groqSchemaCompliantModels = [
        "openai/gpt-oss-safeguard-20b",
        "openai/gpt-oss-20b",
        "openai/gpt-oss-120b",
        "qwen/qwen3.6-27b",
    ]

    static func gemini(
        apiKey: String,
        model: String = "gemini-2.5-flash-lite"
    ) -> RemoteJudge.Configuration {
        RemoteJudge.Configuration(
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!,
            model: model,
            apiKey: apiKey
        )
    }

    static func fromSecrets() -> RemoteJudge.Configuration? {
        if let groq = SecretsStore.groq {
            return .groq(apiKey: groq)
        }
        if let gemini = SecretsStore.gemini {
            return .gemini(apiKey: gemini)
        }
        return nil
    }
}

extension ModerationEngine {
    func configureJudgeFromSecrets() {
        if let configuration = RemoteJudge.Configuration.fromSecrets() {
            judge = RemoteJudge(configuration: configuration)
        }
    }
}
