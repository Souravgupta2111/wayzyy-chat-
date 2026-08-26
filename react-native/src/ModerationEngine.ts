import { ModCategory, Detection, ModAction, Verdict, ActorContext, cleanVerdict, defaultActorContext, isContactExfiltration, newId } from './ModerationTypes';
import { CharView, Canonicalizer } from './Canonicalizer';
import { Extractors } from './Extractors';
import { NumericContext } from './NumericContext';
import { PositionalChannels } from './PositionalChannels';
import { ActorSignalStore, ActorRisk } from './ActorSignals';
import { ConversationBuffers } from './ConversationBuffers';
import { SafetyRules, Finding } from './SafetyRules';
import { DetectionCascade } from './DetectionCascade';
import { CrossMessageAssembler } from './CrossMessageAssembler';
import { SafetyPassEvaluator } from './SafetyPassEvaluator';
import { SafetyClassifier, SafetyClassifierInput, SignalDerivedSafetyClassifier, applySafetyCalibration, SafetyHead } from './SafetyClassifier';
import { Scorer, Signals } from './Scorer';
import { Policy, v1Configuration } from './Policy';
import { EscalationAnalyser, Suspicion } from './Escalation';
import { Lexicons } from './Lexicons';
import { LeverTaxonomy } from './LanguageFolding';
import { SemanticRetriever } from './SemanticRetrieval';
import { AbuseRouter } from './AbuseRouter';
import { SemanticJudge, PooledJudge, JudgeRequest, Decision, JudgeVerdict } from './SemanticJudge';
import { IntentClass, intentCategory, intentDisplay } from './IntentExemplars';
import { NativeScriptSafety } from './NativeScriptSafety';
import { VerdictCache } from './VerdictCache';
import { TrainingStore, TrainingStoreAdapter } from './TrainingStore';
import { ConfigError } from './Errors';

/** Default Groq lane set — mirrors Swift's groqSchemaCompliantModels. */
export const defaultProviderModels = [
    "openai/gpt-oss-safeguard-20b",
    "openai/gpt-oss-20b",
    "openai/gpt-oss-120b",
    "qwen/qwen3.6-27b"
];

export interface ProviderConfig {
    apiKey: string;
    models?: string[];
    timeoutMs?: number;
}

export interface EngineOptions {
    /** Tier-3 provider; omit for deterministic-only operation. */
    provider?: ProviderConfig;
    /** Pre-built judge (tests/mocks). Overrides `provider`. */
    judge?: SemanticJudge;
    /** Verdict cache tuning. */
    cache?: { capacity?: number; ttlMs?: number };
    /** Persistence adapter so training samples survive app restarts. */
    trainingAdapter?: TrainingStoreAdapter;
    /** Pre-parsed abuse router; omit to auto-discover (Node) or run without. */
    abuseRouter?: AbuseRouter | null;
    /** Custom policy configuration. Defaults to v1Configuration if omitted. */
    policy?: import('./Policy').Configuration;
}

export interface EngineConfig {
    maxAnalysedCharacters: number;
    expensiveTierCharacterLimit: number;
    bufferAssemblyCharacterLimit: number;
}

const defaultEngineConfig: EngineConfig = {
    maxAnalysedCharacters: 4000,
    expensiveTierCharacterLimit: 600,
    bufferAssemblyCharacterLimit: 1200,
};

/**
 * Preferred construction path. Returns a fully-wired engine instance with no
 * global mutable state; each instance owns its own buffers, signals, cache and
 * training store.
 */
export function createEngine(options: EngineOptions = {}, config: Partial<EngineConfig> = {}): ModerationEngine {
    return new ModerationEngine(options, config);
}

export class ModerationEngine {
    readonly config: EngineConfig;

    private canonicalizer = new Canonicalizer();
    private scorer = new Scorer();
    private _actorSignals = new ActorSignalStore();
    private _safetyClassifier = new SignalDerivedSafetyClassifier();
    private _buffers = new ConversationBuffers();

    private semanticRetriever = new SemanticRetriever();
    private safetyPass = new SafetyPassEvaluator(this._safetyClassifier, this.semanticRetriever);
    private cascade = new DetectionCascade();
    private assembler = new CrossMessageAssembler();
    private escalation = new EscalationAnalyser();
    private abuseRouter: AbuseRouter | null;
    public judge: SemanticJudge | null = null;
    private policyConfig: import('./Policy').Configuration;

    private verdictCache: VerdictCache;
    private trainingStore: TrainingStore;

    constructor(options: EngineOptions = {}, config: Partial<EngineConfig> = {}) {
        // Explicit lifecycle instead of an import-time side effect; register()
        // is idempotent so multiple engines stay safe.
        NativeScriptSafety.register();
        this.config = { ...defaultEngineConfig, ...config };
        this.policyConfig = options.policy ?? v1Configuration;
        this.verdictCache = new VerdictCache(options.cache?.capacity, options.cache?.ttlMs);
        this.trainingStore = new TrainingStore(options.trainingAdapter);
        if (options.judge) {
            this.judge = options.judge;
        } else if (options.provider) {
            this.configureJudge(options.provider);
        }
        this.abuseRouter = options.abuseRouter !== undefined ? options.abuseRouter : AbuseRouter.discover();
        if (!options.trainingAdapter && typeof options.trainingAdapter !== 'undefined') {
            throw new ConfigError('trainingAdapter must be a TrainingStoreAdapter or undefined');
        }
    }

    // ---- Cache / training facades -------------------------------------------

    getCacheStats(): { size: number; hits: number; misses: number; hitRate: number } {
        return {
            size: this.verdictCache.size,
            hits: this.verdictCache.hits,
            misses: this.verdictCache.misses,
            hitRate: this.verdictCache.hitRate
        };
    }

    clearVerdictCache(): void {
        this.verdictCache.clear();
    }

    getTrainingSamples(): ReturnType<TrainingStore['all']> {
        return this.trainingStore.all().slice();
    }

    setTrainingAdapter(adapter: TrainingStoreAdapter): void {
        this.trainingStore.setAdapter(adapter);
    }

    recordFeedback(text: string, violated: boolean, source: "appeal" | "human" = "appeal"): void {
        this.trainingStore.record(text, violated ? 1 : 0, source);
    }

    // ---- Provider configuration ---------------------------------------------

    configureJudge(config: ProviderConfig): boolean {
        if (!config.apiKey) {
            throw new ConfigError('configureJudge: apiKey is required');
        }
        const models = config.models ?? defaultProviderModels;
        if (!Array.isArray(models) || models.length === 0) {
            throw new ConfigError('configureJudge: models must be a non-empty array');
        }
        this.judge = new PooledJudge(config.apiKey, models, config.timeoutMs ?? 60000);
        return true;
    }

    /** @deprecated Use {@link configureJudge} with a ProviderConfig object. */
    public configurePooledJudge(apiKey: string, models: string[] = defaultProviderModels): boolean {
        return this.configureJudge({ apiKey, models });
    }

    static maxAnalysedCharacters = 4000;
    static expensiveTierCharacterLimit = 600;
    static bufferAssemblyCharacterLimit = 1200;

    get actorSignals(): ActorSignalStore {
        return this._actorSignals;
    }

    get buffers(): ConversationBuffers {
        return this._buffers;
    }

    remember(text: string, actor: ActorContext) {
        this.buffers.remember(text, actor);
    }

    recordBlock(sender: string) {
        this.actorSignals.recordBlock(sender);
    }

    report(sender: string, now: Date = new Date()) {
        this.actorSignals.recordReport(sender, now);
    }

    block(sender: string, now: Date = new Date()) {
        this.actorSignals.recordBlock(sender, now);
    }

    notePlatformPriors(sender: string, count: number) {
        this.actorSignals.notePlatformPriors(sender, count);
    }

    resetBuffer(actor: ActorContext) {
        this.buffers.reset(actor);
        this.actorSignals.reset(actor.senderID);
    }

    private attachSurfaces(detections: Detection[], original: string): Detection[] {
        return detections.map(d => {
            const start = Math.max(0, Math.min(d.range[0], original.length));
            const end = Math.max(start, Math.min(d.range[1], original.length));
            return {
                ...d,
                surface: original.slice(start, end)
            };
        });
    }

    private dedupe(detections: Detection[], textLength: number): Detection[] {
        const best = new Map<string, Detection>();
        for (const d of detections) {
            const lo = Math.max(0, Math.min(d.range[0], textLength));
            const hi = Math.max(lo, Math.min(d.range[1], textLength));
            if (hi <= lo) continue;
            const key = `${d.category}|${lo}|${hi}`;
            const existing = best.get(key);
            if (existing && existing.confidence >= d.confidence) continue;
            best.set(key, { ...d, range: [lo, hi] });
        }
        const sorted = Array.from(best.values()).sort((a, b) => b.confidence - a.confidence);
        const kept: Detection[] = [];
        for (const d of sorted) {
            const swallowed = kept.some(k =>
                k.category === d.category
                && k.range[0] <= d.range[0]
                && k.range[1] >= d.range[1]
            );
            if (!swallowed) kept.push(d);
        }
        return kept.sort((a, b) => a.range[0] - b.range[0]);
    }

    evaluate(
        original: string,
        actor: ActorContext = defaultActorContext(),
        advisoryOnly: boolean = false,
        useConversationBuffer: boolean = true
    ): Verdict {
        const started = Date.now();
        const policyConfig = this.policyConfig;

        const trimmed = original.trim();
        if (trimmed.length === 0) {
            return { ...cleanVerdict(original, Date.now() - started) };
        }

        const fullLength = original.length;
        let analysed = original;
        let truncated = false;
        if (fullLength > ModerationEngine.maxAnalysedCharacters) {
            analysed = original.substring(0, ModerationEngine.maxAnalysedCharacters);
            truncated = true;
        }

        const allowExpensiveTiers = analysed.length <= ModerationEngine.expensiveTierCharacterLimit;

        const views = this.canonicalizer.build(analysed);
        const contextResult = NumericContext.analyze(views.base);
        const effort = Canonicalizer.effort(views.allTransforms);
        const signals = Signals.compute(views.base, views.alpha, views.compact);

        const cascadeResult = this.cascade.run({ analysed, views, signals, effort, allowExpensiveTiers });
        let detections = cascadeResult.detections;
        const suppressedOnly = cascadeResult.suppressedOnly;
        // Tier-2 semantic retrieval over the whole message, only when nothing deterministic fired.
        let usedRetrieval = false;
        let retrievalMargin = 0;
        let retrievalSimilarity = 0;
        if (detections.filter(d => isContactExfiltration(d.category)).length === 0) {
            const result = this.semanticRetriever.retrieve(analysed);
            if (result) {
                retrievalMargin = result.margin;
                retrievalSimilarity = result.similarity;
            }
            const semanticDetection = this.semanticRetriever.detect(analysed, analysed.length, effort);
            if (semanticDetection) {
                detections.push(semanticDetection);
                usedRetrieval = true;
            }
        }

        detections = detections.filter(d => {
            if (d.category !== ModCategory.ExternalURL) return true;
            const host = ModerationEngine.hostOfCandidate(d.canonical);
            if (!host) return true;
            return !SafetyRules.isPlatformOwned(host);
        });

        // Simulate Cross Message Assembly
        const assembly = this.assembler.assemble({
            previous: this.buffers.recent(actor).map(m => m.slice(0, ModerationEngine.bufferAssemblyCharacterLimit)),
            analysed,
            views,
            effort,
            suppressedOnly,
            consume: () => this.buffers.consume(actor)
        });
        const crossMessage = assembly.crossMessage;
        if (assembly.detection) detections.push(assembly.detection);

        detections = this.dedupe(detections, analysed.length);
        detections = detections.map(d => ({ ...d, effort: Canonicalizer.effort(d.transforms) }));
        const contactDetections = detections.filter(d => isContactExfiltration(d.category));
        const contactEffort = contactDetections.map(d => d.effort).reduce((a, b) => Math.max(a, b), 0);

        // Safety rules + Tier-2 safety retrieval + derived classifier.
        const safetyPass = this.safetyPass.run({ analysed, views, signals });
        const safetyFindings = safetyPass.findings;
        const classification = safetyPass.classification;
        const layer3 = safetyPass.layer3;
        const safetySimilarity = safetyPass.safetySimilarity;
        const innocentSimilarity = safetyPass.innocentSimilarity;
        const safetyRetrieval = safetyPass.safetyRetrieval;
        const contactRetrieval = safetyPass.contactRetrieval;
        const scoring = this.scorer.score({
            detections: contactDetections,
            signals,
            obfuscationEffort: contactEffort,
            suppressedOnly,
            crossMessageAssembled: crossMessage,
            priorViolations: actor.priorViolations
        });

        const decision = Policy.decide(
            scoring.score,
            contactDetections,
            safetyFindings,
            actor,
            advisoryOnly,
            policyConfig
        );

        let effectiveDetections: Detection[] = [];
        if (decision.action !== ModAction.Allow) {
            effectiveDetections = [...contactDetections];
            for (const f of safetyFindings) {
                effectiveDetections.push({
                    id: newId(),
                    category: f.category,
                    range: f.range,
                    surface: "",
                    canonical: f.phrase,
                    confidence: f.confidence,
                    transforms: [],
                    effort: 0,
                    reason: `Safety rule: ${f.category}`
                });
            }
        }

        const allWithSurfaces = this.attachSurfaces(effectiveDetections, original);

        let reasonCodes = [...decision.reasonCodes];
        if (crossMessage) reasonCodes.push("CROSS_MESSAGE_ASSEMBLY");
        if (suppressedOnly) reasonCodes.push("NUMERIC_CONTEXT_SUPPRESSED");
        if (contextResult.firedRules.length > 0) reasonCodes.push(`NUMCTX(${contextResult.firedRules.slice(0, 3).join(",")})`);
        reasonCodes.push(...layer3.reasonCodes);
        if (truncated) reasonCodes.push(`INPUT_TRUNCATED(${fullLength}→${ModerationEngine.maxAnalysedCharacters})`);
        if (!allowExpensiveTiers) reasonCodes.push("EXPENSIVE_TIERS_SKIPPED");

        let learnedAbuseSignal = false;
        let routerScore = -1;
        let routerWeightCount = -1;
        if (this.abuseRouter && !advisoryOnly) {
            routerScore = this.abuseRouter.score(original);
            routerWeightCount = this.abuseRouter.weightCount;
            if (routerScore >= this.abuseRouter.threshold) {
                learnedAbuseSignal = true;
                reasonCodes.push(`LEARNED_ABUSE(${routerScore.toFixed(2)})`);
            }
        }

        const escalation = this.escalation.analyse(
            analysed,
            views,
            effectiveDetections,
            suppressedOnly,
            signals,
            allowExpensiveTiers,
            contactRetrieval ? contactRetrieval.margin : 0,
            contactRetrieval ? contactRetrieval.similarity : 0,
            safetyRetrieval ? safetyRetrieval.space.escalation : null,
            safetyRetrieval ? safetyRetrieval.negativeSimilarity : -1,
            safetyRetrieval ? safetyRetrieval.similarity : -1,
            layer3.shouldRoute
        );

        if (escalation.reasonCode) reasonCodes.push(escalation.reasonCode);

        let finalAction = decision.action;
        let finalScore = scoring.score;
        let reportedDetections = allWithSurfaces;

        if (escalation.suspicions.includes(Suspicion.promptManipulation)) {
            reportedDetections.push({
                id: newId(),
                category: ModCategory.SystemManipulation,
                range: [0, Math.max(1, original.length)],
                surface: original,
                canonical: "moderation tampering",
                confidence: 0.90,
                transforms: views.base.transforms,
                effort: contactEffort + 4,
                reason: "Contains text directed at the moderation system rather than at the recipient"
            });
            reasonCodes.push("SYSTEM_MANIPULATION");
            if (Policy.rank(finalAction) < Policy.rank(ModAction.Block) && !advisoryOnly) finalAction = ModAction.Block;
            finalScore = Math.max(finalScore, 0.75);
        }

        let behaviouralSuspicion = false;
        let behaviouralRisk = new ActorRisk();
        if (!advisoryOnly) {
            const safetySignal = classification.strongestViolation ? classification.strongestViolation.score : 0;
            const actedOnSafety = safetyFindings.length > 0 && finalAction !== ModAction.Allow && finalAction !== ModAction.Hint;
            const lawfulRemedyOnly = LeverTaxonomy.classify(analysed) === "lawful";
            const patternEligible = layer3.shouldRoute && classification.legitimateComplaint < this._safetyClassifier.calibration.complaintVeto && !lawfulRemedyOnly;
            
            this.actorSignals.observe(
                actor.senderID,
                actor.conversationID,
                safetySignal,
                patternEligible,
                actedOnSafety
            );

            behaviouralRisk = this.actorSignals.risk(actor.senderID, actor.conversationID);
            
            if (behaviouralRisk.escalating && patternEligible) {
                behaviouralSuspicion = true;
                reasonCodes.push(`BEHAVIOUR_PATTERN(${behaviouralRisk.subThresholdSafetyHits} sub-threshold)`);
                if (Policy.rank(finalAction) < Policy.rank(ModAction.Block)) {
                    finalAction = ModAction.Block;
                    finalScore = Math.max(finalScore, 0.65);
                }
            }
            if (behaviouralRisk.receivedReports > 0) reasonCodes.push(`ACTOR_REPORTED(${behaviouralRisk.receivedReports})`);
            if (behaviouralRisk.isElevated) reasonCodes.push(`ACTOR_RISK(${behaviouralRisk.composite.toFixed(2)})`);
        }

        // Determine if Tier 3 is needed
        const escalateSuspicions = escalation.suspicions.filter(s => s !== Suspicion.personDirectedAnomaly);
        const escalate = (scoring.score >= 0.10 && scoring.score <= 0.62) || // abstain band approximation
                         escalateSuspicions.length > 0 || 
                         behaviouralSuspicion ||
                         learnedAbuseSignal;

        if (escalate) reasonCodes.push("TIER3_ESCALATION_CANDIDATE");

        let provisionalHold = false;
        if (policyConfig.provisionalHoldEnabled && escalate && !advisoryOnly) {
            // Note: withholdsMessage is true if action is block or redact. 
            const withholdsMessage = finalAction === ModAction.Block || finalAction === ModAction.Mask;
            if (!withholdsMessage) {
                provisionalHold = true;
                reasonCodes.push("PROVISIONAL_HOLD");
            }
        }

        const verdict = cleanVerdict(original, Date.now() - started);
        verdict.action = finalAction;
        verdict.reasonCodes = reasonCodes;
        verdict.detections = reportedDetections;
        verdict.provisionalHold = provisionalHold;
        verdict.score = finalScore;
        verdict.suspicions = [
            ...escalation.suspicions,
            ...(behaviouralSuspicion ? [Suspicion.escalatingPattern] : []),
            ...(learnedAbuseSignal ? [Suspicion.learnedAbuse] : [])
        ];
        verdict.carriers = escalation.carriers;
        return verdict;
    }

    shouldEscalate(verdict: Verdict): boolean {
        if (verdict.suspicions.length > 0) return true;
        return verdict.score >= 0.10 && verdict.score <= 0.62;
    }

    private applyJudgement(judgement: JudgeVerdict, verdict: Verdict, message: string, actor: ActorContext): Verdict {
        if (judgement.decision === Decision.abstain) {
            const safetyShaped = verdict.suspicions.includes(Suspicion.learnedAbuse);
            if (!safetyShaped || !(verdict.action === ModAction.Allow || verdict.action === ModAction.Hint)) {
                return verdict;
            }
            const priorAction = verdict.action;
            verdict.reasonCodes.push("SAFETY_FAIL_CLOSED");
            verdict.action = ModAction.Block;
            verdict.tierReached = 3;
            verdict.judgement = {
                decision: judgement.decision, confidence: judgement.confidence,
                rationale: judgement.rationale, source: judgement.source,
                latencyMs: judgement.latencyMs, priorAction: priorAction, priorScore: verdict.score
            };
            return verdict;
        }
        return this.revise(judgement, verdict, message, actor);
    }

    private revise(judgement: JudgeVerdict, verdict: Verdict, message: string, actor: ActorContext): Verdict {
        const detections = verdict.detections;
        const reasons = verdict.reasonCodes;
        const length = Math.max(1, Array.from(message).length);
        verdict.latencyMs += judgement.latencyMs;

        if (judgement.decision === Decision.safetyViolation) {
            const category = judgement.safetyCategory ?? ModCategory.Coercion;
            const finding = {
                category,
                confidence: Math.max(judgement.confidence, 0.80),
                phrase: judgement.rationale,
                range: [0, length] as [number, number]
            };
            const decision = Policy.decide(
                verdict.score,
                detections.filter(d => isContactExfiltration(d.category)),
                [finding],
                actor,
                false
            );
            reasons.push("TIER3_SAFETY");
            for (const rc of decision.reasonCodes) {
                if (!reasons.includes(rc)) reasons.push(rc);
            }
            detections.push({
                id: newId(),
                category,
                range: finding.range,
                surface: "",
                canonical: category,
                confidence: finding.confidence,
                transforms: ["tier3-safety"],
                effort: verdict.obfuscationEffort,
                reason: `${judgement.rationale} [${judgement.source}]`
            });
            verdict.action = decision.action;
            verdict.score = verdict.score;
            verdict.detections = detections;
            verdict.reasonCodes = reasons;
            verdict.tierReached = 3;
            verdict.judgement = {
                decision: judgement.decision, confidence: judgement.confidence,
                rationale: judgement.rationale, source: judgement.source,
                latencyMs: judgement.latencyMs, priorAction: verdict.action, priorScore: verdict.score
            };
            return verdict;
        }

        if (judgement.decision === Decision.benign) {
            const hasHardEvidence = detections.some(d =>
                ((isContactExfiltration(d.category) && d.confidence >= 0.85 && !d.transforms.includes("semantic-retrieval")) ||
                 (d.category === ModCategory.Coercion && d.confidence >= 0.80))
            );
            if (hasHardEvidence) return verdict;

            if (verdict.suspicions.includes(Suspicion.promptManipulation)) {
                reasons.push("TIER3_CLEARANCE_REFUSED_INJECTION");
                return verdict;
            }

            reasons.push("TIER3_CLEARED");
            verdict.action = ModAction.Allow;
            verdict.score = Math.min(verdict.score, 0.15);
            verdict.detections = [];
            verdict.categories = new Set<ModCategory>();
            verdict.reasonCodes = reasons;
            verdict.tierReached = 3;
            verdict.maskedText = message;
            verdict.redactedRanges = [];
            verdict.judgement = {
                decision: judgement.decision, confidence: judgement.confidence,
                rationale: judgement.rationale, source: judgement.source,
                latencyMs: judgement.latencyMs, priorAction: verdict.action, priorScore: verdict.score
            };
            return verdict;
        }

        const coincidenceProne =
            verdict.suspicions.length === 1 && verdict.suspicions[0] === Suspicion.positionalCarrier &&
            !detections.some(d => isContactExfiltration(d.category) && d.confidence >= 0.85);
        if (coincidenceProne && judgement.confidence < 0.90) {
            reasons.push("TIER3_UNCORROBORATED_CARRIER");
            verdict.reasonCodes = reasons;
            return verdict;
        }

        const intent: IntentClass = (judgement.intent as IntentClass) ?? IntentClass.referentialContact;
        detections.push({
            id: newId(),
            category: intentCategory(intent),
            range: [0, length],
            surface: message,
            canonical: intentDisplay(intent),
            confidence: Math.min(Math.max(judgement.confidence, 0.5), 0.97),
            transforms: ["semantic-judge"],
            effort: verdict.obfuscationEffort,
            reason: `${judgement.rationale} [${judgement.source}]`
        });
        reasons.push("TIER3_EXFILTRATION");

        const blended = Math.max(verdict.score, 0.45 + judgement.confidence * 0.5);
        const action: ModAction = blended >= Policy.thresholds(actor).withhold ? ModAction.Warn : ModAction.Mask;

        verdict.action = action;
        verdict.score = Math.min(blended, 0.99);
        verdict.detections = detections;
        verdict.categories = new Set(detections.map(d => d.category));
        verdict.reasonCodes = reasons;
        verdict.tierReached = 3;
        verdict.judgement = {
            decision: judgement.decision, confidence: judgement.confidence,
            rationale: judgement.rationale, source: judgement.source,
            latencyMs: judgement.latencyMs, priorAction: verdict.action, priorScore: verdict.score
        };
        return verdict;
    }

    async evaluateAsync(
        original: string,
        actor: ActorContext = defaultActorContext(),
        advisoryOnly: boolean = false
    ): Promise<Verdict> {
        if (original.length > ModerationEngine.yieldThresholdCharacters) {
            await ModerationEngine.yieldToUI();
        }

        const verdict = this.evaluate(original, actor, advisoryOnly, true);

        if (!this.shouldEscalate(verdict) || !this.judge) return verdict;

        // Near-duplicate messages reuse a prior LLM verdict instead of spending
        // another call. Abstains are never cached so provider outages don't stick.
        const cached = this.verdictCache.get(original);
        if (cached && cached.decision !== Decision.abstain) {
            verdict.latencyMs += 0;
            return this.applyJudgement({ ...cached, latencyMs: 0 }, verdict, original, actor);
        }

        const request: JudgeRequest = {
            window: [...this.buffers.recent(actor), original],
            priorScore: verdict.score,
            priorFindings: verdict.detections.map(d => `${d.category}: ${d.canonical}`),
            bookingStage: actor.stage,
            trust: actor.trust,
            suspicions: verdict.suspicions || [],
            carriers: verdict.carriers || []
        };

        const llmStarted = Date.now();
        const judgement = await this.judge.judge(request);
        verdict.latencyMs += judgement.latencyMs;

        if (judgement.decision !== Decision.abstain) {
            this.verdictCache.put(original, { ...judgement });
            this.trainingStore.record(
                original,
                judgement.decision === Decision.benign ? 0 : 1,
                "tier3"
            );
        }

        return this.applyJudgement(judgement, verdict, original, actor);
    }

    
    /**
     * React-Native friendly evaluation for long inputs. Messages under
     * `yieldThresholdCharacters` evaluate synchronously (~2ms mean). Longer
     * texts yield to the event loop first so an in-flight animation frame can
     * paint before the multi-millisecond analysis runs, avoiding dropped
     * frames on low-end devices.
     */
    static yieldThresholdCharacters = 1500;

    private static yieldToUI(): Promise<void> {
        return new Promise(resolve => setTimeout(resolve, 0));
    }

    static hostOfCandidate(candidate: string): string | null {
        let s = candidate.toLowerCase().trim();
        const schemeEnd = s.indexOf("://");
        if (schemeEnd !== -1) s = s.substring(schemeEnd + 3);
        let authority = "";
        for (const ch of s) {
            if (ch === "/" || ch === "?" || ch === "#") break;
            authority += ch;
        }
        if (authority.length === 0) return null;
        const parts = authority.split("@");
        const hostPart = parts[parts.length - 1] ?? authority;
        return hostPart.split(":")[0] ?? null;
    }

    static mentionsProperty(alpha: CharView): boolean {
        for (const token of Canonicalizer.tokenize(alpha)) {
            if (token.isWord && Lexicons.propertyTargets.has(token.text)) {
                return true;
            }
        }
        return false;
    }
}
