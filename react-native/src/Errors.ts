/** Base class for all engine errors — catch this instead of generic Error. */
export class ModerationError extends Error {
    constructor(message: string) {
        super(message);
        this.name = 'ModerationError';
    }
}

/** Invalid engine/provider configuration. */
export class ConfigError extends ModerationError {
    constructor(message: string) {
        super(message);
        this.name = 'ConfigError';
    }
}

/** A Tier-3 provider call failed after all retries. Carries the HTTP status when known. */
export class ProviderError extends ModerationError {
    readonly status?: number;
    readonly retryAfterMs?: number;

    constructor(message: string, status?: number, retryAfterMs?: number) {
        super(message);
        this.name = 'ProviderError';
        this.status = status;
        this.retryAfterMs = retryAfterMs;
    }
}

/** Router weights / lexicon bundle failed validation. */
export class BundleFormatError extends ModerationError {
    constructor(message: string) {
        super(message);
        this.name = 'BundleFormatError';
    }
}
