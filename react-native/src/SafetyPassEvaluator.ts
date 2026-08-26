import { Canonicalizer, CanonicalizerViews } from './Canonicalizer';
import { ModCategory } from './ModerationTypes';
import { SafetyRules, Finding } from './SafetyRules';
import { SafetyScores, SignalDerivedSafetyClassifier, applySafetyCalibration, SafetyHead } from './SafetyClassifier';
import { EscalationAnalyser } from './Escalation';
import { LeverTaxonomy } from './LanguageFolding';
import { SemanticRetriever, RetrievalResult } from './SemanticRetrieval';
import { Signals } from './Scorer';
import { Lexicons } from './Lexicons';

export interface SafetyPassInput {
    analysed: string;
    views: CanonicalizerViews;
    signals: Signals;
}

export interface SafetyPassOutput {
    findings: Finding[];
    classification: SafetyScores;
    layer3: ReturnType<typeof applySafetyCalibration>;
    safetySimilarity: number;
    innocentSimilarity: number;
    safetyRetrieval: ReturnType<SemanticRetriever['safetyRetrieval']>;
    contactRetrieval: RetrievalResult | null;
}

/**
 * Deterministic safety rules plus Tier-2 safety retrieval and the derived
 * safety classifier, producing calibrated findings for policy.
 */
export class SafetyPassEvaluator {
    private readonly classifier: SignalDerivedSafetyClassifier;
    private readonly retriever: SemanticRetriever;

    constructor(classifier: SignalDerivedSafetyClassifier, retriever: SemanticRetriever) {
        this.classifier = classifier;
        this.retriever = retriever;
    }

    run(input: SafetyPassInput): SafetyPassOutput {
        const { analysed, views, signals } = input;

        // Safety Rules Evaluation
        const safetyFindings: Finding[] = SafetyRules.evaluate(views.base, views.alpha, views.alphaCompact, views.hinglishSkeleton, analysed);

        const bargain = LeverTaxonomy.bargainSignals(analysed);
        
        const safetyRetrieval = this.retriever.safetyRetrieval(analysed);
        if (safetyRetrieval) {
            const semantic = this.retriever.safetyFinding(safetyRetrieval, analysed.length);
            if (semantic
                && !safetyFindings.some(f => f.category === semantic.category)
                && SafetyRules.semanticFindingHolds(semantic, analysed.toLowerCase())) {
                safetyFindings.push(semantic);
            }
        }
        const contactRetrieval = this.retriever.retrieve(analysed);
        const safetySimilarity = safetyRetrieval ? safetyRetrieval.similarity : 0.0;
        const innocentSimilarity = contactRetrieval ? contactRetrieval.negativeSimilarity : 0.0;

        const classification = this.classifier.classify({
            text: analysed,
            deterministicFindings: safetyFindings,
            safetySimilarity: safetySimilarity,
            innocentSimilarity: innocentSimilarity,
            addressesPerson: EscalationAnalyser.addressesPerson(views.alpha) || EscalationAnalyser.addressesPersonNativeScript(analysed),
            conditionalDemand: EscalationAnalyser.conditionalDemand(views.base.text) || EscalationAnalyser.nativeConditionalDemand(analysed) || bargain.isBargain,
            propertyDirected: SafetyPassEvaluator.mentionsProperty(views.alpha),
            reviewBargainScore: bargain.coercionPrior
        });

        if (bargain.coercionPrior > 0) {
            classification.raise(SafetyHead.coercion, bargain.coercionPrior);
        }
        if (bargain.coercionPrior >= 0.55) {
            classification.set(SafetyHead.legitimateComplaint, 0);
        }

        const layer3 = applySafetyCalibration(this.classifier.calibration, classification, analysed.length);
        if (layer3.finding && !safetyFindings.some(f => f.category === layer3.finding!.category)) {
            safetyFindings.push(layer3.finding);
        }

        if (signals.offPlatformIntent && signals.offPlatformPhrase) {
            const phrase = signals.offPlatformPhrase;
            const s = views.base.text.indexOf(phrase);
            if (s !== -1) {
                const e = s + phrase.length;
                const orig = views.base.originalRange(s, e);
                if (orig) {
                    safetyFindings.push({
                        category: ModCategory.Scam,
                        confidence: 0.80,
                        phrase,
                        range: orig
                    });
                }
            }
        }
        return {
            findings: safetyFindings,
            classification,
            layer3,
            safetySimilarity,
            innocentSimilarity,
            safetyRetrieval,
            contactRetrieval
        };
    }

    static mentionsProperty(alpha: import('./Canonicalizer').CharView): boolean {
        for (const token of Canonicalizer.tokenize(alpha)) {
            if (token.isWord && Lexicons.propertyTargets.has(token.text)) {
                return true;
            }
        }
        return false;
    }
}
