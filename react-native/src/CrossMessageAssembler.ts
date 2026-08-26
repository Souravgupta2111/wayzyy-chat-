import { Canonicalizer, CanonicalizerViews } from './Canonicalizer';
import { ModCategory, Detection, Suspicion, newId } from './ModerationTypes';
import { Extractors } from './Extractors';
import { NumericContext } from './NumericContext';
import { Lexicons } from './Lexicons';
import { PositionalChannels } from './PositionalChannels';

export interface AssemblyInput {
    previous: string[];
    analysed: string;
    views: CanonicalizerViews;
    effort: number;
    suppressedOnly: boolean;
    /** Invoked when assembled evidence is accepted and buffered messages are consumed. */
    consume: () => void;
}

export interface AssemblyOutput {
    crossMessage: boolean;
    detection: Detection | null;
}

/**
 * Cross-message assembly: joins the conversation window with the current
 * message and re-runs a focused extractor set (phones across messages,
 * message-initial acrostics, word/length-encoded digits, handles, emails),
 * then applies Swift's acceptance gate before anything is reported.
 */
export class CrossMessageAssembler {
    assemble(input: AssemblyInput): AssemblyOutput {
        const { previous, analysed, views, effort, suppressedOnly } = input;
        let crossMessage = false;
        let detection: Detection | null = null;

        {
            {
                const joined = [...previous, analysed].join(" ");
                const joinedViews = new Canonicalizer().build(joined);
                const prefixLength = Array.from(previous.join(" ") + " ").length;
                const currentLength = Array.from(analysed).length;
                const analysedChars = Array.from(analysed);

                const localRange = (r: [number, number], category: ModCategory): [number, number] => {
                    let contributing: number[];
                    switch (category) {
                        case ModCategory.Phone:
                            contributing = [...views.digits.offsets, ...views.compactDigits.offsets];
                            break;
                        case ModCategory.Email:
                        case ModCategory.ExternalURL:
                        case ModCategory.SocialHandle:
                        case ModCategory.PaymentHandle:
                            contributing = views.separators.offsets.filter(off => {
                                if (off < 0 || off >= currentLength || off >= analysedChars.length) return false;
                                const ch = analysedChars[off]!;
                                return /[\p{L}\p{N}]/u.test(ch) || ch === "@" || ch === ".";
                            });
                            break;
                        default:
                            contributing = [];
                    }

                    const inRange = contributing.filter(off => off >= 0 && off < currentLength);
                    if (inRange.length > 0) {
                        const lo = Math.min(...inRange);
                        const hi = Math.max(...inRange);
                        return [lo, Math.min(currentLength, hi + 1)];
                    }

                    const lo = Math.max(0, r[0] - prefixLength);
                    const hi = Math.min(currentLength, r[1] - prefixLength);
                    return lo < hi ? [lo, hi] : [0, 0];
                };

                var assembled: Detection[] = [];
                assembled.push(...Extractors.phones(joinedViews.digitsMasked, false, effort, false, 40));

                if (assembled.length === 0) {
                    const maskedCompact = Canonicalizer.expandNumberWords(
                        NumericContext.mask(joinedViews.base).filtering("compact", ch => /[\p{L}\p{N}]/u.test(ch))
                    ).filtering("digits-only", ch => /\d/.test(ch));
                    assembled.push(...Extractors.phones(maskedCompact, false, effort, false, 40));
                }

                assembled = assembled.filter(detection => {
                    if (detection.category !== ModCategory.Phone) return true;
                    if (detection.confidence >= 0.80) return true;
                    const digits = detection.canonical.replace(/\D/g, "");
                    return Extractors.isHighConfidencePhone(digits)
                        || Extractors.isHighConfidencePhone(digits.slice(-10));
                });

                const windowMsgs = [...previous, analysed];

                if (assembled.length === 0) {
                    const initials = windowMsgs
                        .map(m => m.trim().charAt(0))
                        .filter(c => c.length > 0)
                        .join("");
                    assembled.push(...Extractors.phones(new Canonicalizer().build(initials).digits, false, effort, false, 40));
                    if (assembled.length === 0 && windowMsgs.length >= 5) {
                        const letters = Array.from(initials.toLowerCase()).filter(c => /\p{L}/u.test(c)).join("");
                        if (letters.length >= 5) {
                            let hit: { name: string; confidence: number; reason: string } | null = null;
                            for (const name of Lexicons.platformsStrong) {
                                if (name.length >= 5 && letters.includes(name)) {
                                    hit = { name, confidence: 0.84, reason: "Platform name spelled by message initials" };
                                    break;
                                }
                            }
                            if (!hit
                                && PositionalChannels.looksPronounceable(letters)
                                && windowMsgs.some(message => PositionalChannels.protocolHint(message.toLowerCase()) !== null)) {
                                hit = { name: letters, confidence: 0.60, reason: `Message initials spell "${letters}"` };
                            }
                            if (hit) {
                                assembled.push({
                                    id: newId(),
                                    category: ModCategory.SocialHandle,
                                    range: [0, Math.max(1, currentLength)],
                                    surface: "", canonical: hit.name, confidence: hit.confidence,
                                    transforms: ["conversation-buffer", "positional-channel"],
                                    effort: effort + 3, reason: hit.reason
                                });
                            }
                        }
                    }
                }

                if (assembled.length === 0 && windowMsgs.length >= 9) {
                    const wordCounts = windowMsgs.map(m => m.split(/[^a-zA-Z0-9]+/).filter(w => w.length > 0).length);
                    const charCounts = windowMsgs.map(m => m.trim().length);

                    for (const [label, counts] of [["word count", wordCounts], ["message length", charCounts]] as [string, number[]][]) {
                        if (!counts.every(c => c >= 0 && c <= 10)) continue;
                        const digits = counts.map(c => String(c % 10)).join("");
                        if (!Extractors.isHighConfidencePhone(digits)) continue;
                        assembled.push({
                            id: newId(),
                            category: ModCategory.Phone,
                            range: [0, Math.max(1, currentLength)],
                            surface: "", canonical: digits, confidence: 0.82,
                            transforms: ["conversation-buffer", "positional-channel"],
                            effort: effort + 5,
                            reason: `Phone number encoded in the ${label} of consecutive messages`
                        });
                        break;
                    }
                }

                if (assembled.length === 0) {
                    const windowText = windowMsgs.join(" ").toLowerCase();
                    const locatorContext = ["booking", "ref", "reference", "confirmation",
                        "pnr", "locator", "itinerary"].some(k => windowText.includes(k));
                    const windowPlatform = Array.from(Lexicons.platformsStrong).some(p => windowText.includes(p))
                        || windowText.includes("handle");
                    if (!locatorContext) {
                        assembled.push(...Extractors.handles(
                            joinedViews.base, joinedViews.alpha, effort, windowPlatform
                        ));
                    }
                    const lowerJoined = joined.toLowerCase();
                    const windowMail = lowerJoined.includes("mail")
                        || lowerJoined.includes(" at ")
                        || joined.includes("@");
                    assembled.push(...Extractors.emails(joinedViews.base, joinedViews.separators, windowMail, effort));
                    if (assembled.length === 0) {
                        assembled.push(...Extractors.spelledEmails(joined, effort));
                        if (assembled.length === 0) {
                            assembled.push(...Extractors.spelledURLs(joined, effort));
                        }
                    }
                }

                if (assembled.length === 0) {
                    const fragments = windowMsgs
                        .map(m => m.trim())
                        .filter(m => m.length <= 8 && !m.includes(" ") && Array.from(m).every(c => /\p{L}/u.test(c)));
                    if (fragments.length >= 3) {
                        const glued = fragments.join("");
                        const windowText = windowMsgs.join(" ").toLowerCase();
                        const windowPlatform = Array.from(Lexicons.platformsStrong).some(p => windowText.includes(p))
                            || windowText.includes("handle");
                        const locatorContext = ["booking", "ref", "reference", "confirmation",
                            "pnr", "locator", "itinerary"].some(k => windowText.includes(k));
                        if (glued.length >= 8 && windowPlatform && !locatorContext
                            && Lexicons.fuzzyPlatform(glued) === null
                            && !Lexicons.platformsStrong.has(glued)) {
                            assembled.push({
                                id: newId(),
                                category: ModCategory.SocialHandle,
                                range: [0, Math.max(1, currentLength)],
                                surface: "", canonical: glued,
                                confidence: 0.78, transforms: ["conversation-buffer"],
                                effort,
                                reason: "Identifier assembled from consecutive short messages"
                            });
                        }
                    }
                }

                const first = assembled[0];
                if (first) {
                    const canon = first.canonical.toLowerCase();
                    const bogusPlatform = Lexicons.platformsStrong.has(canon)
                        || Lexicons.platformsWeak.has(canon);
                    const windowText = windowMsgs.join(" ").toLowerCase();
                    const windowPlatform = Array.from(Lexicons.platformsStrong).some(p => windowText.includes(p))
                        || windowText.includes("handle");
                    const locatorWithoutChannel = first.category === ModCategory.SocialHandle
                        && Extractors.looksLikeBookingLocator(first.canonical)
                        && !windowPlatform;
                    const isPositionalChannel = first.transforms.includes("positional-channel");
                    if ((!bogusPlatform || isPositionalChannel) && !locatorWithoutChannel) {
                        crossMessage = true;
                        input.consume();
                        detection = {
                            id: newId(),
                            category: first.category,
                            range: localRange(first.range, first.category),
                            surface: "",
                            canonical: first.canonical,
                            confidence: Math.max(first.confidence, 0.88),
                            transforms: [...first.transforms, "conversation-buffer"],
                            effort: effort + 4,
                            reason: `${first.category} assembled across recent messages`
                        };
                    }
                }
            }
        }
        return { crossMessage, detection };
    }
}
