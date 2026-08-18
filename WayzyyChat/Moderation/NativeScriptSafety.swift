// Native-script safety phrases: Devanagari and Cyrillic.
//
// Why these exist even though transliteration and the phonetic skeleton already fold
// Devanagari into Latin: folding covers *words*, and the safety floor matches *phrases*.
// A threat like "मैं तुझे मार दूंगा" only becomes detectable at Tier 1 if the phrase itself
// is present in some canonical form. Transliterating it produces "main tujhe mar dunga",
// which matches the romanised list — but only when the romanisation the fold produces
// happens to equal the romanisation someone wrote down by hand, and it frequently does not
// (`mar` vs `maar`, `tujhe` vs `tuje`).
//
// Listing the phrases in their native form removes that coincidence dependency: the message
// matches directly, before any fold, in the script it was written in.
//
// Cyrillic is included because Goa's inbound market includes a substantial Russian-speaking
// population. Note that the canonicaliser homoglyph-folds Cyrillic toward Latin, so Cyrillic
// phrases are additionally registered in their folded form — a Cyrillic threat is otherwise
// mangled into Latin-ish text before the phrase floor ever sees it.

import Foundation

struct NativeScriptSafety {

    // MARK: - Devanagari

    static let devanagariThreats: [String] = [
        "मार दूंगा", "मार दूँगा", "मार डालूंगा", "जान से मार दूंगा",
        "तुझे मार दूंगा", "तुम्हें मार दूंगा", "मैं तुझे मार दूंगा",
        "तेरे घर आ जाऊंगा", "तेरे घर आऊंगा", "घर पर आ जाऊंगा",
        "तोड़ दूंगा", "हाथ पैर तोड़ दूंगा", "टांग तोड़ दूंगा",
        "जला दूंगा", "आग लगा दूंगा",
        "देख लूंगा", "तुझे देख लूंगा", "छोड़ूंगा नहीं",
        "अंजाम भुगतना", "पछताएगा", "पछताओगे",
        "खत्म कर दूंगा", "जिंदा नहीं छोड़ूंगा",
    ]

    static let devanagariHarassment: [String] = [
        "तू बेकार है", "तुम बेकार हो", "तू नालायक है",
        "तेरी औकात", "तेरी हिम्मत", "बेशरम",
        "तू पागल है", "तुम पागल हो", "मूर्ख हो तुम",
        "तेरे जैसे लोग", "तेरी शक्ल",
    ]

    static let devanagariCoercion: [String] = [
        "वरना", "नहीं तो", "अगर नहीं", "नहीं दिया तो",
        "पैसे वापस करो वरना", "रिफंड दो वरना",
        "बदनाम कर दूंगा", "रेटिंग खराब कर दूंगा",
        "झूठा रिव्यू", "फेक रिव्यू डाल दूंगा",
    ]

    static let devanagariSexual: [String] = [
        "तेरा शरीर", "अकेली हो", "अकेली रहती हो",
        "रात को अकेली", "कपड़े उतार",
    ]

    static let devanagariSelfHarm: [String] = [
        "मरना चाहता हूं", "मरना चाहती हूं", "जान दे दूंगा",
        "आत्महत्या", "जीना नहीं चाहता", "जीने का मन नहीं",
    ]

    // MARK: - Cyrillic

    static let cyrillicThreats: [String] = [
        "я тебя убью", "убью тебя", "убью", "прикончу",
        "я приду к тебе", "приду к тебе домой", "найду тебя",
        "сломаю", "сломаю тебе", "изобью",
        "ты пожалеешь", "пожалеешь об этом", "тебе конец",
        "сожгу", "спалю",
    ]

    static let cyrillicHarassment: [String] = [
        "ты никчёмный", "ты никчемный", "ты идиот", "ты дура",
        "ты тупой", "ты тупая", "мерзкий человек", "ничтожество",
    ]

    static let cyrillicCoercion: [String] = [
        "иначе", "если не", "или я", "верни деньги иначе",
        "напишу фальшивый отзыв", "испорчу рейтинг", "оклевещу",
    ]

    static let cyrillicSelfHarm: [String] = [
        "хочу умереть", "не хочу жить", "покончу с собой",
    ]

    // MARK: - Registration
    //
    // Cyrillic is registered twice: once natively, and once through the canonicaliser's own
    // homoglyph fold, because by the time the phrase floor runs the Cyrillic text has already
    // been partially transliterated toward Latin.

    /// Mirrors the canonicaliser's `confusable-fold` pass so a Cyrillic phrase is registered
    /// in the same shape the phrase floor will actually see.
    static func confusableFold(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            if let mapped = Lex.confusables[ch] {
                out.append(mapped)
            } else if let mapped = Lex.confusables[Character(String(ch).lowercased())] {
                out.append(mapped)
            } else {
                out += String(ch).lowercased()
            }
        }
        return out
    }

    static func foldedCyrillic(_ phrases: [String]) -> [String] {
        // Only keep folds that actually differ, so the lists do not double in size for no
        // benefit when a phrase contains no confusable characters.
        phrases.compactMap { phrase in
            let folded = confusableFold(phrase)
            return folded == phrase.lowercased() ? nil : folded
        }
    }

    static var allThreats: [String] {
        devanagariThreats + cyrillicThreats + foldedCyrillic(cyrillicThreats)
    }

    static var allHarassment: [String] {
        devanagariHarassment + cyrillicHarassment + foldedCyrillic(cyrillicHarassment)
    }

    static var allCoercion: [String] {
        devanagariCoercion + cyrillicCoercion + foldedCyrillic(cyrillicCoercion)
    }

    static var allSexual: [String] { devanagariSexual }

    static var allSelfHarm: [String] {
        devanagariSelfHarm + cyrillicSelfHarm + foldedCyrillic(cyrillicSelfHarm)
    }

    /// Register native-script phrases into the shared phrase floor. Runs once.
    ///
    /// Appended rather than interleaved so the existing English and romanised entries keep
    /// their scan order: `scan` returns on first match, so ordering determines which phrase
    /// is reported when several are present.
    static let register: Void = {
        Lex.requireMutable("Native-script phrase registration")
        Lex.threatPhrases     += allThreats
        Lex.harassmentPhrases += allHarassment
        Lex.coercionPhrases   += allCoercion
        Lex.sexualPhrases     += allSexual
        Lex.selfHarmPhrases   += allSelfHarm
    }()
}
