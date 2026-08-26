// Barrel export — single entry point for the moderation engine.
// Import from '@wayzyy/moderation-engine' in the host app.

// ---- Core engine ----
export { createEngine, ModerationEngine } from './ModerationEngine';
export type { EngineOptions, EngineConfig, ProviderConfig } from './ModerationEngine';

// ---- Types & enums ----
export {
    ModAction,
    ModCategory,
    TrustTier,
    BookingStage,
    Suspicion,
    modActionWithholdsMessage,
    getModActionLabel,
    getModActionRank,
    isContactExfiltration,
    isVerdictClean,
    cleanVerdict,
    defaultActorContext,
    newId,
} from './ModerationTypes';
export type {
    Verdict,
    Detection,
    ActorContext,
    CarrierCandidate,
    JudgementRecord,
} from './ModerationTypes';

// ---- Errors ----
export {
    ModerationError,
    ConfigError,
    ProviderError,
    BundleFormatError,
} from './Errors';

// ---- Platform adapter (for Expo/RN host apps) ----
export { setPlatformAdapter, platform } from './Platform';
export type { PlatformAdapter } from './Platform';

// ---- Runtime compatibility check ----
export { checkRuntimeCompatibility } from './RuntimeCheck';
export type { RuntimeCheckResult } from './RuntimeCheck';

// ---- Tier-3 judge types (for custom judge implementations) ----
export type { SemanticJudge, JudgeRequest, JudgeVerdict } from './SemanticJudge';
export { Decision } from './SemanticJudge';

// ---- Training store adapter (for persistence) ----
export type { TrainingStoreAdapter, TrainingSample, SampleSource } from './TrainingStore';

// ---- Abuse router (for pre-parsed weight injection) ----
export { AbuseRouter } from './AbuseRouter';
