import { Lexicons } from './Lexicons';

export class NativeScriptSafety {
    static devanagariThreats: string[] = [
        "मार दूंगा", "मार दूँगा", "मार डालूंगा", "जान से मार दूंगा",
        "तुझे मार दूंगा", "तुम्हें मार दूंगा", "मैं तुझे मार दूंगा",
        "तेरे घर आ जाऊंगा", "तेरे घर आऊंगा", "घर पर आ जाऊंगा",
        "तोड़ दूंगा", "हाथ पैर तोड़ दूंगा", "टांग तोड़ दूंगा",
        "जला दूंगा", "आग लगा दूंगा",
        "देख लूंगा", "तुझे देख लूंगा", "छोड़ूंगा नहीं",
        "अंजाम भुगतना", "पछताएगा", "पछताओगे",
        "खत्म कर दूंगा", "जिंदा नहीं छोड़ूंगा",
    ];

    static devanagariHarassment: string[] = [
        "तू बेकार है", "तुम बेकार हो", "तू नालायक है",
        "तेरी औकात", "तेरी हिम्मत", "बेशरम",
        "तू पागल है", "तुम पागल हो", "मूर्ख हो तुम",
        "तेरे जैसे लोग", "तेरी शक्ल",
    ];

    static devanagariCoercion: string[] = [
        "वरना", "नहीं तो", "अगर नहीं", "नहीं दिया तो",
        "पैसे वापस करो वरना", "रिफंड दो वरना",
        "बदनाम कर दूंगा", "रेटिंग खराब कर दूंगा",
        "झूठा रिव्यू", "फेक रिव्यू डाल दूंगा",
    ];

    static devanagariSexual: string[] = [
        "तेरा शरीर", "अकेली हो", "अकेली रहती हो",
        "रात को अकेली", "कपड़े उतार",
    ];

    static devanagariSelfHarm: string[] = [
        "मरना चाहता हूं", "मरना चाहती हूं", "जान दे दूंगा",
        "आत्महत्या", "जीना नहीं चाहता", "जीने का मन नहीं",
    ];

    static cyrillicThreats: string[] = [
        "я тебя убью", "убью тебя", "убью", "прикончу",
        "я приду к тебе", "приду к тебе домой", "найду тебя",
        "сломаю", "сломаю тебе", "изобью",
        "ты пожалеешь", "пожалеешь об этом", "тебе конец",
        "сожгу", "спалю",
    ];

    static cyrillicHarassment: string[] = [
        "ты никчёмный", "ты никчемный", "ты идиот", "ты дура",
        "ты тупой", "ты тупая", "мерзкий человек", "ничтожество",
    ];

    static cyrillicCoercion: string[] = [
        "иначе", "если не", "или я", "верни деньги иначе",
        "напишу фальшивый отзыв", "испорчу рейтинг", "оклевещу",
    ];

    static cyrillicSelfHarm: string[] = [
        "хочу умереть", "не хочу жить", "покончу с собой",
    ];

    static confusableFold(s: string): string {
        let out = "";
        for (const ch of s) {
            const mapped = Lexicons.confusables[ch] || Lexicons.confusables[ch.toLowerCase()];
            if (mapped) {
                out += mapped;
            } else {
                out += ch.toLowerCase();
            }
        }
        return out;
    }

    static foldedCyrillic(phrases: string[]): string[] {
        return phrases.map(phrase => {
            const folded = this.confusableFold(phrase);
            return folded === phrase.toLowerCase() ? null : folded;
        }).filter((f): f is string => f !== null);
    }

    static get allThreats(): string[] {
        return [...this.devanagariThreats, ...this.cyrillicThreats, ...this.foldedCyrillic(this.cyrillicThreats)];
    }

    static get allHarassment(): string[] {
        return [...this.devanagariHarassment, ...this.cyrillicHarassment, ...this.foldedCyrillic(this.cyrillicHarassment)];
    }

    static get allCoercion(): string[] {
        return [...this.devanagariCoercion, ...this.cyrillicCoercion, ...this.foldedCyrillic(this.cyrillicCoercion)];
    }

    static get allSexual(): string[] {
        return this.devanagariSexual;
    }

    static get allSelfHarm(): string[] {
        return [...this.devanagariSelfHarm, ...this.cyrillicSelfHarm, ...this.foldedCyrillic(this.cyrillicSelfHarm)];
    }

    private static registered = false;

    static register() {
        if (this.registered) return;
        this.registered = true;
        Lexicons.threatPhrases.push(...this.allThreats);
        Lexicons.harassmentPhrases.push(...this.allHarassment);
        Lexicons.coercionPhrases.push(...this.allCoercion);
        Lexicons.sexualPhrases.push(...this.allSexual);
        Lexicons.selfHarmPhrases.push(...this.allSelfHarm);
    }
}
