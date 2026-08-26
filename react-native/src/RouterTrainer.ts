// Retrains the AbuseRouter from labelled examples and emits weights in the
// exact "WAYZYY-NGRAM-1" text format that AbuseRouter.parse consumes — so a
// retrained model is indistinguishable from the shipped one downstream
// (Supabase bundle, config file, or embedded asset).
//
// Model: L2-regularised logistic regression over FNV-1a-hashed character
// n-grams with L2 normalisation, identical to the scoring path in AbuseRouter.
// Training uses per-sample SGD with an averaged tail for stability.

import { utf8Bytes } from './Platform';
import { TrainingSample } from './TrainingStore';
import { ConfigError } from './Errors';

export interface RouterConfig {
    buckets: number;
    ngrams: number[];
    bias: number;
    threshold: number;
}

export const defaultRouterConfig: RouterConfig = {
    buckets: 1 << 18,
    ngrams: [2, 3, 4, 5],
    bias: 0.0,
    threshold: 0.08,
};

function hashFeature(text: string, n: number, buckets: number): number {
    const bytes = utf8Bytes(text);
    let h = 0x811C9DC5;
    for (let i = 0; i < bytes.length; i++) {
        h ^= bytes[i]!;
        h = Math.imul(h, 0x01000193);
    }
    return (h >>> 0) % buckets;
}

/** Mirrors AbuseRouter.score's feature construction exactly. */
function features(text: string, cfg: RouterConfig): Map<number, number> {
    const collapsed = text.toLowerCase()
        .split(/\s+/)
        .filter(s => s.length > 0)
        .join(" ");
    const out = new Map<number, number>();
    if (collapsed.length === 0) return out;

    const padded = " " + collapsed + " ";
    const scalars = Array.from(padded);

    for (const n of cfg.ngrams) {
        if (scalars.length < n) continue;
        for (let i = 0; i <= scalars.length - n; i++) {
            const view = scalars.slice(i, i + n).join("");
            const index = hashFeature(view, n, cfg.buckets);
            out.set(index, (out.get(index) || 0) + 1);
        }
    }
    return out;
}

export interface TrainResult {
    /** Serialised weights — feed straight into AbuseRouter.parse(). */
    serialized: string;
    nonZero: number;
    epochs: number;
    trainAccuracy: number;
    holdoutAccuracy: number | null;
    holdoutF1: number | null;
}

export class RouterTrainer {
    private readonly cfg: RouterConfig;

    constructor(cfg: Partial<RouterConfig> = {}) {
        this.cfg = { ...defaultRouterConfig, ...cfg };
    }

    /**
     * @param samples labelled corpus; aim for ≥200 per class before trusting output
     * @param epochs passes over the data (default 12)
     * @param lr learning rate (default 0.5)
     * @param l2 regularisation strength (default 1e-6)
     * @param holdoutFraction fraction held back for evaluation (default 0.15)
     */
    train(
        samples: TrainingSample[],
        epochs: number = 12,
        lr: number = 0.5,
        l2: number = 1e-6,
        holdoutFraction: number = 0.15,
    ): TrainResult {
        if (samples.length === 0) throw new ConfigError("RouterTrainer: no training samples");
        const { buckets, ngrams, bias, threshold } = this.cfg;

        // Deterministic shuffle so re-runs on the same corpus are reproducible.
        const order = samples.map((_, i) => i);
        let seed = 0x9E3779B9;
        const rand = () => {
            seed ^= seed << 13; seed >>>= 0;
            seed ^= seed >> 17;
            seed ^= seed << 5; seed >>>= 0;
            return seed / 0xFFFFFFFF;
        };
        for (let i = order.length - 1; i > 0; i--) {
            const j = Math.floor(rand() * (i + 1));
            [order[i], order[j]] = [order[j]!, order[i]!];
        }
        const shuffled = order.map(i => samples[i]!);

        const holdoutCount = Math.floor(shuffled.length * holdoutFraction);
        const holdout = shuffled.slice(0, holdoutCount);
        const trainSet = shuffled.slice(holdoutCount);

        const weights = new Float32Array(buckets);
        const featurise = (s: TrainingSample) => ({ f: features(s.text, this.cfg), y: s.label });

        for (let epoch = 0; epoch < epochs; epoch++) {
            for (const raw of trainSet) {
                const { f, y } = featurise(raw);
                if (f.size === 0) continue;

                let norm = 0;
                for (const v of f.values()) norm += v * v;
                norm = Math.sqrt(norm);
                if (norm === 0) continue;

                let z = bias;
                for (const [index, count] of f.entries()) z += weights[index]! * (count / norm);
                const p = 1 / (1 + Math.exp(-Math.max(-30, Math.min(30, z))));
                const err = y - p;

                for (const [index, count] of f.entries()) {
                    const xij = count / norm;
                    weights[index] = weights[index]! + lr * (err * xij - l2 * weights[index]!);
                }
            }
        }

        const serialized = this.serialize(weights);
        const parsedNonZero = serialized.split(/\r?\n/).filter(l => /^[0-9]+ -/.test(l) || /^[0-9]+ [0-9]/.test(l)).length;

        const accuracyOf = (set: { text: string; label: 0 | 1 }[], w: Float32Array): { acc: number; f1: number | null } => {
            if (set.length === 0) return { acc: 0, f1: null };
            let tp = 0, fp = 0, tn = 0, fn = 0;
            for (const s of set) {
                const f = features(s.text, this.cfg);
                let z = bias;
                let norm = 0;
                for (const v of f.values()) norm += v * v;
                norm = Math.sqrt(norm);
                for (const [index, count] of f.entries()) z += w[index]! * (count / norm);
                const predicted = (1 / (1 + Math.exp(-z))) >= threshold ? 1 : 0;
                if (predicted === 1 && s.label === 1) tp++;
                else if (predicted === 1 && s.label === 0) fp++;
                else if (predicted === 0 && s.label === 0) tn++;
                else fn++;
            }
            const prec = tp + fp === 0 ? 0 : tp / (tp + fp);
            const rec = tp + fn === 0 ? 0 : tp / (tp + fn);
            const f1 = prec + rec === 0 ? null : 2 * prec * rec / (prec + rec);
            return { acc: (tp + tn) / set.length, f1 };
        };

        const trainEval = accuracyOf(trainSet, weights);
        const holdEval = accuracyOf(holdout, weights);

        return {
            serialized,
            nonZero: parsedNonZero,
            epochs,
            trainAccuracy: trainEval.acc,
            holdoutAccuracy: holdout.length > 0 ? holdEval.acc : null,
            holdoutF1: holdEval.f1,
        };
    }

    /**
     * Emits the WAYZYY-NGRAM-1 format. Only non-zero weights are written; the
     * `weights` header declares their count so AbuseRouter.parse validates it.
     */
    serialize(weights: Float32Array): string {
        const lines: string[] = [];
        lines.push("WAYZYY-NGRAM-1");
        lines.push(`buckets ${this.cfg.buckets}`);
        lines.push(`ngrams ${this.cfg.ngrams.join(",")}`);
        lines.push(`bias ${this.cfg.bias}`);
        lines.push(`threshold ${this.cfg.threshold}`);
        let nonZero = 0;
        const body: string[] = [];
        for (let i = 0; i < weights.length; i++) {
            const w = weights[i]!;
            if (w !== 0) {
                nonZero++;
                body.push(`${i} ${w}`);
            }
        }
        lines.push(`weights ${nonZero}`);
        return [...lines, ...body].join("\n") + "\n";
    }
}
