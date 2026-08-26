import { ActorContext } from './ModerationTypes';

export interface ConversationMessage {
    text: string;
    at: Date;
}

export class ConversationBufferSnapshot {
    messages: ConversationMessage[] = [];

    trim(depth: number, cutoff: Date) {
        this.messages = this.messages.filter(m => m.at >= cutoff);
        if (this.messages.length > depth) {
            this.messages = this.messages.slice(this.messages.length - depth);
        }
    }
}

export interface ConversationBufferBackend {
    snapshot(key: string): ConversationBufferSnapshot | null;
    mutate(key: string, body: (state: ConversationBufferSnapshot) => void): void;
    remove(key: string): void;
    evict(before: Date, maxConversations: number): void;
    get trackedCount(): number;
}

export class InMemoryConversationBufferBackend implements ConversationBufferBackend {
    private buffers: Map<string, ConversationBufferSnapshot> = new Map();

    snapshot(key: string): ConversationBufferSnapshot | null {
        return this.buffers.get(key) || null;
    }

    mutate(key: string, body: (state: ConversationBufferSnapshot) => void): void {
        const state = this.buffers.get(key) || new ConversationBufferSnapshot();
        body(state);
        if (state.messages.length === 0) {
            this.buffers.delete(key);
        } else {
            this.buffers.set(key, state);
        }
    }

    remove(key: string): void {
        this.buffers.delete(key);
    }

    evict(before: Date, maxConversations: number): void {
        // Remove empty buffers or those where latest message is before cutoff
        for (const [key, state] of this.buffers.entries()) {
            if (state.messages.length === 0 || state.messages[state.messages.length - 1].at < before) {
                this.buffers.delete(key);
            }
        }

        // If still over max, evict oldest
        if (this.buffers.size > maxConversations) {
            const entries = Array.from(this.buffers.entries());
            entries.sort((a, b) => {
                const aTime = a[1].messages[a[1].messages.length - 1].at.getTime();
                const bTime = b[1].messages[b[1].messages.length - 1].at.getTime();
                return aTime - bTime;
            });
            const toRemove = entries.slice(0, this.buffers.size - maxConversations);
            for (const [key] of toRemove) {
                this.buffers.delete(key);
            }
        }
    }

    get trackedCount(): number {
        return this.buffers.size;
    }
}

export class ConversationBuffers {
    private backend: ConversationBufferBackend;
    private window: number;
    private depth: number;
    private maxConversations: number;

    constructor(
        window: number = 15 * 60 * 1000, // 15 mins in ms
        depth: number = 14,
        maxConversations: number = 512,
        backend: ConversationBufferBackend = new InMemoryConversationBufferBackend()
    ) {
        this.window = window;
        this.depth = depth;
        this.maxConversations = maxConversations;
        this.backend = backend;
    }

    private key(actor: ActorContext): string {
        return `${actor.conversationID}|${actor.senderID}`;
    }

    private get cutoff(): Date {
        return new Date(Date.now() - this.window);
    }

    remember(text: string, actor: ActorContext) {
        const now = new Date();
        const cutoffTime = new Date(now.getTime() - this.window);
        this.backend.mutate(this.key(actor), snapshot => {
            snapshot.messages.push({ text, at: now });
            snapshot.trim(this.depth, cutoffTime);
        });
        this.backend.evict(cutoffTime, this.maxConversations);
    }

    recent(actor: ActorContext): string[] {
        const cutoff = this.cutoff;
        const snapshot = this.backend.snapshot(this.key(actor));
        if (!snapshot) return [];
        return snapshot.messages
            .filter(m => m.at >= cutoff)
            .map(m => m.text);
    }

    reset(actor: ActorContext) {
        this.backend.remove(this.key(actor));
    }

    consume(actor: ActorContext) {
        this.reset(actor);
    }

    get trackedCount(): number {
        return this.backend.trackedCount;
    }
}
