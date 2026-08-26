import { ModCategory, Detection, newId } from './ModerationTypes';
import { IntentClass, IntentExemplars, Exemplar, intentCategory, intentDisplay } from './IntentExemplars';
import { SafetyRules } from './SafetyRules';
import { ConfigError } from './Errors';

export class SparseVector {
    weights: Map<number, number>;
    norm: number;

    constructor(weights: Map<number, number> | Record<number, number>) {
        this.weights = weights instanceof Map ? weights : new Map(Object.entries(weights).map(([k, v]) => [Number(k), v]));
        
        let sumSq = 0;
        for (const v of this.weights.values()) {
            sumSq += v * v;
        }
        this.norm = Math.sqrt(sumSq);
    }

    cosine(other: SparseVector): number {
        if (this.norm === 0 || other.norm === 0) return 0;
        
        const small = this.weights.size <= other.weights.size ? this.weights : other.weights;
        const large = this.weights.size <= other.weights.size ? other.weights : this.weights;
        
        let dot = 0;
        for (const [k, v] of small.entries()) {
            const w = large.get(k);
            if (w !== undefined) {
                dot += v * w;
            }
        }
        return dot / (this.norm * other.norm);
    }
}

export interface Thresholds {
    similarity: number;
    margin: number;
}

export interface VectorSpace {
    id: string;
    enforcement: Thresholds;
    escalation: Thresholds;
    confidenceCeiling: number;
}

export interface VectorReading {
    vector: SparseVector;
    space: VectorSpace;
}

export interface Vectoriser {
    identifier: string;
    spaces: VectorSpace[];
    reading(text: string): VectorReading;
    anchorVector(text: string, space: VectorSpace): SparseVector;
    get primarySpace(): VectorSpace;
    vector(text: string): SparseVector;
    get enforcementThresholds(): Thresholds;
    get escalationThresholds(): Thresholds;
}

export abstract class BaseVectoriser implements Vectoriser {
    abstract identifier: string;
    abstract spaces: VectorSpace[];
    abstract reading(text: string): VectorReading;
    abstract anchorVector(text: string, space: VectorSpace): SparseVector;

    get primarySpace(): VectorSpace {
        return this.spaces[0];
    }

    vector(text: string): SparseVector {
        return this.reading(text).vector;
    }

    get enforcementThresholds(): Thresholds {
        return this.primarySpace.enforcement;
    }

    get escalationThresholds(): Thresholds {
        return this.primarySpace.escalation;
    }
}

export class LexicalVectoriser extends BaseVectoriser {
    identifier = "lexical-hashed-ngram-v1";
    
    static space: VectorSpace = {
        id: "lexical-hashed-ngram-v1",
        enforcement: { similarity: 0.28, margin: 0.06 },
        escalation: { similarity: 0.24, margin: 0.05 },
        confidenceCeiling: 0.62
    };

    get spaces(): VectorSpace[] {
        return [LexicalVectoriser.space];
    }

    private idf: Map<number, number>;
    private dimensions = 1 << 18;

    constructor(corpus: string[]) {
        super();
        const documentFrequency = new Map<number, number>();
        
        for (const document of corpus) {
            const features = new Set(LexicalVectoriser.features(document, this.dimensions));
            for (const feature of features) {
                documentFrequency.set(feature, (documentFrequency.get(feature) || 0) + 1);
            }
        }
        
        const n = Math.max(corpus.length, 1);
        this.idf = new Map();
        
        for (const [feature, df] of documentFrequency.entries()) {
            this.idf.set(feature, Math.max(Math.log((n + 1) / (df + 1)), 0.0));
        }
    }

    reading(text: string): VectorReading {
        return { vector: this.vector(text), space: LexicalVectoriser.space };
    }

    anchorVector(text: string, space: VectorSpace): SparseVector {
        return this.vector(text);
    }

    override vector(text: string): SparseVector {
        const counts = new Map<number, number>();
        for (const feature of LexicalVectoriser.features(text, this.dimensions)) {
            counts.set(feature, (counts.get(feature) || 0) + 1);
        }
        
        const weighted = new Map<number, number>();
        for (const [feature, tf] of counts.entries()) {
            const weight = this.idf.has(feature) ? this.idf.get(feature)! : 1.2;
            if (weight > 0) {
                weighted.set(feature, (1 + Math.log(tf)) * weight);
            }
        }
        return new SparseVector(weighted);
    }

    static features(text: string, dimensions: number): number[] {
        const normalised = LexicalVectoriser.normalise(text);
        const tokens = normalised.split(" ").filter(t => t.length > 0);
        const out: number[] = [];
        
        for (let i = 0; i < tokens.length; i++) {
            const token = tokens[i];
            out.push(LexicalVectoriser.hash("w:" + token, dimensions));
            if (i + 1 < tokens.length) {
                out.push(LexicalVectoriser.hash("b:" + token + "_" + tokens[i + 1], dimensions));
            }
        }
        
        if (normalised.length >= 4) {
            for (let i = 0; i <= normalised.length - 4; i++) {
                out.push(LexicalVectoriser.hash("c:" + normalised.substring(i, i + 4), dimensions));
            }
        }
        return out;
    }

    static normalise(text: string): string {
        let out = "";
        let lastWasSpace = true;
        const lower = text.toLowerCase();
        
        for (let i = 0; i < lower.length; i++) {
            const ch = lower[i];
            const code = ch.charCodeAt(0);
            const isLetter = (code >= 97 && code <= 122) || code > 127;
            const isNumber = code >= 48 && code <= 57;
            
            if (isLetter || isNumber) {
                out += ch;
                lastWasSpace = false;
            } else if (!lastWasSpace) {
                out += " ";
                lastWasSpace = true;
            }
        }
        return out.trim();
    }

    static hash(s: string, dimensions: number): number {
        // FNV-1a 64-bit parity with Swift
        // BigInt is used here to match Swift's UInt64 overflowing exactly.
        const bytes = new TextEncoder().encode(s);
        let h = 0xcbf29ce484222325n;
        const prime = 0x100000001b3n;
        
        for (let i = 0; i < bytes.length; i++) {
            h ^= BigInt(bytes[i]);
            h = BigInt.asUintN(64, h * prime);
        }
        return Number(h % BigInt(dimensions));
    }
}

export class EmbeddingVectoriser extends BaseVectoriser {
    identifier: string;
    private configuration: { baseURL: string; model: string; apiKey?: string } | null = null;
    private fallback: LexicalVectoriser;
    private embeddingSpace: VectorSpace;
    private cache = new Map<string, SparseVector>();
    private inFlight = new Set<string>();

    constructor(configuration: { baseURL: string; model: string; apiKey?: string; timeout?: number }, corpus: string[]) {
        super();
        this.configuration = configuration;
        this.identifier = "embedding-" + configuration.model;
        this.fallback = new LexicalVectoriser(corpus);
        this.embeddingSpace = {
            id: "embedding-" + configuration.model,
            enforcement: { similarity: 0.60, margin: 0.05 },
            escalation: { similarity: 0.55, margin: 0.05 },
            confidenceCeiling: 0.90
        };
    }

    get spaces(): VectorSpace[] {
        return [this.embeddingSpace, LexicalVectoriser.space];
    }

    reading(text: string): VectorReading {
        const key = LexicalVectoriser.normalise(text);
        const hit = this.cache.get(key);
        if (hit) {
            return { vector: hit, space: this.embeddingSpace };
        }
        
        this.warmInBackground(key, text);
        return { vector: this.fallback.vector(text), space: LexicalVectoriser.space };
    }

    anchorVector(text: string, space: VectorSpace): SparseVector {
        if (space.id !== this.embeddingSpace.id) {
            return this.fallback.vector(text);
        }
        throw new ConfigError("Synchronous embedding fetch not implemented. Await warmup or implement async init for EmbeddingVectoriser in TS.");
    }

    private warmInBackground(key: string, text: string) {
        if (this.inFlight.has(key)) return;
        this.inFlight.add(key);

        // Async fire-and-forget fetch
        fetch(this.configuration.baseURL, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                ...(this.configuration.apiKey ? { 'Authorization': `Bearer ${this.configuration.apiKey}` } : {})
            },
            body: JSON.stringify({ model: this.configuration.model, input: text })
        }).then(res => res.json()).then(data => {
            this.inFlight.delete(key);
            if (data && data.data && data.data[0] && data.data[0].embedding) {
                const dense = data.data[0].embedding as number[];
                const sparseMap = new Map<number, number>();
                dense.forEach((val, i) => { if (val !== 0) sparseMap.set(i, val); });
                this.cache.set(key, new SparseVector(sparseMap));
            }
        }).catch(err => {
            this.inFlight.delete(key);
        });
    }
}

export enum AnchorFamily {
    contact = "contact",
    safety = "safety"
}

export interface RetrievalResult {
    intent: IntentClass;
    similarity: number;
    negativeSimilarity: number;
    margin: number;
    nearestExemplar: string;
    space: VectorSpace;
}

export class SemanticRetriever {
    private vectoriser: Vectoriser;
    private anchors: Map<string, { contact: { exemplar: Exemplar, vector: SparseVector }[], safety: { exemplar: Exemplar, vector: SparseVector }[], negatives: SparseVector[] }>;
    private thresholdOverride?: Thresholds;

    get backendIdentifier(): string { return this.vectoriser.identifier; }
    get thresholds(): Thresholds { return this.thresholdOverride ?? this.vectoriser.primarySpace.enforcement; }
    get escalationThresholds(): Thresholds { return this.vectoriser.primarySpace.escalation; }

    constructor(vectoriser?: Vectoriser, thresholds?: Thresholds) {
        const corpus = [...IntentExemplars.all.map(x => x.text), ...IntentExemplars.negatives];
        this.vectoriser = vectoriser ?? new LexicalVectoriser(corpus);
        this.thresholdOverride = thresholds;

        this.anchors = new Map();
        for (const space of this.vectoriser.spaces) {
            this.anchors.set(space.id, {
                contact: IntentExemplars.contact.map(e => ({ exemplar: e, vector: this.vectoriser.anchorVector(e.text, space) })),
                safety: IntentExemplars.safety.map(e => ({ exemplar: e, vector: this.vectoriser.anchorVector(e.text, space) })),
                negatives: IntentExemplars.negatives.map(n => this.vectoriser.anchorVector(n, space))
            });
        }
    }

    retrieve(text: string, family: AnchorFamily = AnchorFamily.contact): RetrievalResult | null {
        const normalised = LexicalVectoriser.normalise(text);
        const floor = family === AnchorFamily.safety ? 3 : 4;
        if (normalised.split(" ").length < floor) return null;

        const reading = this.vectoriser.reading(text);
        if (reading.vector.norm === 0) return null;
        
        const set = this.anchors.get(reading.space.id);
        if (!set) return null;

        const query = reading.vector;
        const positives = family === AnchorFamily.safety ? set.safety : set.contact;

        let best: { exemplar: Exemplar, similarity: number } | null = null;
        for (const { exemplar, vector } of positives) {
            const similarity = query.cosine(vector);
            if (!best || similarity > best.similarity) {
                best = { exemplar, similarity };
            }
        }

        let worstNegative = 0.0;
        for (const vector of set.negatives) {
            worstNegative = Math.max(worstNegative, query.cosine(vector));
        }

        if (!best) return null;

        return {
            intent: best.exemplar.intent,
            similarity: best.similarity,
            negativeSimilarity: worstNegative,
            margin: best.similarity - worstNegative,
            nearestExemplar: best.exemplar.text,
            space: reading.space
        };
    }

    detect(text: string, textLength: number, effort: number): Detection | null {
        const result = this.retrieve(text);
        if (!result) return null;

        const thresholds = this.thresholdOverride ?? result.space.enforcement;
        if (result.similarity < thresholds.similarity || result.margin < thresholds.margin) return null;

        const span = Math.max(result.space.confidenceCeiling - thresholds.similarity, 0.01);
        const t = Math.min(Math.max((result.similarity - thresholds.similarity) / span, 0), 1);
        const confidence = 0.56 + t * 0.36;

        return {
            id: newId(),
            category: intentCategory(result.intent),
            range: [0, Math.max(1, textLength)],
            surface: "",
            canonical: intentDisplay(result.intent),
            confidence: confidence,
            transforms: ["semantic-retrieval"],
            effort: effort,
            reason: `${intentDisplay(result.intent)} — ${result.similarity.toFixed(2)} similar to a known pattern: "${result.nearestExemplar}"`
        };
    }

    detectSafety(text: string, textLength: number): { category: ModCategory, confidence: number, phrase: string, range: [number, number] } | null {
        const result = this.retrieve(text, AnchorFamily.safety);
        if (!result) return null;
        return this.safetyFinding(result, textLength);
    }

    safetyRetrieval(text: string): RetrievalResult | null {
        return this.retrieve(text, AnchorFamily.safety);
    }

    static safetyEnforcementFloor = 0.55;
    static safetyEnforcementMarginFloor = 0.20;

    safetyFinding(result: RetrievalResult, textLength: number): { category: ModCategory, confidence: number, phrase: string, range: [number, number] } | null {
        const base = this.thresholdOverride ?? result.space.enforcement;
        const similarityBar = Math.max(base.similarity + 0.06, SemanticRetriever.safetyEnforcementFloor);
        const marginBar = Math.max(base.margin * 2, SemanticRetriever.safetyEnforcementMarginFloor);

        if (result.similarity < similarityBar || result.margin < marginBar) return null;

        const span = Math.max(result.space.confidenceCeiling - similarityBar, 0.01);
        const t = Math.min(Math.max((result.similarity - similarityBar) / span, 0), 1);

        return {
            category: intentCategory(result.intent),
            confidence: 0.60 + t * 0.32,
            phrase: `${intentDisplay(result.intent)} — ${result.similarity.toFixed(2)} similar to: "${result.nearestExemplar}"`,
            range: [0, Math.max(1, textLength)]
        };
    }
}
