// The public service contract.
//
// Everything else in this module is internal on purpose. A service boundary should expose a
// deliberate, versioned contract rather than the engine's internals — otherwise the wire
// format drifts with every refactor and consumers couple to details they should not see.
//
// This is also the seam that makes the engine portable: any transport (HTTP, gRPC, queue
// consumer, Lambda) only needs these two DTOs and one function.

import Foundation

// MARK: - Request

public struct ModerationRequestDTO: Codable, Sendable {
    public var id: String?
    /// `nil` or `"evaluate"` to judge a message; `"health"` for a liveness probe.
    public var op: String?
    public var text: String?
    public var conversationID: String?
    public var senderID: String?
    /// Set by the platform backend from account data, never by the phone.
    /// A patched client sending `trusted` cannot loosen policy: elevated senders are clamped.
    /// Prefer `POST /v1/context` so replicas share the same trust. `fresh` | `standard` | `trusted`.
    /// Aliases: `new` → fresh, `established` → trusted.
    public var trust: String?
    /// Set by the platform via `POST /v1/context`, never by the phone.
    /// Ignored on `/v1/moderate` so a patched client cannot pick `checkedIn`.
    /// `inquiry` | `booked` | `checkedIn`. Aliases: `staying` / `completed` → checkedIn.
    public var stage: String?
    /// Set by the platform backend. The engine takes max(this, stored reports+blocks)
    /// so a client cannot reset the counter to zero.
    public var priorViolations: Int?
    /// Typing-hint mode. Advisory verdicts are clamped and can never enforce.
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

// MARK: - Recipient signal

/// A recipient reporting or blocking a sender. Separate from `ModerationRequestDTO` because
/// it carries no message and produces no verdict — it is evidence, not a judgement.
public struct RecipientSignalDTO: Codable, Sendable {
    public var id: String?
    /// `report` or `block`.
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
    /// Counters after the signal was applied, so callers can see it landed.
    public var receivedReports: Int?
    public var blockEvents: Int?
    public var compositeRisk: Double?
    public var elevated: Bool?
    public var error: String?

    public init(id: String? = nil, ok: Bool, error: String? = nil) {
        self.id = id; self.ok = ok; self.error = error
    }
}

// MARK: - Response

public struct ModerationVerdictDTO: Codable, Sendable {
    public var id: String?
    public var ok: Bool
    /// `allow`, `hint`, `mask`, `warn`, `review`, `block`.
    public var action: String?
    public var score: Double?
    public var categories: [String]?
    public var reasonCodes: [String]?
    public var maskedText: String?
    public var tierReached: Int?
    public var latencyMs: Double?
    public var policyVersion: String?
    public var provisionalHold: Bool?
    /// True when the message would be sent to Tier 3 for adjudication.
    public var escalationCandidate: Bool?
    /// True when this response is the previously stored decision for a repeated request id,
    /// rather than a fresh evaluation. A retry must not be able to change an outcome.
    public var idempotentReplay: Bool?
    public var error: String?
    /// Chat UI only: action to apply and text to show. Never send `categories` / `reasonCodes` to the other party.
    public var displayAction: String?
    public var displayText: String?

    public init(id: String? = nil, ok: Bool, error: String? = nil) {
        self.id = id; self.ok = ok; self.error = error
    }
}

// MARK: - Limits
//
// A service needs bounds the app never did. A 29,400-character input measured 169 ms
// on-device: tolerable for one user, unacceptable when it occupies a shared worker.

public enum ModerationLimits {
    public static let maxTextBytes = 8_192
    public static let maxRequestBytes = 32_768
}

// MARK: - Facade

public enum WayzyyModerationService {

    public static var policyVersion: String { Policy.current.version }

    /// Whether a real Tier 3 adjudicator is reachable. Exposed for health reporting and so
    /// the fail-closed guarantee can be asserted rather than assumed.
    public static var tier3Available: Bool { ModerationEngine.shared.tier3Available }

    // MARK: - Deployment seams
    //
    // The two pieces of state that cannot stay in-process once there is more than one replica,
    // and the one signal that has to come from outside because it changes hourly.

    /// Move actor signals to a shared store. Without this, each replica sees only its own share
    /// of a sender's 24-hour history, which multiplies every escalation threshold by the replica
    /// count and hides a recipient's report from the next pod that sender reaches.
    public static func installActorSignalBackend(_ backend: ActorSignalBackend) {
        ModerationEngine.shared.actorSignals = ActorSignalStore(backend: backend)
    }

    /// Move conversation buffers to a shared store.
    ///
    /// More urgent than the actor store behind a load balancer: these buffers exist to catch
    /// attacks split across messages, so per-replica buffers lose exactly the attacks they were
    /// added for. Four drip-fed fragments across four pods leave no pod holding more than one.
    public static func installConversationBufferBackend(_ backend: ConversationBufferBackend) {
        ModerationEngine.shared.buffers = ConversationBuffers(backend: backend)
    }

    public static func installConversationContextBackend(_ backend: ConversationContextBackend) {
        contextStore = ConversationContextStore(backend: backend)
    }

    /// Install a host reputation source. Reputation may raise suspicion and never lower it, so
    /// this cannot be used to switch off contact-exfiltration rules.
    public static func installURLReputationProvider(_ provider: URLReputationProvider) {
        URLReputation.provider = provider
    }

    /// Hosts this deployment treats as its own — the only de-escalation path, and deliberately
    /// operator-owned rather than vendor-owned.
    public static var urlAllowlist: Set<String> {
        get { URLReputation.allowlistedHosts }
        set { URLReputation.allowlistedHosts = newValue }
    }

    /// The learned router, when weights were found. Exposed so a deployment can confirm the
    /// model actually loaded — a missing file degrades silently to the previous behaviour, which
    /// is the right default and the wrong thing to discover by accident.
    public static var abuseRouterDiagnostics: AbuseRouter? {
        ModerationEngine.shared.abuseRouter
    }

    /// Whether the safety phrase lists are final. They are read without synchronisation on
    /// every evaluation, so a deployment should confirm this before accepting traffic.
    public static var lexiconsSealed: Bool {
        _ = ModerationEngine.shared   // sealing happens in the shared initialiser
        return Lex.isSealed
    }

    /// Size of the active slur set. An empty set silently disables the highest-confidence
    /// rule in the engine, so it is worth asserting rather than assuming.
    public static var slurTermCount: Int { SlurLexicon.termCount }

    /// Read-only behavioural risk lookup. Unlike `handle(_ signal:)` this records nothing, so
    /// it is safe for health endpoints and for asserting that other operations are inert.
    public static func compositeRisk(senderID: String, conversationID: String = "svc") -> Double {
        ModerationEngine.shared
            .behaviouralRisk(sender: senderID, conversation: conversationID).composite
    }

    // MARK: - Durable decisions
    //
    // A verdict is a historical fact, not a recomputable opinion. Callers persist the record
    // and restore it; they must never re-run the engine to recover a past decision, because
    // that re-decides under today's policy instead of the one that applied.

    /// Evaluate and return a durable record of the decision, suitable for storage.
    public static func decisionRecord(for request: ModerationRequestDTO) -> DecisionRecord {
        evaluated(request).verdict.decisionRecord
    }

    /// One evaluation, with the pieces callers need afterwards.
    ///
    /// Adjudication needs the verdict, the message and the actor — not just the record — so a
    /// single entry point produces all three. Re-deriving them later would mean evaluating
    /// twice and risking two different answers for one message.
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

    /// Restore a stored decision and re-capture it. Round-tripping is the identity function on
    /// every enforcement-relevant field, which is what makes a stored decision trustworthy.
    public static func roundTrip(_ record: DecisionRecord) -> DecisionRecord {
        var restored = Verdict(restoring: record).decisionRecord
        restored.decidedAt = record.decidedAt   // re-capture stamps 'now'; the fact is the original
        restored.reDerived = record.reDerived
        return restored
    }

    // MARK: - Dependency probes
    //
    // Layer 3 sits on the synchronous write path, so the cost of a *failed* dependency is a
    // property worth measuring rather than assuming. These exist so readiness checks and the
    // invariant gate can assert the write path stays fast when the classifier endpoint is
    // unreachable, instead of discovering it under load.

    /// Worst-case synchronous latency of a full evaluation while the remote classifier
    /// endpoint is unreachable, in milliseconds.
    ///
    /// Installs a classifier pointed at a black-hole port, measures, then restores the
    /// previous classifier. The result should be far below `timeout`, because a cache miss
    /// returns local scores immediately and refreshes in the background.
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

    /// Whether the classifier that serves cache misses and outages may enforce.
    /// Always false by construction; exposed so that can be asserted.
    public static var degradedClassifierCanEnforce: Bool {
        RemoteSafetyClassifier(configuration: .local()).fallbackCanEnforce
    }

    // MARK: - Policy rollout
    //
    // A service needs to change thresholds and action tables without a redeploy, and needs
    // to be able to roll back. Configuration is a value type and every evaluation takes one
    // immutable snapshot at request entry, so a rollout applied here can never tear a
    // verdict in flight: an evaluation already running completes against the version it
    // started with.

    /// Serialise the active policy, for audit or rollback.
    public static func exportPolicy() throws -> Data {
        try Policy.snapshot().encoded()
    }

    /// Install a policy configuration. Returns the version now active.
    ///
    /// Rejects a configuration that would violate an invariant, because a policy file is
    /// exactly the vector by which someone could otherwise make self-harm blockable.
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

    /// Apply a recipient signal — a report or a block.
    ///
    /// Returns the resulting counters so a caller can confirm the signal landed rather than
    /// assuming it did. These signals do not produce a verdict and cannot enforce on their
    /// own: they raise the evidence available to the next evaluation.
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

    /// Booking stage (and optional trust/priors) from the platform's booking/user tables.
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

    /// Stateless with respect to the caller: every field the verdict depends on arrives in
    /// the request. Conversation and actor state are keyed by the supplied identifiers, so
    /// the same request always produces the same verdict for the same state.
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

// MARK: - Startup
//
// Everything in this file above this point assumes the process has been wired up. This is the
// wiring, and it exists because the default configuration is safe for a test and wrong for a
// deployment.
//
// The specific hazard: with no adjudicator installed, `tier3Available` is false, and the
// fail-closed rule raises safety-shaped content in the critical categories to `review` rather
// than delivering it. That is the correct choice for a single message and a disaster as a
// steady state, because `review` is a hold and there is no human review tier to drain it. A pod
// that starts without an adjudicator does not fail loudly; it quietly converts a fraction of
// real traffic into messages nobody will ever see.
//
// So startup is explicit, it reports exactly what it wired, and it can be told to refuse to
// start rather than serve in that condition.

/// What the process wired up, for logging and for a readiness check.
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

    /// Wire the process from the environment and report what was installed.
    ///
    /// Recognised variables:
    ///
    /// * `WAYZYY_JUDGE_BASE_URL`, `WAYZYY_JUDGE_MODEL`, `WAYZYY_JUDGE_KEY` — any
    ///   OpenAI-compatible endpoint. Checked first, so a deployment can point at a sidecar or a
    ///   self-hosted model without code changes.
    /// * `WAYZYY_TIER3` — `auto` (default), `local`, `pooled`, or `off`.
    /// * `WAYZYY_REQUIRE_TIER3` — when set, startup throws instead of serving without an
    ///   adjudicator.
    /// * `WAYZYY_KEYS`, `WAYZYY_SECRETS_FILE` — provider credentials.
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
            // Not fatal by default — a single-tenant or staging deployment may genuinely want
            // this — but it must never be silent.
            notes.append("Running without adjudication: critical-category routing will hold for review.")
        }

        // Deployment seams: shared actor signals and conversation buffers.
        // Without these, each replica holds its own state; behavioural history fragments
        // across pods and cross-message detection stops working.
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

        // Optional secondary routing signal. Opt-in, because it sends message text to a third
        // party — a decision an operator should make explicitly rather than inherit from a
        // default. It cannot enforce, so losing it costs routing recall and nothing else.
        if let key = env["WAYZYY_OPENAI_MODERATION_KEY"] ?? SecretsStore.key("openai"),
           !key.isEmpty,
           env["WAYZYY_OPENAI_MODERATION"] != nil {
            engine.safetyClassifier = RemoteSafetyClassifier(
                configuration: .openAIModeration(
                    apiKey: key,
                    model: env["WAYZYY_OPENAI_MODERATION_MODEL"] ?? "omni-moderation-latest"))
            notes.append("OpenAI moderation installed as a routing-only secondary signal.")
        }

        // Durable decisions. Postgres wins when both are configured: the file log is a
        // single-writer store and cannot survive a rolling deploy with 2+ replicas. The
        // Dockerfile still sets WAYZYY_DECISION_LOG as a local fallback for single-node runs.
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

// MARK: - Durable decisions and the outbox

extension WayzyyModerationService {

    private static let storeLock = NSLock()
    private static var _decisionStore: DecisionStore = InMemoryDecisionStore()
    private static let contextLock = NSLock()
    private static var _contextStore = ConversationContextStore()

    /// Where decisions are written. Defaults to memory, which is right for the app and for
    /// tests and wrong for a deployment — so startup reports which one is installed.
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

    /// Number of decisions the active store holds. For readiness reporting.
    public static var committedDecisionCount: Int { decisionStore.committedDecisions }

    /// Evaluate and persist, returning the stored decision unchanged on a retry.
    ///
    /// A client that retries after a timeout must get the decision that was already made. Any
    /// other behaviour means a retry can change an outcome, which turns a network hiccup into
    /// an enforcement difference and makes the audit trail ambiguous about which verdict
    /// actually applied to the message.
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

    /// Feed the conversation buffer.
    ///
    /// Without this, cross-message detection cannot work at all through the service: the
    /// assembly logic reads a window of previous messages and nothing else on this path writes
    /// to it. Three exclusions, each for a different reason:
    ///
    /// * **Advisory calls.** A preview of a message that has not been sent. Buffering it would
    ///   let a sender assemble an attack out of drafts they never delivered.
    /// * **Withheld messages.** Never reached the recipient, so the exfiltration did not
    ///   progress. Keeping the fragment would also let a blocked message contribute to
    ///   actioning a later innocent one.
    /// * **Requests with no conversation identity.** The buffer is keyed by conversation and
    ///   sender. A caller that omits both would share one buffer with every other such caller,
    ///   so fragments from unrelated people would assemble into evidence nobody produced —
    ///   the one thing cross-message detection must never do.
    static func hasIdentity(_ request: ModerationRequestDTO) -> Bool {
        let convo = request.conversationID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sender = request.senderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !convo.isEmpty && !sender.isEmpty && convo != "svc" && sender != "svc"
    }

    /// Trust and prior-violation fields on the request are hints from the platform backend,
    /// never from a phone. Stage is taken only from `POST /v1/context` (booking row), defaulting
    /// to `inquiry`. Priors are max(request, stored reports+blocks, replicated platform floor).
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

    /// Render a stored decision as a response. Pure translation — no policy read, no
    /// re-evaluation — so a replayed decision is the original one, not today's opinion of it.
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

    /// The only fields a chat client should render. Categories and reason codes stay on the
    /// backend so the other party never learns *why* a span was removed.
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
        // A report or block has already been applied in memory by the time this runs; the
        // event is what makes it survive a restart. Failing to record it must not discard the
        // signal, because the recipient's evidence is more valuable than the log line.
        try? decisionStore.commit(event: OutboxEvent(
            requestID: id ?? UUID().uuidString, kind: kind, subject: senderID))
        OutboxDispatcher.shared.kick()
    }

    /// Rebuild behavioural state from the event log after a restart.
    ///
    /// Reports and blocks are the only label source in a design with no human review tier, so
    /// losing them on every deploy would reset every repeat offender to a clean slate. The
    /// window matches the actor store's own retention: older evidence has already expired and
    /// replaying it would resurrect signals the policy considers stale.
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
                // Decisions and their revisions are facts about messages, not behavioural
                // signals. Replaying them would re-derive risk the signals already carry.
                continue
            }
        }
        return replayed
    }
}

// MARK: - Asynchronous Tier 3 adjudication
//
// The gap this closes
// ───────────────────
// Tiers 1 and 2 recognise abuse they have seen the shape of before: listed phrases, and text
// close enough to a labelled exemplar. Neither generalises to an insult invented this morning.
// What they *do* produce for such a message is a suspicion — `personDirectedAnomaly` on
// second-person degradation aimed at a person rather than a property — and a routing score.
// That is the system saying "something is wrong here and I cannot name it".
//
// Answering that question needs something that reads meaning, which is Tier 3. Without this
// file the service marked those messages as escalation candidates and then dropped them: the
// adjudicator was reachable and never asked.
//
// Why asynchronous
// ────────────────
// A judgement costs roughly a second. Putting that on the send path would gate ordinary
// conversation — "what time is check-in?" behind a one-second model call — which is the exact
// cost this architecture exists to avoid. So the deterministic verdict is returned immediately
// and the adjudication follows, arriving as an outbox event the platform acts on. For the
// critical categories the provisional-hold path already withholds the message first, so those
// are judged before anyone reads them; everything else is judged after delivery, which is the
// honest trade for keeping chat fast.
//
// Three properties this deliberately preserves
// ────────────────────────────────────────────
// **The adjudicator cannot exceed policy.** A safety finding it produces is fed back through
// `Policy.decide` rather than applied directly, so every category ceiling still holds: it can
// raise harassment to a warning, and it cannot make harassment blockable or self-harm
// enforceable no matter how confident it is.
//
// **History is appended, never rewritten.** The revision is stored as its own record beside
// the original, and the original remains what `decision(forRequestID:)` returns. A retry
// therefore still gets the decision that actually applied to the message when it was sent —
// a later judgement is new information, not a retroactive edit of what happened.
//
// **Overload degrades to silence, not to a queue.** Beyond a fixed number of in-flight
// judgements, adjudication is skipped and counted. The message already has a valid
// deterministic verdict; adjudication improves it. An unbounded queue under load would trade a
// bounded quality loss for an unbounded memory one.

import Foundation

/// The outcome of judging an already-delivered message.
public struct AdjudicationOutcome: Codable, Equatable {
    public var requestID: String
    /// What was returned to the caller at send time.
    public var priorAction: String
    /// What the adjudicator, constrained by policy, concluded.
    public var action: String
    /// True when the action changed — the only case the platform must act on.
    public var changed: Bool
    public var judgement: String
    public var confidence: Double
    public var rationale: String
    public var source: String
    public var latencyMs: Double
}

extension WayzyyModerationService {

    /// Suffix distinguishing a revision from the original in the same log.
    static let adjudicationSuffix = "#t3"

    private static let adjudicationLock = NSLock()
    private static var _inFlight = 0
    private static var _completed = 0
    private static var _changed = 0
    private static var _dropped = 0
    private static var _enabled = true
    private static let group = DispatchGroup()

    /// Ceiling on concurrent judgements. Excess work waits in `pendingAdjudicationLimit`
    /// rather than being dropped.
    public static var maxConcurrentAdjudications = 3
    public static var pendingAdjudicationLimit = 2_048

    private static var _pending: [(requestID: String, text: String, actor: ActorContext, verdict: Verdict)] = []

    /// Turn adjudication off without removing the adjudicator — useful for load testing the
    /// deterministic path in isolation.
    public static var adjudicationEnabled: Bool {
        get { adjudicationLock.lock(); defer { adjudicationLock.unlock() }; return _enabled }
        set { adjudicationLock.lock(); _enabled = newValue; adjudicationLock.unlock() }
    }

    public struct AdjudicationStats: Codable, Equatable {
        public var inFlight: Int
        public var completed: Int
        /// Judgements that changed the action. These are the ones that mattered.
        public var changed: Int
        /// Skipped only when the pending queue is saturated.
        public var dropped: Int
    }

    public static var adjudicationStats: AdjudicationStats {
        adjudicationLock.lock()
        defer { adjudicationLock.unlock() }
        return AdjudicationStats(inFlight: _inFlight, completed: _completed,
                                 changed: _changed, dropped: _dropped)
    }

    // Counter mutation lives in synchronous helpers rather than inline in the task. Taking a
    // lock directly inside an async function is unsound — the continuation can resume on a
    // different thread than the one holding it — and is an error under the Swift 6 language
    // mode. A synchronous call cannot suspend, so it cannot be split across threads.

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

    /// Schedule a judgement for a message that has already been answered.
    ///
    /// Returns true when the job was accepted (running or queued). False only when the
    /// adjudicator is off or the pending queue is saturated.
    @discardableResult
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

                recordAdjudicationCompleted(changed: outcome.changed)

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

    /// Apply a synthetic judgement to a message and return the resulting action.
    ///
    /// The adjudicator is the newest thing in the system with any influence over enforcement,
    /// and it is the only component whose behaviour this codebase does not control — it is a
    /// third-party model reading free text. So "can a confident adjudicator exceed a category
    /// ceiling?" needs to be answerable by assertion rather than by reading `revise` and
    /// concluding that it probably cannot. This exists so a deployment can verify it directly,
    /// with no network and no model.
    ///
    /// - Parameters:
    ///   - category: the safety category the adjudicator claims, as a raw value.
    ///   - confidence: deliberately unclamped, so a caller can try 1.0 and beyond.
    public static func simulateAdjudication(text: String,
                                            category: String,
                                            confidence: Double = 1.0,
                                            decision: String = "safety_violation") -> String {
        simulateAdjudicationRecord(text: text, category: category,
                                   confidence: confidence, decision: decision).action
    }

    /// As `simulateAdjudication`, returning the whole record so its attribution can be checked.
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

    /// Wait for in-flight judgements to finish. For shutdown and for tests; a request path
    /// must never call this, since waiting is the thing asynchronous adjudication avoids.
    @discardableResult
    public static func drainAdjudications(timeout: TimeInterval = 30) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }

    /// The adjudication of a request, if one has been recorded.
    public static func adjudication(forRequestID requestID: String) -> ModerationVerdictDTO? {
        guard let envelope = decisionStore
            .decision(forRequestID: requestID + adjudicationSuffix) else { return nil }
        var out = verdictDTO(restoring: envelope.decision)
        out.id = requestID
        return out
    }

    /// Everything known about a request: the decision that applied when the message was sent,
    /// and the later judgement if there is one. Separate fields rather than one merged verdict,
    /// because a caller needs to know which of the two it is looking at.
    public struct DecisionStatusDTO: Codable {
        public var id: String
        public var ok: Bool
        public var found: Bool
        /// Persist / show this in chat. No categories or reason codes.
        public var display: ClientDisplayDTO?
        /// Backend-only. Do not forward to either chat participant.
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
