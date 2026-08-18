// Wayzyy moderation — transport-agnostic service adapter.
//
// Speaks newline-delimited JSON on stdin/stdout: one request object per line, one response
// object per line, in order. The engine itself is reached only through the public
// `WayzyyModerationService` facade, so this file contains no moderation logic — swapping in
// HTTP, gRPC, a queue consumer or a serverless handler means replacing this loop and
// nothing else.
//
//   echo '{"id":"1","text":"call me on 9876543210","senderID":"s","conversationID":"c"}' | wayzyy-moderate
//   echo '{"op":"health"}' | wayzyy-moderate

import Foundation
import WayzyyModeration

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
let decoder = JSONDecoder()

func emit(_ verdict: ModerationVerdictDTO) {
    if let data = try? encoder.encode(verdict),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    } else {
        print(#"{"ok":false,"error":"response encoding failed"}"#)
    }
    fflush(stdout)
}

func failure(_ message: String) -> ModerationVerdictDTO {
    ModerationVerdictDTO(ok: false, error: message)
}

// Wire the process before serving anything, and say so on stderr — stdout carries the response
// stream and must stay machine-readable. Startup that silently leaves Tier 3 unconfigured is the
// failure this exists to prevent: see WayzyyModerationService.bootstrap.
do {
    let report = try WayzyyModerationService.bootstrap()
    if let data = try? encoder.encode(report), let line = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data(("startup \(line)\n").utf8))
    }
} catch {
    FileHandle.standardError.write(Data("startup failed: \(error)\n".utf8))
    exit(78)   // EX_CONFIG — the configuration is wrong, not the request
}

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }

    guard trimmed.utf8.count <= ModerationLimits.maxRequestBytes else {
        emit(failure("request exceeds \(ModerationLimits.maxRequestBytes) bytes"))
        continue
    }
    guard let data = trimmed.data(using: .utf8) else {
        emit(failure("malformed JSON request"))
        continue
    }

    // Recipient signals carry an op of report/block and no text; they are evidence rather
    // than a message to judge, so they take a different path and return counters.
    if let signal = try? decoder.decode(RecipientSignalDTO.self, from: data),
       signal.op == "report" || signal.op == "block" {
        let ack = WayzyyModerationService.handle(signal)
        if let out = try? encoder.encode(ack), let line = String(data: out, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
        continue
    }

    if let ctx = try? decoder.decode(ConversationContextDTO.self, from: data),
       ctx.op == "context" {
        let ack = WayzyyModerationService.handle(ctx)
        if let out = try? encoder.encode(ack), let line = String(data: out, encoding: .utf8) {
            print(line)
            fflush(stdout)
        }
        continue
    }

    guard let request = try? decoder.decode(ModerationRequestDTO.self, from: data) else {
        emit(failure("malformed JSON request"))
        continue
    }

    // Durable path: a repeated request id returns the decision already made rather than
    // producing a second one. A storage failure is reported as a failure — a verdict the store
    // never saw cannot be appealed or reconciled, so it must not be presented as decided.
    do {
        emit(try WayzyyModerationService.handleDurably(request))
    } catch {
        emit(failure("decision could not be recorded: \(error)"))
    }
}

// Adjudication runs after the response, so exiting the moment stdin closes would abandon
// judgements already in flight — and those are exactly the messages the deterministic tiers
// were least sure about. Wait for them, bounded, before leaving.
let drained = WayzyyModerationService.drainAdjudications(timeout: 30)
let stats = WayzyyModerationService.adjudicationStats
FileHandle.standardError.write(Data(
    "shutdown drained=\(drained) adjudications=\(stats.completed) changed=\(stats.changed) dropped=\(stats.dropped)\n".utf8))
