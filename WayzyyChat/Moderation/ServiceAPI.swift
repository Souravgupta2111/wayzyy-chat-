
import Foundation


    // Unique identifier for tracking this request through the moderation pipeline
public struct ModerationRequestDTO: Codable, Sendable {
    public var id: String?
    public var op: String?
    public var text: String?
    public var conversationID: String?
    public var senderID: String?
    public var trust: String?
    // Captures the lifecycle stage of the booking to adjust policy strictness dynamically
    public var stage: String?
    public var priorViolations: Int?
    public var advisory: Bool?

    public init(
        id: String? = nil, op: String? = nil, text: String? = nil,
        conversationID: String? = nil, senderID: String? = nil,
        trust: String? = nil, stage: String? = nil,
        priorViolations: Int? = nil, advisory: Bool? = nil
    ) {
        self.id = id; self.op = op; self.text = text
        self.conversationID = conversationID; self.senderID = senderID
        self.trust = trust; self.stage = stage
        self.priorViolations = priorViolations; self.advisory = advisory
    }
}


public struct RecipientSignalDTO: Codable, Sendable {
    public var id: String?
    public var op: String
    public var senderID: String
    public var conversationID: String?

    public init(id: String? = nil, op: String, senderID: String, conversationID: String? = nil) {
        self.id = id; self.op = op
        self.senderID = senderID; self.conversationID = conversationID
    }
}

public struct ConversationContextDTO: Codable, Sendable {
    public var op: String?
    public var conversationID: String
    // Captures the lifecycle stage of the booking to adjust policy strictness dynamically
    public var stage: String?
    public var trust: String?
    public var priorViolations: Int?

    public init(conversationID: String, stage: String? = nil, trust: String? = nil,
                priorViolations: Int? = nil) {
        self.op = "context"
        self.conversationID = conversationID
        self.stage = stage
        self.trust = trust
        self.priorViolations = priorViolations
    }
}

public struct ConversationContextAckDTO: Codable, Sendable {
    public var ok: Bool
    public var conversationID: String?
    // Captures the lifecycle stage of the booking to adjust policy strictness dynamically
    public var stage: String?
    public var trust: String?
    public var priorViolations: Int?
    public var error: String?
}

public struct RecipientSignalAckDTO: Codable, Sendable {
    public var id: String?
    public var ok: Bool
    public var op: String?
    public var senderID: String?
    public var receivedReports: Int?
    public var blockEvents: Int?
    public var compositeRisk: Double?
    public var elevated: Bool?
    public var error: String?

    public init(id: String? = nil, ok: Bool, error: String? = nil) {
        self.id = id; self.ok = ok; self.error = error
    }
}


public struct ModerationVerdictDTO: Codable, Sendable {
    public var id: String?
    public var ok: Bool
    public var action: String?
    public var score: Double?
    public var categories: [String]?
    public var reasonCodes: [String]?
    public var maskedText: String?
    public var tierReached: Int?
    public var latencyMs: Double?
    public var policyVersion: String?
    public var provisionalHold: Bool?
    public var escalationCandidate: Bool?
    public var idempotentReplay: Bool?
    public var error: String?
    public var displayAction: String?
    public var displayText: String?
    public var source: String?

    public init(id: String? = nil, ok: Bool, error: String? = nil) {
        self.id = id; self.ok = ok; self.error = error
    }
}


public enum ModerationLimits {
    public static let maxTextBytes = 8_192
    public static let maxRequestBytes = 32_768
}


public enum WayzyyModerationService {

    public static var policyVersion: String { Policy.current.version }

    public static var tier3Available: Bool { ModerationEngine.shared.tier3Available }


    public static func installActorSignalBackend(_ backend: ActorSignalBackend) {
        ModerationEngine.shared.actorSignals = ActorSignalStore(backend: backend)
    }

    public static func installConversationBufferBackend(_ backend: ConversationBufferBackend) {
        ModerationEngine.shared.buffers = ConversationBuffers(backend: backend)
    }

    public static func installConversationContextBackend(_ backend: ConversationContextBackend) {
        contextStore = ConversationContextStore(backend: backend)
    }

    public static var adjudicationSources: [String: String] = [:]

    public static func installURLReputationProvider(_ provider: URLReputationProvider) {
        URLReputation.provider = provider
    }

    public static var urlAllowlist: Set<String> {
        get { URLReputation.allowlistedHosts }
        set { URLReputation.allowlistedHosts = newValue }
    }

    public static var abuseRouterDiagnostics: AbuseRouter? {
        ModerationEngine.shared.abuseRouter
    }

    public static var lexiconsSealed: Bool {
        _ = ModerationEngine.shared   // sealing happens in the shared initialiser
        return Lex.isSealed
    }

    public static var slurTermCount: Int { SlurLexicon.termCount }

    public static func compositeRisk(senderID: String, conversationID: String = "svc") -> Double {
        ModerationEngine.shared
            .behaviouralRisk(sender: senderID, conversation: conversationID).composite
    }


    public static func decisionRecord(for request: ModerationRequestDTO) -> DecisionRecord {
        evaluated(request).verdict.decisionRecord
    }

    static func evaluated(_ request: ModerationRequestDTO,
                          persistBuffer: Bool = true)
        -> (verdict: Verdict, actor: ActorContext, text: String) {
        let engine = ModerationEngine.shared
        let actor = actorContext(from: request)
        let text = request.text ?? ""
        let verdict = request.advisory == true
            ? engine.hint(text, actor: actor)
            : engine.evaluate(text, actor: actor)

        if persistBuffer {
            remember(text, verdict: verdict, request: request, actor: actor, engine: engine)
        }
        return (verdict, actor, text)
    }

    public static func roundTrip(_ record: DecisionRecord) -> DecisionRecord {
        var restored = Verdict(restoring: record).decisionRecord
        restored.decidedAt = record.decidedAt   // re-capture stamps 'now'; the fact is the original
        restored.reDerived = record.reDerived
        return restored
    }


    public static func probeUnreachableClassifierLatencyMs(samples: Int = 25,
                                                           timeout: TimeInterval = 2.0) -> Double {
        let engine = ModerationEngine.shared
        let previous = engine.safetyClassifier
        var config = RemoteSafetyClassifier.Configuration.local(port: 9)  // discard port
        config.timeout = timeout
        engine.safetyClassifier = RemoteSafetyClassifier(configuration: config)
        defer { engine.safetyClassifier = previous }

        var worst = 0.0
        for i in 0..<samples {
            var request = ModerationRequestDTO(text: "message \(i) about the villa booking")
            request.conversationID = "probe-\(i)"
            request.senderID = "probe-sender-\(i)"
            let verdict = handle(request)
            worst = Swift.max(worst, verdict.latencyMs ?? 0)
        }
        return worst
    }

    public static var degradedClassifierCanEnforce: Bool {
        RemoteSafetyClassifier(configuration: .local()).fallbackCanEnforce
    }


    public static func exportPolicy() throws -> Data {
        try Policy.snapshot().encoded()
    }

    @discardableResult
    public static func loadPolicy(json: Data) throws -> String {
        let candidate = try Policy.Configuration.decoded(from: json)

        guard candidate.safetyActions[ModCategory.selfHarm.rawValue] == nil else {
            throw PolicyLoadError.invariantViolation(
                "selfHarm must never have an action mapping")
        }
        if let harassment = candidate.safetyActions[ModCategory.harassment.rawValue],
           harassment == ModAction.block.rawValue {
            throw PolicyLoadError.invariantViolation(
                "harassment must never be hard-blocked")
        }

        Policy.current = candidate
        return candidate.version
    }

    public enum PolicyLoadError: Error, CustomStringConvertible {
        case invariantViolation(String)

        public var description: String {
            switch self {
            case .invariantViolation(let detail):
                return "policy rejected: \(detail)"
            }
        }
    }

    public static func handle(_ signal: RecipientSignalDTO) -> RecipientSignalAckDTO {
        let engine = ModerationEngine.shared
        guard !signal.senderID.isEmpty else {
            return RecipientSignalAckDTO(id: signal.id, ok: false, error: "missing 'senderID'")
        }

        switch signal.op {
        case "report":
            engine.report(sender: signal.senderID)
            recordSignal(kind: .report, senderID: signal.senderID, id: signal.id)
        case "block":
            engine.block(sender: signal.senderID)
            recordSignal(kind: .block, senderID: signal.senderID, id: signal.id)
        default:
            return RecipientSignalAckDTO(
                id: signal.id, ok: false,
                error: "unknown op '\(signal.op)', expected 'report' or 'block'")
        }

        let risk = engine.behaviouralRisk(
            sender: signal.senderID,
            conversation: signal.conversationID ?? "svc"
        )
        var ack = RecipientSignalAckDTO(id: signal.id, ok: true)
        ack.op = signal.op
        ack.senderID = signal.senderID
        ack.receivedReports = risk.receivedReports
        ack.blockEvents = risk.blockEvents
        ack.compositeRisk = risk.composite
        ack.elevated = risk.isElevated
        return ack
    }

    public static func handle(_ context: ConversationContextDTO) -> ConversationContextAckDTO {
        let id = context.conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != "svc" else {
            return ConversationContextAckDTO(ok: false, error: "missing 'conversationID'")
        }
        contextStore.apply(
            conversationID: id,
            stage: context.stage,
            trust: context.trust,
            priorViolations: context.priorViolations
        )
        let stored = contextStore.snapshot(conversationID: id)
        return ConversationContextAckDTO(
            ok: true,
            conversationID: id,
            stage: stored?.stage,
            trust: stored?.trust,
            priorViolations: stored?.priorViolations
        )
    }

    public static func handle(_ request: ModerationRequestDTO) -> ModerationVerdictDTO {
        if request.op == "health" {
            var out = ModerationVerdictDTO(id: request.id, ok: true)
            out.reasonCodes = ["HEALTHY"]
            out.policyVersion = Policy.current.version
            return out
        }

        guard let text = request.text else {
            return ModerationVerdictDTO(id: request.id, ok: false, error: "missing 'text'")
        }
        guard text.utf8.count <= ModerationLimits.maxTextBytes else {
            return ModerationVerdictDTO(
                id: request.id, ok: false,
                error: "text exceeds \(ModerationLimits.maxTextBytes) bytes")
        }
        if request.advisory != true, !hasIdentity(request) {
            return ModerationVerdictDTO(
                id: request.id, ok: false,
                error: "missing 'conversationID' and 'senderID'")
        }

        let engine = ModerationEngine.shared
        let actor = actorContext(from: request)

        let verdict = request.advisory == true
            ? engine.hint(text, actor: actor)
            : engine.evaluate(text, actor: actor)

        remember(text, verdict: verdict, request: request, actor: actor, engine: engine)

        var out = ModerationVerdictDTO(id: request.id, ok: true)
        out.action = verdict.action.rawValue
        out.score = verdict.score
        out.categories = verdict.categories.map { $0.rawValue }.sorted()
        out.reasonCodes = verdict.reasonCodes
        out.maskedText = verdict.maskedText
        out.tierReached = verdict.tierReached
        out.latencyMs = verdict.latencyMs
        out.policyVersion = verdict.policyVersion
        out.provisionalHold = verdict.provisionalHold
        out.escalationCandidate = engine.shouldEscalate(verdict)
        attachDisplay(&out)
        return out
    }
}


public struct BootstrapReport: Codable, Equatable {
    public var adjudicator: String
    public var tier3Available: Bool
    public var lexiconsSealed: Bool
    public var slurTerms: Int
    public var policyVersion: String
    public var urlAllowlistCount: Int
    public var actorStateBackend: String
    public var decisionStore: String
    public var conversationBufferBackend: String
    public var notes: [String]
}

public enum BootstrapError: Error, CustomStringConvertible {
    case adjudicatorRequired(String)
    case redisRequired(String)

    public var description: String {
        switch self {
        case .adjudicatorRequired(let detail):
            return """
                No Tier 3 adjudicator is configured and WAYZYY_REQUIRE_TIER3 is set. \(detail)
                Refusing to start: without an adjudicator, critical-category traffic is blocked \
                (fail-closed) and cannot be judged. Configure WAYZYY_JUDGE_BASE_URL and \
                WAYZYY_JUDGE_MODEL, or provide a provider key via WAYZYY_KEYS or \
                WAYZYY_SECRETS_FILE, or set WAYZYY_TIER3=off to accept delivery-only operation \
                deliberately.
                """
        case .redisRequired(let detail):
            return """
                REDIS_URL is set but Redis is not usable: \(detail)
                Refusing to start. Falling back to in-memory actor/buffer state under a URL \
                that looks shared would silently drop cross-message detection and actor risk \
                across replicas. Fix REDIS_URL, or unset it to run a single replica in memory.
                """
        }
    }
}

extension WayzyyModerationService {

    @discardableResult
    public static func bootstrap() throws -> BootstrapReport {
        let env = ProcessInfo.processInfo.environment
        let engine = ModerationEngine.shared      // also seals the lexicons
        var notes: [String] = []

        let mode = (env["WAYZYY_TIER3"] ?? "auto").lowercased()

        if mode == "off" {
            notes.append("Tier 3 disabled by WAYZYY_TIER3=off; safety holds cannot be adjudicated.")
        } else if let raw = env["WAYZYY_JUDGE_BASE_URL"],
                  let url = URL(string: raw),
                  let model = env["WAYZYY_JUDGE_MODEL"], !model.isEmpty {
            engine.judge = RemoteJudge(configuration: RemoteJudge.Configuration(
                baseURL: url,
                model: model,
                apiKey: env["WAYZYY_JUDGE_KEY"] ?? "local"
            ))
            notes.append("Adjudicator from WAYZYY_JUDGE_BASE_URL.")
        } else if mode == "local" {
            let model = env["WAYZYY_JUDGE_MODEL"] ?? "llama3.1:8b"
            engine.judge = RemoteJudge(configuration: .ollama(model: model))
            notes.append("Adjudicator from WAYZYY_TIER3=local (\(model)).")
        } else if mode == "pooled", engine.configurePooledJudge() {
            notes.append("Pooled adjudicator across schema-compliant models.")
        } else if RemoteJudge.Configuration.fromSecrets() != nil {
            engine.configureJudgeFromSecrets()
            notes.append("Adjudicator from configured provider credentials.")
        } else {
            notes.append("No adjudicator credentials found.")
        }

        let available = engine.tier3Available
        if !available, mode != "off", env["WAYZYY_REQUIRE_TIER3"] != nil {
            throw BootstrapError.adjudicatorRequired(notes.joined(separator: " "))
        }
        if !available, mode != "off" {
            notes.append("Running without adjudication: critical-category routing will hold for review.")
        }

        if let redisURL = env["REDIS_URL"], !redisURL.isEmpty {
            do {
                let actorBackend = try RedisActorSignalBackend(redisURL: redisURL)
                let bufBackend = try RedisConversationBufferBackend(redisURL: redisURL)
                guard actorBackend.ping() else {
                    throw BootstrapError.redisRequired("PING failed")
                }
                installActorSignalBackend(actorBackend)
                installConversationBufferBackend(bufBackend)
                installConversationContextBackend(try RedisConversationContextBackend(redisURL: redisURL))
                notes.append("Actor signals and conversation buffers in Redis (PING OK) — N replicas supported.")
            } catch let error as BootstrapError {
                throw error
            } catch {
                throw BootstrapError.redisRequired("\(error)")
            }
        }

        if slurTermCount == 0 {
            notes.append("Slur set is empty; the highest-confidence profanity rule is inert.")
        }

        if let router = engine.abuseRouter {
            notes.append(String(format: "Abuse router loaded: %d weights, routes at %.2f.",
                                router.weightCount, router.threshold))
        } else {
            notes.append("No abuse router weights; unlisted abuse relies on structural signals alone.")
        }

        if let key = env["WAYZYY_OPENAI_MODERATION_KEY"] ?? SecretsStore.key("openai"),
           !key.isEmpty,
           env["WAYZYY_OPENAI_MODERATION"] != nil {
            engine.safetyClassifier = RemoteSafetyClassifier(
                configuration: .openAIModeration(
                    apiKey: key,
                    model: env["WAYZYY_OPENAI_MODERATION_MODEL"] ?? "omni-moderation-latest"))
            notes.append("OpenAI moderation installed as a routing-only secondary signal.")
        }

        if let pgConfig = PostgresDecisionStore.Configuration.fromEnvironment() {
            let store = PostgresDecisionStore(configuration: pgConfig)
            installDecisionStore(store)
            let replayed = replayRecipientSignals()
            notes.append(
                "Decisions durable in Postgres (\(pgConfig.projectURL.host ?? "supabase"));"
                + " replayed \(replayed) recipient signals.")
        } else if let path = env["WAYZYY_DECISION_LOG"], !path.isEmpty {
            do {
                installDecisionStore(try FileDecisionStore(path: path))
                let replayed = replayRecipientSignals()
                notes.append("Decisions durable at \(path); replayed \(replayed) recipient signals.")
            } catch {
                throw error
            }
        } else {
            notes.append("Decision store is in-memory; decisions do not survive a restart.")
        }

        if let hook = env["WAYZYY_WEBHOOK_URL"], !hook.isEmpty {
            OutboxDispatcher.shared.configure(url: hook, token: env["WAYZYY_WEBHOOK_TOKEN"])
            notes.append("Outbox webhook \(hook) — adjudication and decisions are pushed.")
        } else {
            notes.append("No WAYZYY_WEBHOOK_URL; clients must poll GET /v1/decision?id=.")
        }

        return BootstrapReport(
            adjudicator: engine.judge.identifier,
            tier3Available: available,
            lexiconsSealed: lexiconsSealed,
            slurTerms: slurTermCount,
            policyVersion: policyVersion,
            urlAllowlistCount: URLReputation.allowlistCount,
            actorStateBackend: String(describing: type(of: engine.actorSignals.backendForDiagnostics)),
            decisionStore: String(describing: type(of: decisionStore)),
            conversationBufferBackend:
                String(describing: type(of: engine.buffers.backendForDiagnostics)),
            notes: notes
        )
    }
}


extension WayzyyModerationService {

    private static let storeLock = NSLock()
    private static var _decisionStore: DecisionStore = InMemoryDecisionStore()
    private static let contextLock = NSLock()
    private static var _contextStore = ConversationContextStore()

    public static var decisionStore: DecisionStore {
        get { storeLock.lock(); defer { storeLock.unlock() }; return _decisionStore }
        set { storeLock.lock(); _decisionStore = newValue; storeLock.unlock() }
    }

    static var contextStore: ConversationContextStore {
        get { contextLock.lock(); defer { contextLock.unlock() }; return _contextStore }
        set { contextLock.lock(); _contextStore = newValue; contextLock.unlock() }
    }

    public static func installDecisionStore(_ store: DecisionStore) {
        decisionStore = store
    }

    public static var committedDecisionCount: Int { decisionStore.committedDecisions }

    private static let idempotencyLocks = KeyedLock()

    public static func handleDurably(_ request: ModerationRequestDTO) throws -> ModerationVerdictDTO {
        guard request.op == nil || request.op == "evaluate" else {
            return handle(request)
        }
        if request.advisory == true { return handle(request) }
        if !hasIdentity(request) {
            return ModerationVerdictDTO(
                id: request.id, ok: false,
                error: "missing 'conversationID' and 'senderID'")
        }

        let store = decisionStore
        let key = request.id ?? UUID().uuidString

        return try idempotencyLocks.with(key) {
            if let existing = store.decision(forRequestID: key), !existing.decision.isReservation {
                var out = verdictDTO(restoring: existing.decision)
                out.id = key
                out.idempotentReplay = true
                return out
            }

            let placeholder = DecisionEnvelope(
                requestID: key,
                conversationID: request.conversationID ?? "",
                senderID: request.senderID ?? "",
                decision: .reservation()
            )
            let claim = try store.reserve(placeholder)
            if !claim.acquired {
                if claim.envelope.decision.isReservation {
                    if let ready = waitForFinalDecision(requestID: key, store: store) {
                        var out = verdictDTO(restoring: ready.decision)
                        out.id = key
                        out.idempotentReplay = true
                        return out
                    }
                    throw DecisionStoreError.notWritable("reservation still pending")
                }
                var out = verdictDTO(restoring: claim.envelope.decision)
                out.id = key
                out.idempotentReplay = true
                return out
            }

            let (verdict, actor, text) = evaluated(request, persistBuffer: false)
            let record = verdict.decisionRecord
            let envelope = DecisionEnvelope(
                requestID: key,
                conversationID: request.conversationID ?? "",
                senderID: request.senderID ?? "",
                decision: record
            )
            let stored = try store.finalize(
                envelope,
                event: OutboxEvent(id: key, requestID: key, kind: .decision, subject: record.action)
            )
            let won = stored.decision.action == record.action
                && stored.decision.score == record.score
                && !stored.decision.isReservation
            if won {
                remember(text, verdict: verdict, request: request, actor: actor,
                         engine: ModerationEngine.shared)
            }
            OutboxDispatcher.shared.kick()

            let adjudicating = won && scheduleAdjudication(
                requestID: key, text: text, actor: actor, verdict: verdict)

            var out = verdictDTO(restoring: stored.decision)
            out.id = key
            out.idempotentReplay = !won
            out.escalationCandidate = adjudicating
            return out
        }
    }

    private static func waitForFinalDecision(requestID: String, store: DecisionStore) -> DecisionEnvelope? {
        for _ in 0..<40 {
            if let envelope = store.decision(forRequestID: requestID),
               !envelope.decision.isReservation {
                return envelope
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if let envelope = store.decision(forRequestID: requestID),
           !envelope.decision.isReservation {
            return envelope
        }
        return nil
    }

    static func hasIdentity(_ request: ModerationRequestDTO) -> Bool {
        let convo = request.conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sender = request.senderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !convo.isEmpty && !sender.isEmpty && convo != "svc" && sender != "svc"
    }

    static func actorContext(from request: ModerationRequestDTO) -> ActorContext {
        let sender = request.senderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let convo = request.conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let engine = ModerationEngine.shared
        if let claimed = request.priorViolations, claimed > 0, !sender.isEmpty, sender != "svc" {
            engine.notePlatformPriors(sender: sender, count: claimed)
        }
        let risk = engine.behaviouralRisk(
            sender: sender.isEmpty ? "svc" : sender,
            conversation: convo.isEmpty ? "svc" : convo
        )
        let stored = engine.platformPriors(sender: sender)
        let ctx = convo.isEmpty || convo == "svc" ? nil : contextStore.snapshot(conversationID: convo)
        let storedPriors = risk.receivedReports + risk.blockEvents
        let priors = max(request.priorViolations ?? 0,
                         max(ctx?.priorViolations ?? 0, max(stored, storedPriors)))
        var trust = TrustTier.parse(ctx?.trust ?? request.trust)
        if risk.isElevated, trust == .trusted { trust = .standard }
        if storedPriors > 0, trust == .trusted { trust = .standard }
        return ActorContext(
            trust: trust,
            stage: BookingStage.parse(ctx?.stage),
            priorViolations: priors,
            conversationID: convo.isEmpty ? "svc" : convo,
            senderID: sender.isEmpty ? "svc" : sender
        )
    }

    static func remember(_ text: String,
                         verdict: Verdict,
                         request: ModerationRequestDTO,
                         actor: ActorContext,
                         engine: ModerationEngine) {
        guard request.advisory != true,
              !verdict.action.withholdsMessage,
              request.conversationID?.isEmpty == false,
              request.senderID?.isEmpty == false
        else { return }
        engine.remember(text, actor: actor)
    }

    static func verdictDTO(restoring record: DecisionRecord) -> ModerationVerdictDTO {
        var out = ModerationVerdictDTO(ok: true)
        out.action = record.action
        out.score = record.score
        out.categories = record.categories
        out.reasonCodes = record.reasonCodes
        out.maskedText = record.maskedText
        out.tierReached = record.tierReached
        out.latencyMs = record.latencyMs
        out.policyVersion = record.policyVersion
        out.provisionalHold = record.provisionalHold
        attachDisplay(&out)
        return out
    }

    static func attachDisplay(_ out: inout ModerationVerdictDTO) {
        out.displayAction = out.action
        switch out.action {
        case "mask":
            out.displayText = out.maskedText
        case "allow", "hint":
            out.displayText = nil
        default:
            out.displayText = nil
        }
    }

    static func recordSignal(kind: OutboxEvent.Kind, senderID: String, id: String?) {
        try? decisionStore.commit(event: OutboxEvent(
            requestID: id ?? UUID().uuidString, kind: kind, subject: senderID))
        OutboxDispatcher.shared.kick()
    }

    @discardableResult
    public static func replayRecipientSignals(window: TimeInterval = 24 * 3600) -> Int {
        let engine = ModerationEngine.shared
        let cutoff = Date().addingTimeInterval(-window)
        var replayed = 0
        for event in decisionStore.events(since: cutoff) {
            switch event.kind {
            case .report:
                engine.report(sender: event.subject, at: event.occurredAt)
                replayed += 1
            case .block:
                engine.block(sender: event.subject, at: event.occurredAt)
                replayed += 1
            case .decision, .adjudication:
                continue
            }
        }
        return replayed
    }
}


import Foundation

public struct AdjudicationOutcome: Codable, Equatable {
    public var requestID: String
    public var priorAction: String
    public var action: String
    public var changed: Bool
    public var judgement: String
    public var confidence: Double
    public var rationale: String
    public var source: String
    public var latencyMs: Double
}

extension WayzyyModerationService {

    static let adjudicationSuffix = "#t3"

    private static let adjudicationLock = NSLock()
    private static var _inFlight = 0
    private static var _completed = 0
    private static var _changed = 0
    private static var _dropped = 0
    private static var _enabled = true
    private static let group = DispatchGroup()

    public static var maxConcurrentAdjudications = 3
    public static var pendingAdjudicationLimit = 2_048

    private static var _pending: [(requestID: String, text: String, actor: ActorContext, verdict: Verdict)] = []

    public static var adjudicationEnabled: Bool {
        get { adjudicationLock.lock(); defer { adjudicationLock.unlock() }; return _enabled }
        set { adjudicationLock.lock(); _enabled = newValue; adjudicationLock.unlock() }
    }

    public struct AdjudicationStats: Codable, Equatable {
        public var inFlight: Int
        public var completed: Int
        public var changed: Int
        public var dropped: Int
    }

    public static var adjudicationStats: AdjudicationStats {
        adjudicationLock.lock()
        defer { adjudicationLock.unlock() }
        return AdjudicationStats(inFlight: _inFlight, completed: _completed,
                                 changed: _changed, dropped: _dropped)
    }


    private static func dequeueAdjudication() -> (String, String, ActorContext, Verdict)? {
        adjudicationLock.lock()
        defer { adjudicationLock.unlock() }
        guard _inFlight < maxConcurrentAdjudications, !_pending.isEmpty else { return nil }
        _inFlight += 1
        return _pending.removeFirst()
    }

    private static func enqueueAdjudication(_ job: (String, String, ActorContext, Verdict)) -> Bool {
        adjudicationLock.lock()
        defer { adjudicationLock.unlock() }
        if _pending.count >= pendingAdjudicationLimit {
            _dropped += 1
            return false
        }
        _pending.append(job)
        group.enter()
        return true
    }

    private static func releaseAdjudicationSlot() {
        adjudicationLock.lock()
        _inFlight -= 1
        adjudicationLock.unlock()
    }

    private static func recordAdjudicationCompleted(changed: Bool) {
        adjudicationLock.lock()
        _completed += 1
        if changed { _changed += 1 }
        adjudicationLock.unlock()
    }

    @discardableResult
    // Queues escalated verdicts for asynchronous re-evaluation by the Tier 3 LLM adjudicator
    static func scheduleAdjudication(requestID: String,
                                     text: String,
                                     actor: ActorContext,
                                     verdict: Verdict) -> Bool {
        let engine = ModerationEngine.shared
        guard adjudicationEnabled,
              engine.tier3Available,
              engine.shouldEscalate(verdict)
        else { return false }

        guard enqueueAdjudication((requestID, text, actor, verdict)) else { return false }
        pumpAdjudications()
        return true
    }

    private static func pumpAdjudications() {
        while let job = dequeueAdjudication() {
            let store = decisionStore
            let engine = ModerationEngine.shared
            Task.detached(priority: .utility) {
                defer {
                    releaseAdjudicationSlot()
                    group.leave()
                    pumpAdjudications()
                }

                    // Executes the LLM call to get a second opinion on structurally suspicious messages
                guard let (revised, judgement) = await engine.escalate(
                    verdict: job.3, message: job.1, actor: job.2
                ) else { return }

                let outcome = AdjudicationOutcome(
                    requestID: job.0,
                    priorAction: job.3.action.rawValue,
                    action: revised.action.rawValue,
                    changed: revised.action != job.3.action,
                    judgement: judgement.decision.rawValue,
                    confidence: judgement.confidence,
                    rationale: judgement.rationale,
                    source: judgement.source,
                    latencyMs: judgement.latencyMs
                )
                
                adjudicationSources[job.0] = judgement.source

                recordAdjudicationCompleted(changed: outcome.changed)

                // Persists the final adjudicated decision envelope to the backing store for later auditing
                try? store.commit(
                    DecisionEnvelope(
                        requestID: job.0 + adjudicationSuffix,
                        conversationID: job.2.conversationID,
                        senderID: job.2.senderID,
                        decision: revised.decisionRecord
                    ),
                    event: OutboxEvent(
                        requestID: job.0,
                        kind: .adjudication,
                        subject: outcome.changed ? revised.action.rawValue : "unchanged"
                    )
                )
                OutboxDispatcher.shared.kick()
            }
        }
    }

    public static func simulateAdjudication(text: String,
                                            category: String,
                                            confidence: Double = 1.0,
                                            decision: String = "safety_violation") -> String {
        simulateAdjudicationRecord(text: text, category: category,
                                   confidence: confidence, decision: decision).action
    }

    public static func simulateAdjudicationRecord(text: String,
                                                  category: String,
                                                  confidence: Double = 1.0,
                                                  decision: String = "safety_violation") -> DecisionRecord {
        let engine = ModerationEngine.shared
        let actor = ActorContext(conversationID: "simulate", senderID: "simulate")
        let verdict = engine.evaluate(text, actor: actor, useConversationBuffer: false)
        let judgement = JudgeVerdict(
            decision: JudgeVerdict.Decision(rawValue: decision) ?? .safetyViolation,
            confidence: confidence,
            rationale: "simulated adjudication",
            intent: nil,
            safetyCategory: ModCategory(rawValue: category),
            source: "simulated",
            latencyMs: 0
        )
        return engine.applyJudgement(judgement, to: verdict, message: text, actor: actor)
            .decisionRecord
    }

    @discardableResult
    public static func drainAdjudications(timeout: TimeInterval = 30) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    public static func adjudication(forRequestID requestID: String) -> ModerationVerdictDTO? {
        guard let envelope = decisionStore
            .decision(forRequestID: requestID + adjudicationSuffix) else { return nil }
        var out = verdictDTO(restoring: envelope.decision)
        out.id = requestID
        return out
    }

    public struct DecisionStatusDTO: Codable {
        public var id: String
        public var ok: Bool
        public var found: Bool
        public var display: ClientDisplayDTO?
        public var audit: ModerationVerdictDTO?
        public var adjudication: ModerationVerdictDTO?
        public var superseded: Bool
    }

    public struct ClientDisplayDTO: Codable {
        public var action: String?
        public var text: String?
    }

    public static func status(forRequestID requestID: String) -> DecisionStatusDTO {
        let original = decisionStore.decision(forRequestID: requestID)
        let decided = original.flatMap { $0.decision.isReservation ? nil : $0 }
        let revised = adjudication(forRequestID: requestID)
        let effective = revised ?? decided.map { verdictDTO(restoring: $0.decision) }
        var display: ClientDisplayDTO?
        if let effective {
            display = ClientDisplayDTO(
                action: effective.displayAction ?? effective.action,
                text: effective.displayText ?? (effective.action == "mask" ? effective.maskedText : nil)
            )
        }
        return DecisionStatusDTO(
            id: requestID,
            ok: true,
            found: decided != nil,
            display: display,
            audit: decided.map { verdictDTO(restoring: $0.decision) },
            adjudication: revised,
            superseded: decided != nil && revised != nil
                && decided?.decision.action != revised?.action
        )
    }
}
