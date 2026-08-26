export interface ActorSignalEvent {
    at: Date;
    conversation: string;
    safetyScore: number;
    routedForSafety: boolean;
    acted: boolean;
}

export class ActorSignalSnapshot {
    events: ActorSignalEvent[] = [];
    reports: Date[] = [];
    blocks: Date[] = [];
    platformPriors: number = 0;

    prune(before: Date) {
        this.events = this.events.filter(e => e.at >= before);
        this.reports = this.reports.filter(r => r >= before);
        this.blocks = this.blocks.filter(b => b >= before);
    }

    get isEmpty(): boolean {
        return this.events.length === 0 && this.reports.length === 0 && this.blocks.length === 0 && this.platformPriors <= 0;
    }
}

export interface ActorSignalBackend {
    snapshot(sender: string): ActorSignalSnapshot | null;
    mutate(sender: string, body: (state: ActorSignalSnapshot) => void): void;
    remove(sender: string): void;
    removeAll(): void;
    get trackedSenderCount(): number;
}

export class InMemoryActorSignalBackend implements ActorSignalBackend {
    private senders: Map<string, ActorSignalSnapshot> = new Map();
    private readonly maxSenders: number;

    constructor(maxSenders: number = 20000) {
        this.maxSenders = maxSenders;
    }

    snapshot(sender: string): ActorSignalSnapshot | null {
        return this.senders.get(sender) || null;
    }

    mutate(sender: string, body: (state: ActorSignalSnapshot) => void): void {
        if (!this.senders.has(sender) && this.senders.size >= this.maxSenders) {
            this.evictOldest();
        }
        const state = this.senders.get(sender) || new ActorSignalSnapshot();
        body(state);
        
        if (state.isEmpty) {
            this.senders.delete(sender);
        } else {
            this.senders.set(sender, state);
        }
    }

    remove(sender: string): void {
        this.senders.delete(sender);
    }

    removeAll(): void {
        this.senders.clear();
    }

    get trackedSenderCount(): number {
        return this.senders.size;
    }

    private evictOldest(): void {
        let oldestSender: string | null = null;
        let oldestTime = new Date(8640000000000000); // Max date

        for (const [sender, state] of this.senders.entries()) {
            const lastEvent = state.events.length > 0 ? state.events[state.events.length - 1] : null;
            const time = lastEvent ? lastEvent.at : new Date(0);
            if (time < oldestTime) {
                oldestTime = time;
                oldestSender = sender;
            }
        }

        if (oldestSender) {
            this.senders.delete(oldestSender);
        }
    }
}

export class ActorRisk {
    messagesInWindow = 0;
    distinctConversations = 0;
    repeatTargetCount = 0;
    receivedReports = 0;
    blockEvents = 0;
    subThresholdSafetyHits = 0;
    escalating = false;

    get composite(): number {
        let r = 0.0;
        r += Math.min(this.receivedReports * 0.30, 0.60);
        r += Math.min(this.blockEvents * 0.20, 0.40);
        r += Math.min(this.subThresholdSafetyHits * 0.12, 0.36);
        r += Math.min(this.distinctConversations / 40.0, 0.20);
        r += Math.min(this.messagesInWindow / 400.0, 0.10);
        return Math.min(r, 1.0);
    }

    get isElevated(): boolean {
        return this.composite >= 0.35;
    }
}

export class ActorSignalStore {
    static readonly window: number = 24 * 3600 * 1000; // ms
    static readonly patternThreshold = 3;
    static readonly patternThresholdAfterReport = 2;

    private backend: ActorSignalBackend;

    constructor(backend: ActorSignalBackend = new InMemoryActorSignalBackend()) {
        this.backend = backend;
    }

    observe(
        sender: string,
        conversation: string,
        safetyScore: number,
        routedForSafety: boolean,
        acted: boolean,
        now: Date = new Date()
    ): void {
        this.backend.mutate(sender, state => {
            state.events.push({
                at: now,
                conversation,
                safetyScore,
                routedForSafety,
                acted
            });
            state.prune(new Date(now.getTime() - ActorSignalStore.window));
        });
    }

    recordReport(sender: string, now: Date = new Date()): void {
        this.backend.mutate(sender, state => {
            state.reports.push(now);
            state.prune(new Date(now.getTime() - ActorSignalStore.window));
        });
    }

    recordBlock(sender: string, now: Date = new Date()): void {
        this.backend.mutate(sender, state => {
            state.blocks.push(now);
            state.prune(new Date(now.getTime() - ActorSignalStore.window));
        });
    }

    notePlatformPriors(sender: string, count: number): void {
        if (count <= 0) return;
        this.backend.mutate(sender, state => {
            state.platformPriors = Math.max(state.platformPriors, count);
        });
    }

    platformPriors(sender: string): number {
        const state = this.backend.snapshot(sender);
        return Math.max(0, state ? state.platformPriors : 0);
    }

    risk(sender: string, conversation: string, now: Date = new Date()): ActorRisk {
        const state = this.backend.snapshot(sender);
        const risk = new ActorRisk();
        if (!state) return risk;

        state.prune(new Date(now.getTime() - ActorSignalStore.window));

        risk.messagesInWindow = state.events.length;
        risk.distinctConversations = new Set(state.events.map(e => e.conversation)).size;
        risk.receivedReports = state.reports.length;
        risk.blockEvents = state.blocks.length;

        const here = state.events.filter(e => e.conversation === conversation);
        risk.repeatTargetCount = here.length;

        const subThreshold = here.filter(e => e.routedForSafety && !e.acted);
        risk.subThresholdSafetyHits = subThreshold.length;

        const bar = risk.receivedReports > 0
            ? ActorSignalStore.patternThresholdAfterReport
            : ActorSignalStore.patternThreshold;
        
        risk.escalating = subThreshold.length >= bar;
        return risk;
    }

    reset(sender: string): void {
        this.backend.remove(sender);
    }

    resetAll(): void {
        this.backend.removeAll();
    }

    get trackedSenderCount(): number {
        return this.backend.trackedSenderCount;
    }
}
