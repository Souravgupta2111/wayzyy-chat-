export enum ModAction {
    Allow = 'allow',
    Hint = 'hint',
    Mask = 'mask',
    Warn = 'warn',
    Block = 'block',
    Review = 'review'
}

export function getModActionLabel(action: ModAction): string {
    return action.toUpperCase();
}

export function modActionWithholdsMessage(action: ModAction): boolean {
    return action === ModAction.Warn || action === ModAction.Block || action === ModAction.Review;
}

export function getModActionRank(action: ModAction): number {
    switch (action) {
        case ModAction.Allow: return 0;
        case ModAction.Hint: return 1;
        case ModAction.Mask: return 2;
        case ModAction.Review: return 3;
        case ModAction.Warn: return 4;
        case ModAction.Block: return 5;
    }
}

export enum ModCategory {
    Phone = 'phone',
    Email = 'email',
    SocialHandle = 'socialHandle',
    ExternalURL = 'externalURL',
    PaymentHandle = 'paymentHandle',
    CryptoAddress = 'cryptoAddress',
    BankDetails = 'bankDetails',
    ReferentialContact = 'referentialContact',

    Threat = 'threat',
    Harassment = 'harassment',
    Coercion = 'coercion',
    Scam = 'scam',
    Sexual = 'sexual',
    SelfHarm = 'selfHarm',
    Discrimination = 'discrimination',
    SystemManipulation = 'systemManipulation'
}

export function isContactExfiltration(category: ModCategory): boolean {
    switch (category) {
        case ModCategory.Phone:
        case ModCategory.Email:
        case ModCategory.SocialHandle:
        case ModCategory.ExternalURL:
        case ModCategory.PaymentHandle:
        case ModCategory.CryptoAddress:
        case ModCategory.BankDetails:
        case ModCategory.ReferentialContact:
            return true;
        default:
            return false;
    }
}

export enum TrustTier {
    Fresh = 'fresh',
    Standard = 'standard',
    Trusted = 'trusted'
}

export function getTrustTierThresholdOffset(tier: TrustTier): number {
    switch (tier) {
        case TrustTier.Fresh: return -0.08;
        case TrustTier.Standard: return 0.0;
        case TrustTier.Trusted: return +0.10;
    }
}

export enum BookingStage {
    Inquiry = 'inquiry',
    Booked = 'booked',
    CheckedIn = 'checkedIn'
}

export function getBookingStageThresholdOffset(stage: BookingStage): number {
    switch (stage) {
        case BookingStage.Inquiry: return 0.0;
        case BookingStage.Booked: return +0.14;
        case BookingStage.CheckedIn: return +0.22;
    }
}

export interface ActorContext {
    trust: TrustTier;
    stage: BookingStage;
    priorViolations: number;
    conversationID: string;
    senderID: string;
}

export function defaultActorContext(): ActorContext {
    return {
        trust: TrustTier.Standard,
        stage: BookingStage.Inquiry,
        priorViolations: 0,
        conversationID: "demo",
        senderID: "me"
    };
}

export interface Detection {
    id: string;
    category: ModCategory;
    range: [number, number]; // Representing Range<Int> as a tuple [start, end]
    surface: string;
    canonical: string;
    confidence: number;
    transforms: string[];
    effort: number;
    reason: string;
}

/** Collision-resistant id for detections/verdicts; works on Hermes (no crypto.randomUUID). */
export function newId(): string {
    const g = globalThis as { crypto?: { randomUUID?: () => string } };
    if (g.crypto && typeof g.crypto.randomUUID === "function") {
        return g.crypto.randomUUID();
    }
    return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
}

export enum Suspicion {
    dictatedFragment = "dictatedFragment",
    suppressedPhoneShape = "suppressedPhoneShape",
    positionalCarrier = "positionalCarrier",
    spacedDomain = "spacedDomain",
    wordlessProtocolCue = "wordlessProtocolCue",
    anomalousRegularity = "anomalousRegularity",
    intentWithoutPayload = "intentWithoutPayload",
    promptManipulation = "promptManipulation",
    personDirectedAnomaly = "personDirectedAnomaly",
    conditionalDemand = "conditionalDemand",
    classifierUncertain = "classifierUncertain",
    escalatingPattern = "escalatingPattern",
    learnedAbuse = "learnedAbuse"
}

export interface CarrierCandidate {
    channel: string;
    payload: string;
    validates: boolean;
    shape: string;
}

export interface Verdict {
    id: string;
    action: ModAction;
    score: number;
    detections: Detection[];
    categories: Set<ModCategory>;
    reasonCodes: string[];
    tierReached: number;
    latencyMs: number;
    features: [string, number][]; // Array of tuples for [(String, Double)]
    threshold: number;
    maskedText: string;
    redactedRanges: [number, number][];
    transformsApplied: string[];
    obfuscationEffort: number;
    suspicions: Suspicion[];
    carriers: CarrierCandidate[];
    policyVersion: string;

    provisionalHold: boolean;
    judgement: JudgementRecord | null;
}

export function cleanVerdict(text: string, latencyMs: number = 0): Verdict {
    return {
        id: newId(),
        action: ModAction.Allow,
        score: 0,
        detections: [],
        categories: new Set<ModCategory>(),
        reasonCodes: [],
        tierReached: 1,
        latencyMs: latencyMs,
        features: [],
        threshold: 0,
        maskedText: text,
        redactedRanges: [],
        transformsApplied: [],
        obfuscationEffort: 0,
        suspicions: [],
        carriers: [],
        policyVersion: "",
        provisionalHold: false,
        judgement: null
    };
}

export function isVerdictClean(verdict: Verdict): boolean {
    return verdict.detections.length === 0 && verdict.action === ModAction.Allow;
}

export interface JudgementRecord {
    decision: string;
    confidence: number;
    rationale: string;
    source: string;
    latencyMs: number;
    priorAction: ModAction;
    priorScore: number;
}
