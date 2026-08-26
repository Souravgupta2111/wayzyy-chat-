export enum LeverClass {
    lawful = "lawful",
    illegitimate = "illegitimate",
    unknown = "unknown"
}

export class LeverTaxonomy {
    static lawful: string[] = [
        "report", "reporting", "report you", "report this", "report it",
        "complain", "complaint", "customer care", "customer support",
        "support team", "platform", "wayzyy support", "helpdesk",
        "police", "fir", "legal notice", "lawyer", "court", "consumer forum",
        "consumer court", "bank", "chargeback", "dispute the charge",
        "honest review", "leave a review", "write a review", "bad review",
        "negative review", "low rating", "one star", "1 star",
        "cancel the booking", "cancel my booking", "cancel and rebook",
        "report karunga", "report karenge", "complaint karunga",
        "police me jaunga", "police ko bataunga", "consumer court jaunga",
        "bank se dispute", "review likhunga", "review dunga",
    ];

    static illegitimate: string[] = [
        "fake review", "fake reviews", "fake bad review", "fake bad reviews",
        "false review", "false reviews", "fake rating", "fake ratings",
        "review bomb", "review bombing", "bombard your reviews",
        "ruin your rating", "ruin your ratings", "destroy your rating",
        "destroy your ratings", "ruin your business", "destroy your business",
        "tank your rating", "trash your rating",
        "defame", "defamation", "slander", "spread lies", "tell lies about",
        "say you have bedbugs", "say your place has bedbugs",
        "tell everyone you", "post lies",
        "trash the place", "trash your place", "wreck the place",
        "damage your property", "break your stuff", "break the furniture",
        "smash your", "burn your",
        "post your number", "share your number", "post your address",
        "share your address", "post your photos", "share your photos",
        "leak your", "dox", "doxx", "expose you online",
        "tell your employer", "call your boss", "tell your boss",
        "tell your family", "tell your wife", "tell your husband",
        "tell your neighbours", "tell your neighbors", "tell your community",
        "immigration", "visa cancelled", "get you deported", "deport you",
        "report you to immigration",
        "fake review dunga", "jhoota review", "jhootha review",
        "review kharab kar dunga", "review kharab kar denge",
        "rating kharab kar dunga", "rating kharab kar denge",
        "badnaam kar dunga", "badnaam karunga", "izzat kharab kar dunga",
        "tera business barbaad", "business barbaad kar dunga",
        "sabko bata dunga", "sab ko bata dunga",
        "ghar pe aa jaunga", "tere ghar aa jaunga",
    ];

    private static concessionCues: string[] = [
        "refund", "discount", "waive", "waiver", "comp ", "compensate",
        "cleaning fee", "paisa", "money back", "pay me", "cover the",
        "free night", "penalty-free", "penalty free", "half back",
        "percent back", "% back", "% off", "quietly",
    ];

    private static reputationCues: string[] = [
        "review", "rating", "ratings", "stars", "star review",
        "1 star", "one star", "5 star", "five star", "public post",
        "post this", "posting this",
    ];

    private static exchangeCues: string[] = [
        " or ", " or i", " unless ", " otherwise", " warna ",
        " nahi to ", " nahi toh ", " nahin to ", " nahin toh ",
        " nhi to ", " nhi toh ", " varna ",
        " still leave", " still give", " still keep",
        " stays a", " in exchange", " if you", " if i",
        "won't mention", "will not mention",
    ];

    private static impliedThreatCues: string[] = [
        "you don't want", "you dont want", "you wouldn't want", "you wouldnt want",
        "you'll regret", "you will regret", "youll regret",
        "you don't want this", "going on my public",
    ];

    private static privateSettleCues: string[] = [
        "between us", "between ourselves", "between ourselves only",
        "off the record", "keep this private", "keep it private",
        "settle this between", "sort this between",
    ];

    private static publicPressureCues: string[] = [
        "escalate it publicly", "escalate this publicly", "escalate publicly",
        "go public", "going public", "make this public", "make it public",
        "post this publicly",
    ];

    private static officialRemedyCues: string[] = [
        "police", "fir", "chargeback", "wayzyy support", "wayzyy",
        "the platform", "consumer forum", "consumer court", "legal notice",
    ];

    private static hasCue(haystack: string, cues: string[]): boolean {
        return cues.some(cue => haystack.includes(cue));
    }

    static bargainSignals(text: string): BargainSignals {
        const h = ` ${HinglishFold.foldOtherwise(text).toLowerCase()} `;
        const s = new BargainSignals();
        s.demand = this.hasCue(h, this.concessionCues) || h.includes("%");
        s.reputation = this.hasCue(h, this.reputationCues);
        s.exchange = this.hasCue(h, this.exchangeCues) || h.includes("if you") || h.startsWith(" if ");
        s.impliedThreat = this.hasCue(h, this.impliedThreatCues);
        s.officialRemedy = this.hasCue(h, this.officialRemedyCues);
        s.privateSettle = this.hasCue(h, this.privateSettleCues);
        s.publicPressure = this.hasCue(h, this.publicPressureCues);
        return s;
    }

    static isReviewBargain(text: string): boolean {
        return this.bargainSignals(text).isBargain;
    }

    static classify(text: string): LeverClass {
        const haystack = HinglishFold.foldOtherwise(text).toLowerCase();
        for (const term of this.illegitimate) {
            if (haystack.includes(term)) return LeverClass.illegitimate;
        }
        if (this.isReviewBargain(haystack)) return LeverClass.illegitimate;
        for (const term of this.lawful) {
            if (haystack.includes(term)) return LeverClass.lawful;
        }
        return LeverClass.unknown;
    }

    static supportsCoercionFinding(text: string): boolean {
        return this.classify(text) === LeverClass.illegitimate;
    }
}

export class BargainSignals {
    demand = false;
    reputation = false;
    exchange = false;
    impliedThreat = false;
    officialRemedy = false;
    privateSettle = false;
    publicPressure = false;

    get isBargain(): boolean {
        if (this.officialRemedy) return false;
        if (this.privateSettle && this.publicPressure) return true;
        if (this.impliedThreat && this.reputation) return true;
        return this.demand && this.reputation && this.exchange;
    }

    get coercionPrior(): number {
        if (this.officialRemedy) return 0;
        if (this.privateSettle && this.publicPressure) return 0.80;
        if (this.impliedThreat && this.reputation) return 0.78;
        if (this.demand && this.reputation && this.exchange) return 0.82;
        if (this.demand && this.reputation) return 0.46;
        if (this.reputation && this.exchange) return 0.42;
        return 0;
    }
}

export enum TargetClass {
    person = "person",
    property = "property",
    group = "group",
    selfDirected = "selfDirected",
    unknown = "unknown"
}

export class HinglishFold {
    static readonly devanagariToLatin: Record<string, string> = {
        "अ": "a", "आ": "a", "इ": "i", "ई": "i", "उ": "u", "ऊ": "u",
        "ए": "e", "ऐ": "ai", "ओ": "o", "औ": "au", "ऋ": "ri",
        "क": "k", "ख": "kh", "ग": "g", "घ": "gh", "ङ": "n",
        "च": "ch", "छ": "chh", "ज": "j", "झ": "jh", "ञ": "n",
        "ट": "t", "ठ": "th", "ड": "d", "ढ": "dh", "ण": "n",
        "त": "t", "थ": "th", "द": "d", "ध": "dh", "न": "n",
        "प": "p", "फ": "ph", "ब": "b", "भ": "bh", "म": "m",
        "य": "y", "र": "r", "ल": "l", "व": "v",
        "श": "sh", "ष": "sh", "स": "s", "ह": "h",
        "ळ": "l", "क़": "k", "ख़": "kh", "ग़": "g", "ज़": "z",
        "ड़": "r", "ढ़": "rh", "फ़": "f",
        "ा": "a", "ि": "i", "ी": "i", "ु": "u", "ू": "u",
        "े": "e", "ै": "ai", "ो": "o", "ौ": "au", "ृ": "ri",
        "्": "", "ं": "n", "ँ": "n", "ः": "h", "ऽ": "",
        "़": "",
    };

    static containsDevanagari(s: string): boolean {
        for (const char of s) {
            const code = char.charCodeAt(0);
            if (code >= 0x0900 && code <= 0x097F) return true;
        }
        return false;
    }

    static transliterate(s: string): string {
        let out = "";
        for (const char of s) {
            out += this.devanagariToLatin[char] ?? char;
        }
        return out;
    }

    private static digraphs: [string, string][] = [
        ["chh", "c"], ["shh", "s"],
        ["bh", "b"], ["ph", "f"], ["dh", "d"], ["gh", "g"],
        ["jh", "j"], ["kh", "k"], ["th", "t"], ["ch", "c"], ["sh", "s"],
        ["ee", "i"], ["oo", "u"], ["aa", "a"], ["ii", "i"], ["uu", "u"],
        ["ck", "k"], ["kk", "k"],
    ];

    private static equivalents: Record<string, string> = {
        "w": "v", "z": "j", "q": "k",
    };

    static skeleton(word: string): string {
        let s = word.toLowerCase();
        for (const [from, to] of this.digraphs) {
            s = s.split(from).join(to);
        }

        const vowels = new Set(["a", "e", "i", "o", "u"]);
        let out = "";
        let previous: string | null = null;

        for (let i = 0; i < s.length; i++) {
            const ch = s[i];
            if (!/[a-z0-9]/.test(ch)) continue;
            
            const mapped = this.equivalents[ch] ?? ch;
            if (i > 0 && vowels.has(mapped)) continue;
            if (mapped === previous) continue;
            
            out += mapped;
            previous = mapped;
        }
        return out;
    }

    private static otherwiseRX = /\b(?:warnaa?|varnaa?|nahi+n?\s+toh?|nhi+\s+toh?)\b/gi;

    static foldOtherwise(text: string): string {
        let s = text;
        const replacements: [string, string][] = [
            ["नहीं तो", "warna"], ["नही तो", "warna"],
            ["वरना", "warna"], ["वर्ना", "warna"],
        ];
        
        for (const [from, to] of replacements) {
            s = s.split(from).join(to);
        }
        
        return s.replace(this.otherwiseRX, "warna");
    }

    static skeletonPhrase(text: string): string {
        return this.transliterate(text)
            .split(/[^a-zA-Z0-9]+/)
            .map(word => this.skeleton(word))
            .filter(word => word.length > 0)
            .join(" ");
    }

    static readonly minSkeletonLength = 4;

    static skeletonSet(terms: string[] | Set<string>): Set<string> {
        const out = new Set<string>();
        for (const term of terms) {
            const s = this.skeleton(term);
            if (s.length >= this.minSkeletonLength) {
                out.add(s);
            }
        }
        return out;
    }
}
