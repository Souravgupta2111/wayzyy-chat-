// Accumulates labelled examples for the weekly AbuseRouter retraining.
// Labels come from three sources:
//   - tier3:      every adjudicated escalation (LLM verdict = label)
//   - appeal:     user-reported false positive / missed detection
//   - human:      moderator review
// The store is deliberately storage-agnostic: the app injects a persistence
// adapter (SQLite / AsyncStorage), tests use memory.

export type SampleSource = "tier3" | "appeal" | "human" | "seed";

export interface TrainingSample {
    text: string;
    /** 1 = abuse/exfiltration, 0 = benign */
    label: 0 | 1;
    source: SampleSource;
    createdAt: number;
}

export interface TrainingStoreAdapter {
    load(): TrainingSample[];
    append(sample: TrainingSample): void;
    clear(): void;
}

class MemoryAdapter implements TrainingStoreAdapter {
    samples: TrainingSample[] = [];
    load(): TrainingSample[] { return this.samples; }
    append(sample: TrainingSample): void { this.samples.push(sample); }
    clear(): void { this.samples = []; }
}

export class TrainingStore {
    private adapter: TrainingStoreAdapter;
    private cache: TrainingSample[] | null = null;

    constructor(adapter?: TrainingStoreAdapter) {
        this.adapter = adapter ?? new MemoryAdapter();
    }

    setAdapter(adapter: TrainingStoreAdapter): void {
        this.adapter = adapter;
        this.cache = null;
    }

    record(text: string, label: 0 | 1, source: SampleSource): void {
        if (text.trim().length === 0) return;
        this.adapter.append({ text, label, source, createdAt: Date.now() });
        this.cache = null;
    }

    all(): TrainingSample[] {
        if (this.cache === null) this.cache = this.adapter.load();
        return this.cache;
    }

    count(): number {
        return this.all().length;
    }

    clear(): void {
        this.adapter.clear();
        this.cache = null;
    }
}
