import { Canonicalizer, CanonicalizerViews } from './Canonicalizer';
import { ModCategory, Detection, newId } from './ModerationTypes';
import { Extractors } from './Extractors';
import { PositionalChannels } from './PositionalChannels';
import { Signals } from './Scorer';

export interface CascadeInput {
    analysed: string;
    views: CanonicalizerViews;
    signals: Signals;
    effort: number;
    allowExpensiveTiers: boolean;
}

export interface CascadeOutput {
    detections: Detection[];
    /** A phone-shaped run existed but numeric context suppressed it. */
    suppressedOnly: boolean;
}

/**
 * Tier-1 deterministic extraction cascade: every contact extractor in Swift's
 * order, over the canonicalizer's derived views.
 */
export class DetectionCascade {
    run(input: CascadeInput): CascadeOutput {
        const { analysed, views, signals, effort, allowExpensiveTiers } = input;
        let detections: Detection[] = [];

        const allDigits = views.digits.text;
        const launderedPhone = Extractors.isHighConfidencePhone(allDigits);

        const maskedPhones = Extractors.phones(views.digitsMasked, false, effort);
        const rawPhones = Extractors.phones(views.digits, !launderedPhone, effort);

        const suppressedOnly = maskedPhones.length === 0 && rawPhones.length > 0 && !launderedPhone;
        detections.push(...(maskedPhones.length === 0 ? rawPhones : maskedPhones));

        if (!detections.some(d => d.category === ModCategory.Phone) && signals.hasContactIntent) {
            const streamEmpty = views.digitsMasked.text.length === 0;
            const stream = streamEmpty ? views.digits.text : views.digitsMasked.text;
            const offsets = streamEmpty ? views.digits.offsets : views.digitsMasked.offsets;
            if (stream.length >= 10 && stream.length <= 13) {
                const lo = offsets.length > 0 ? Math.min(...offsets) : 0;
                const hi = (offsets.length > 0 ? Math.max(...offsets) : lo) + 1;
                detections.push({
                    id: newId(),
                    category: ModCategory.Phone,
                    range: [lo, Math.min(hi, Array.from(analysed).length)],
                    surface: "",
                    canonical: stream,
                    confidence: 0.86,
                    transforms: views.digitsMasked.transforms,
                    effort: effort + 2,
                    reason: `Sender labelled this as their number and gave ${stream.length} digits`
                });
            }
        }

        if (detections.length === 0) {
            detections.push(...Extractors.phones(views.compactDigits, false, effort));
        }

        if (detections.length === 0) {
            detections.push(...Extractors.phones(views.romanDigits, false, effort));
        }

        if (detections.length === 0) {
            detections.push(...Extractors.phones(views.digitsReversed, false, effort, true));
        }

        detections.push(...Extractors.emails(views.base, views.separators, signals.mailKeyword, effort));
        detections.push(...Extractors.urls(views.base, false, effort));
        detections.push(...Extractors.urls(views.separators, false, effort));
        detections.push(...Extractors.urls(views.separatorsAlt, false, effort));
        detections.push(...Extractors.spelledURLs(analysed, effort));
        detections.push(...Extractors.emails(views.separatorsAlt, views.separatorsAlt, signals.mailKeyword, effort));
        detections.push(...Extractors.platformSteering(
            views.base, views.alpha, views.compact, views.alphaCompact,
            signals.hasContactIntent, signals.offPlatformIntent, effort
        ));
        detections.push(...Extractors.handles(
            views.base, views.alpha, effort,
            signals.hasContactIntent || signals.offPlatformIntent
        ));
        detections.push(...Extractors.leetDigitRuns(views.base, views.compact, effort));
        detections.push(...Extractors.bareIdentifiers(
            views.base,
            Canonicalizer.tokenize(views.base).filter(t => t.isWord).length,
            signals.hasContactIntent || signals.offPlatformIntent,
            effort
        ));
        detections.push(...Extractors.payments(views.base, views.raw, signals.paymentKeyword, effort));
        detections.push(...Extractors.payments(views.separators, views.raw, signals.paymentKeyword, effort));

        if (allowExpensiveTiers) {
            detections.push(...Extractors.encoded(views.raw, views.base, effort));
            detections.push(...PositionalChannels.detect(analysed, views.base, views.raw, effort));
        }

        detections = detections.filter(d =>
            !(d.category === ModCategory.SocialHandle
                && Extractors.looksLikeBookingLocator(d.canonical)
                && !signals.hasContactIntent
                && !signals.offPlatformIntent)
        );

        if (detections.length === 0) {
            const acrosticDigits = Canonicalizer.expandNumberWords(views.acrostic).filtering("digits-only", ch => /\d/.test(ch));
            detections.push(...Extractors.phones(acrosticDigits, false, effort + 3));
        }
        return { detections, suppressedOnly };
    }
}
