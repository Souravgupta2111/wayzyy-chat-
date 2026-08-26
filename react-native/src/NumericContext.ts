import { CharView } from './TextPrimitives';
import { RX, OffsetTable } from './TextPrimitives';

export class NumericContext {
    private static readonly placeholder: string = "·";

    private static readonly patternSources: [string, string][] = [
        ["time", "\\b\\d{1,2}\\s*[:.]\\s*\\d{2}\\s*(?:am|pm|hrs)?\\b"],
        ["time-bare", "\\b\\d{1,2}\\s*(?:am|pm)\\b"],
        ["time-range", "\\b\\d{1,2}\\s*(?:-|to|till|until)\\s*\\d{1,2}\\s*(?:am|pm)\\b"],

        ["year", "\\b(?:19|20)\\d{2}\\b"],
        ["built-in", "\\b(?:built|renovated|since|established|est)\\D{0,6}\\d{4}\\b"],

        ["currency-pre", "(?:₹|rs\\.?|inr|\\$|usd|us\\$|€|eur|£|gbp|aed|sgd)\\s*\\d[\\d,]*(?:\\.\\d+)?"],
        ["currency-post", "\\b\\d[\\d,]*(?:\\.\\d+)?\\s*(?:rupees|rupee|rupay|rupaye|rupaiya|rupaya|rs\\b|inr|usd|dollars?|euros?|eur|pounds?|gbp|aed|k\\b|hazaar|hazar|lakh|lakhs|lac|crore|crores|taka|paise|paisa)\\b"],
        ["currency-verb", "\\b\\d[\\d,]*(?:\\.\\d+)?\\s*(?:\\w+\\s+)?(?:de\\s?dena|dedena|de\\s?do|dedo|bhej\\s?dena|bhejdena|bhej\\s?do|le\\s?lena|lelena|paid|pay|refund)\\b"],
        ["per-night", "\\b\\d[\\d,]*\\s*(?:per|a|\\/)\\s*(?:night|day|week|month|person|guest|head)\\b"],

        ["units", "\\b\\d+(?:\\.\\d+)?\\s*(?:sq\\.?\\s?(?:ft|m|feet|meters?|metres?)|sqft|sqm|km|kms|kilometer?s?|mtr|meters?|metres?|ft\\b|feet|inch(?:es)?|cm|mm|kg|kgs|gms?|grams?|lit(?:re|er)s?|ltr|ml|mins?|minutes?|hrs?|hours?|days?|nights?|weeks?|months?|years?|guests?|adults?|children|kids|infants?|people|persons?|pax|bhk|bedrooms?|beds?|bathrooms?|baths?|washrooms?|rooms?|floors?|storey|stories|balcon(?:y|ies)|star|stars|reviews?|ratings?|seats?|cars?|steps?|degrees?|°c|°f|%)\\b"],

        ["ordinal", "\\b\\d{1,2}(?:st|nd|rd|th)\\b"],
        ["date-slash", "\\b\\d{1,2}\\s*[\\/\\-.]\\s*\\d{1,2}(?:\\s*[\\/\\-.]\\s*\\d{2,4})?\\b"],
        ["date-month", "\\b\\d{1,2}\\s*(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\b"],
        ["month-date", "\\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\\s*\\d{1,2}\\b"],

        ["gstin", "\\b\\d{2}[a-z]{5}\\d{4}[a-z]\\d[a-z]{2}\\b"],
        ["pan", "\\b[a-z]{5}\\d{4}[a-z]\\b"],
        ["pincode", "\\b(?:pin\\s?-?code|pincode|pin|zip|postal\\s?code)\\D{0,8}\\d{6}\\b"],
        ["hsn", "\\b(?:hsn|sac)\\D{0,6}\\d{4,8}\\b"],

        ["flight", "\\b(?:flight|fl|pnr|train|bus|ticket|seat|gate|terminal)\\D{0,8}[a-z0-9]{0,3}\\s?\\d{1,6}\\b"],
        ["booking-ref", "\\b(?:booking|reservation|confirmation|conf|order|invoice|receipt|ref|reference|id|pnr|locator|itinerary)\\W{0,4}(?:no\\.?|number|code|id|#)?\\W{0,4}[a-z0-9][a-z0-9\\-]{3,20}\\b"],
        ["mixed-ref", "\\b[a-z]{2,8}-[a-z0-9]{3,16}\\b"],
        ["slash-ref", "\\b[a-z]{2,5}\\/\\d{2,8}(?:\\/[a-z0-9]{2,8})?\\b"],
        ["alnum-ref", "\\b[a-z]{2,5}\\d{3,10}[a-z]{0,6}\\d{0,6}\\b"],

        ["unit-no", "\\b(?:flat|apt|apartment|room|unit|block|floor|door|house|villa|plot|survey|shop|gate|tower|wing)\\s*(?:no\\.?|#)?\\s*\\d{1,5}\\b"],
        ["highway", "\\b(?:nh|sh|highway|route)\\s*-?\\s*\\d{1,3}\\b"],

        ["rating", "\\b\\d(?:\\.\\d)?\\s*(?:\\/|out of)\\s*(?:5|10)\\b"],
        ["percent", "\\b\\d{1,3}\\s*(?:%|percent|percentage)\\b"],

        ["wifi", "\\b(?:wifi|wi-fi|ssid|network)\\D{0,10}[a-z0-9_\\-]{2,20}\\b"],

        ["approx", "\\b(?:approx|about|around|roughly|nearly|almost|under|over|within)\\s*\\d{1,4}\\b"],
    ];

    private static compiled: { name: string, rx: RX }[] | null = null;
    private static chainRX: RX | null = null;

    private static get compiledPatterns() {
        if (!this.compiled) {
            this.compiled = NumericContext.patternSources.map(
                ([name, pattern]) => ({ name, rx: new RX(name, pattern) })
            );
        }
        return this.compiled;
    }

    private static get chainPattern() {
        if (!this.chainRX) {
            this.chainRX = new RX("chain", "\\d{1,5}(?:[\\s.,\\-/]{1,3}\\d{1,5}){3,}");
        }
        return this.chainRX;
    }

    static analyze(view: CharView): { view: CharView, firedRules: string[], maskedCharacterCount: number, protectedRanges: [number, number][] } {
        const text = view.text;
        if (!text) {
            return { view, firedRules: [], maskedCharacterCount: 0, protectedRanges: [] };
        }

        const maskedIndices = new Set<number>();
        const fired: string[] = [];
        const table = new OffsetTable(text);

        const protectedIndices = new Set<number>();
        const protectedRanges: [number, number][] = [];
        
        for (const match of this.chainPattern.matches(text, 1000, table)) {
            const body = match.text;
            const digitCount = (body.match(/\d/g) || []).length;
            if (digitCount >= 9 && digitCount <= 15) {
                protectedRanges.push([match.start, match.end]);
                for (let i = match.start; i < match.end; i++) {
                    protectedIndices.add(i);
                }
            }
        }

        for (const { name, rx } of this.compiledPatterns) {
            let ruleFired = false;
            for (const match of rx.matches(text, 1000, table)) {
                for (let i = match.start; i < match.end; i++) {
                    if (i < view.chars.length && /\d/.test(view.chars[i]!) && !protectedIndices.has(i)) {
                        maskedIndices.add(i);
                        ruleFired = true;
                    }
                }
            }
            if (ruleFired) {
                fired.push(name);
            }
        }

        if (maskedIndices.size === 0) {
            return { view, firedRules: [], maskedCharacterCount: 0, protectedRanges };
        }

        const chars = [...view.chars];
        for (const i of maskedIndices) {
            chars[i] = this.placeholder;
        }

        const maskedView = new CharView(chars, view.offsets, [...view.transforms, "numeric-context-mask"]);
        return {
            view: maskedView,
            firedRules: fired,
            maskedCharacterCount: maskedIndices.size,
            protectedRanges
        };
    }

    static mask(view: CharView): CharView {
        return this.analyze(view).view;
    }
}
