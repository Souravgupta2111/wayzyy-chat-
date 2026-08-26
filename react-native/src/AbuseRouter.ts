import { platform } from './Platform';
import { BundleFormatError } from './Errors';

export class AbuseRouter {
    private readonly weights: Float32Array;
    private readonly buckets: number;
    private readonly ngrams: number[];
    private readonly bias: number;

    public readonly weightCount: number;
    public readonly threshold: number;

    private constructor(weights: Float32Array, buckets: number, ngrams: number[], bias: number, threshold: number, nonZero: number) {
        this.weights = weights;
        this.buckets = buckets;
        this.ngrams = ngrams;
        this.bias = bias;
        this.threshold = threshold;
        this.weightCount = nonZero;
    }

    public routes(text: string): boolean {
        return this.score(text) >= this.threshold;
    }

    private static hash(bytes: Uint8Array): number {
        let h = 0x811C9DC5;
        for (let i = 0; i < bytes.length; i++) {
            h ^= bytes[i];
            h = Math.imul(h, 0x01000193);
        }
        return h >>> 0; // Convert to unsigned 32-bit integer
    }

    public score(text: string): number {
        const collapsed = text.toLowerCase()
            .split(/\s+/)
            .filter(s => s.length > 0)
            .join(" ");
            
        if (collapsed.length === 0) return 0;

        const padded = " " + collapsed + " ";
        const scalars = Array.from(padded); // Extracts unicode scalars

        const counts = new Map<number, number>();
        const encoder = new TextEncoder();

        for (const n of this.ngrams) {
            if (scalars.length >= n) {
                for (let i = 0; i <= scalars.length - n; i++) {
                    const view = scalars.slice(i, i + n).join("");
                    const bytes = encoder.encode(view);
                    const index = AbuseRouter.hash(bytes) % this.buckets;
                    counts.set(index, (counts.get(index) || 0) + 1);
                }
            }
        }

        if (counts.size === 0) return 0;

        let norm = 0;
        for (const v of counts.values()) {
            norm += v * v;
        }
        norm = Math.sqrt(norm);
        if (norm === 0) return 0;

        let z = this.bias;
        for (const [index, count] of counts.entries()) {
            z += this.weights[index] * (count / norm);
        }

        z = Math.max(-30, Math.min(30, z));
        return 1 / (1 + Math.exp(-z));
    }

    public static parse(raw: string): AbuseRouter {
        let buckets = 0;
        let ngrams: number[] = [];
        let bias = 0.0;
        let threshold = 0.5;
        let declared = 0;
        let weights: Float32Array = new Float32Array(0);
        let nonZero = 0;

        const lines = raw.split(/\r?\n/).filter(line => line.trim().length > 0);

        for (const line of lines) {
            const parts = line.split(" ");
            if (parts.length === 0) continue;

            switch (parts[0]) {
                case "WAYZYY-NGRAM-1":
                    continue;
                case "buckets":
                    buckets = parts.length > 1 ? parseInt(parts[1], 10) : 0;
                    if (buckets <= 0 || buckets > (1 << 24)) {
                        throw new BundleFormatError(`abuse router weights malformed: bucket count ${buckets}`);
                    }
                    weights = new Float32Array(buckets);
                    break;
                case "ngrams":
                    ngrams = (parts.length > 1 ? parts[1] : "").split(",").map(s => parseInt(s, 10)).filter(n => !isNaN(n));
                    break;
                case "bias":
                    bias = parts.length > 1 ? parseFloat(parts[1]) : 0;
                    break;
                case "threshold":
                    threshold = parts.length > 1 ? parseFloat(parts[1]) : 0.5;
                    break;
                case "weights":
                    declared = parts.length > 1 ? parseInt(parts[1], 10) : 0;
                    break;
                default:
                    if (parts.length === 2) {
                        const index = parseInt(parts[0], 10);
                        const value = parseFloat(parts[1]);
                        if (!isNaN(index) && !isNaN(value) && index >= 0 && index < weights.length) {
                            weights[index] = value;
                            nonZero++;
                        }
                    }
                    break;
            }
        }

        if (buckets <= 0 || ngrams.length === 0) {
            throw new BundleFormatError("abuse router weights malformed: missing header");
        }
        if (declared > 0 && declared !== nonZero) {
            throw new BundleFormatError(`abuse router weights malformed: declared ${declared} weights, read ${nonZero}`);
        }

        return new AbuseRouter(weights, buckets, ngrams, bias, threshold, nonZero);
    }

    public static loadFile(path: string): AbuseRouter {
        const raw = platform().readTextFile(path);
        if (raw === null) {
            throw new BundleFormatError(`abuse router weights malformed: unreadable at ${path}`);
        }
        try {
            return AbuseRouter.parse(raw);
        } catch (error: unknown) {
            if (error instanceof BundleFormatError) {
                throw error;
            }
            const msg = error instanceof Error ? error.message : String(error);
            throw new BundleFormatError(`abuse router weights malformed: unreadable at ${path} - ${msg}`);
        }
    }

    public static discover(): AbuseRouter | null {
        const candidates: string[] = [];
        const envPath = platform().env("WAYZYY_ABUSE_ROUTER");
        if (envPath) {
            candidates.push(envPath);
        }

        candidates.push("config/abuse-router.weights");
        candidates.push("/etc/wayzyy/abuse-router.weights");
        candidates.push("../config/abuse-router.weights"); // Often helpful if run from inside src/ or react-native/

        for (const path of candidates) {
            const raw = platform().readTextFile(path);
            if (raw !== null) {
                return AbuseRouter.parse(raw);
            }
        }
        return null;
    }
}
