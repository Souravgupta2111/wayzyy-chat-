// Static vocabulary: platforms, TLDs, payment suffixes, profanity, person and property targets, stoplists.

import Foundation

enum Lex {

    static let invisibleScalars: Set<UInt32> = {
        var s = Set<UInt32>()
        s.formUnion(0x200B...0x200F)
        s.formUnion(0x202A...0x202E)
        s.formUnion(0x2060...0x2064)
        s.formUnion(0x206A...0x206F)
        s.formUnion(0xFE00...0xFE0F)
        s.formUnion(0x20D0...0x20F0)
        s.formUnion(0xE0000...0xE007F)
        s.insert(0x00AD)
        s.insert(0x034F)
        s.insert(0x180E)
        s.insert(0xFEFF)
        s.insert(0x20E3)
        return s
    }()

    static let confusables: [Character: Character] = [
        "а": "a", "б": "b", "в": "b", "г": "r", "е": "e", "ѕ": "s", "і": "i",
        "ј": "j", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c",
        "т": "t", "у": "y", "х": "x", "ѡ": "w", "ԁ": "d", "ԛ": "q", "ա": "w",
        "А": "a", "В": "b", "Е": "e", "К": "k", "М": "m", "Н": "h", "О": "o",
        "Р": "p", "С": "c", "Т": "t", "У": "y", "Х": "x",
        "α": "a", "β": "b", "γ": "y", "ε": "e", "ζ": "z", "η": "n", "ι": "i",
        "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "χ": "x",
        "Α": "a", "Β": "b", "Ε": "e", "Η": "h", "Ι": "i", "Κ": "k", "Μ": "m",
        "Ν": "n", "Ο": "o", "Ρ": "p", "Τ": "t", "Υ": "y", "Χ": "x", "Ζ": "z",
        "ո": "n", "օ": "o", "ս": "u", "Ꭺ": "a", "Ꮃ": "w", "Ꮖ": "i", "Ꮪ": "s",
        "Ꮯ": "c", "Ꭼ": "e", "Ꮋ": "h", "Ꮶ": "k", "Ꮷ": "d", "Ꮲ": "p", "Ꮢ": "r",
        "ı": "i", "ɩ": "i", "ɪ": "i", "ɡ": "g", "ɢ": "g", "ʏ": "y", "ʙ": "b",
        "ᴀ": "a", "ᴄ": "c", "ᴅ": "d", "ᴇ": "e", "ᴋ": "k", "ᴍ": "m", "ᴏ": "o",
        "ᴘ": "p", "ᴛ": "t", "ᴜ": "u", "ᴠ": "v", "ᴡ": "w", "ᴢ": "z", "ѐ": "e",
        "ʜ": "h", "ʟ": "l", "ɴ": "n", "ʀ": "r", "ꜱ": "s",
        "ʁ": "r", "ᴊ": "j", "ғ": "f", "ǫ": "q", "ɢ̇": "g",
        "ϲ": "c", "ϳ": "j", "ѵ": "v", "ⅰ": "i", "ⅴ": "v", "ⅹ": "x", "ⅼ": "l",
        "Ø": "o", "ø": "o",
    ]

    static let leetToLetter: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "6": "g",
        "7": "t", "8": "b", "9": "g", "2": "z",
        "@": "a", "$": "s", "!": "i", "|": "l", "£": "e", "€": "e", "¢": "c",
        "+": "t", "(": "c", "©": "c", "®": "r", "µ": "u", "ß": "b",
    ]

    static let letterToDigit: [Character: Character] = [
        "o": "0", "O": "0", "l": "1", "I": "1", "i": "1", "z": "2",
        "e": "3", "a": "4", "s": "5", "b": "6", "t": "7", "g": "9", "q": "9",
    ]

    static let numberWordsCore: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90", "hundred": "00",
        "niner": "9", "zeero": "0",
    ]

    static let numberWordsHomophones: [String: String] = [
        "oh": "0", "o": "0", "nought": "0", "naught": "0", "nil": "0",
        "nulla": "0", "nix": "0",
        "won": "1", "tree": "3", "ate": "8", "sex": "6",
        "zeroth": "0", "first": "1", "second": "2", "third": "3", "fourth": "4",
        "fifth": "5", "sixth": "6", "seventh": "7", "eighth": "8", "ninth": "9",
    ]

    static let numberWordsFunctionWords: [String: String] = [
        "to": "2", "too": "2", "for": "4", "fore": "4",
        "do": "2", "no": "9",
    ]

    static let numberWordsIndic: [String: String] = [
        "paach": "5", "saha": "6", "daha": "10", "vees": "20", "pannas": "50",
        "ainshi": "80", "nabbad": "90", "shambhar": "100",
        "pancchyahattar": "75", "pancheahttar": "75", "panchyahattar": "75",
        "shunno": "0", "dui": "2", "choy": "6", "aat": "8", "noy": "9",
        "dosh": "10", "kuri": "20", "tirish": "30", "chollish": "40",
        "ponchash": "50", "shaat": "60", "sottor": "70", "ashi": "80",
        "nobboi": "90", "eksho": "100",
        "poojiyam": "0", "ondru": "1", "onnu": "1", "irandu": "2", "rendu": "2",
        "moondru": "3", "moonu": "3", "naangu": "4", "naalu": "4",
        "ainthu": "5", "anju": "5", "aaru": "6", "ezhu": "7", "ettu": "8",
        "onbathu": "9", "pathu": "10", "irupathu": "20", "muppathu": "30",
        "naappathu": "40", "aimbathu": "50", "aruvathu": "60",
        "ezhupathu": "70", "enbathu": "80", "thonnooru": "90", "nooru": "100",
        "sunna": "0", "okati": "1", "moodu": "3", "naalugu": "4", "aidu": "5",
        "enimidi": "8", "tommidi": "9", "padi": "10", "iravai": "20",
        "muppai": "30", "nalabhai": "40", "yabhai": "50", "aravai": "60",
        "debbhai": "70", "enabhai": "80", "tombhai": "90",
        "sonne": "0", "ondu": "1", "eradu": "2", "muru": "3", "naalku": "4",
        "elu": "7", "entu": "8", "ombattu": "9", "hattu": "10",
        "ippattu": "20", "muvattu": "30", "nalavattu": "40", "aivattu": "50",
        "aravattu": "60", "eppattu": "70", "embattu": "80", "tombattu": "90",
        "poojyam": "0", "randu": "2", "anchu": "5", "onpathu": "9",
        "patthu": "10", "nalpathu": "40", "anpathu": "50", "aruppathu": "60",
        "enpathu": "80",
        "chha": "6", "trees": "30", "sitter": "70", "ainsi": "80",
        "ikk": "1", "tinn": "3", "panj": "5", "satt": "7", "vih": "20",
        "tih": "30", "chali": "40", "panjah": "50",
        "eka": "1", "tini": "3", "chari": "4", "pancha": "5", "sata": "7",
        "atha": "8", "dasha": "10", "kodie": "20", "tirisha": "30",
        "chalisha": "40", "pachasha": "50", "sattari": "70",
        "aik": "1",
    ]

    static let numberWordsIndicAmbiguous: [String: String] = [
        "don": "2",
        "be": "2",
        "tran": "3",
        "shat": "7",
        "edu": "7",
        "nav": "9",
        "na": "9",
    ]

    static let allNumberWords: [String: String] = {
        var merged = numberWordsCore
        for table in [numberWordsRisky, numberWordsIndic,
                      numberWordsIndicAmbiguous, numberWordsHomophones,
                      numberWordsFunctionWords] {
            for (key, value) in table where merged[key] == nil { merged[key] = value }
        }
        return merged
    }()

    static let numberWordsRisky: [String: String] = [
        "nyne": "9", "ayt": "8", "fyve": "5",
        "shunya": "0", "sunya": "0", "sifar": "0",
        "ek": "1", "teen": "3",
        "tin": "3", "char": "4", "chaar": "4", "paanch": "5", "panch": "5",
        "pach": "5", "chhe": "6", "che": "6", "chey": "6", "cheh": "6",
        "saat": "7", "sat": "7", "aath": "8", "ath": "8", "nau": "9",

        "das": "10", "dus": "10",
        "gyarah": "11", "barah": "12", "terah": "13", "chaudah": "14",
        "pandrah": "15", "solah": "16", "satrah": "17", "atharah": "18",
        "unnis": "19", "unnees": "19",
        "bees": "20", "bis": "20",
        "tees": "30", "tis": "30",
        "chalis": "40", "chalees": "40",
        "pachas": "50", "pachaas": "50", "pachhas": "50",
        "saath": "60", "sath": "60",
        "sattar": "70",
        "assi": "80", "assee": "80", "asi": "80",
        "nabbe": "90", "navve": "90", "nabbey": "90",
        "sau": "100",
        "pachhattar": "75", "pachattar": "75", "pichhattar": "75",
        "panchanve": "95",
        "ikkis": "21", "baees": "22", "teis": "23", "chaubis": "24",
        "pachees": "25", "chhabbis": "26", "sattais": "27", "atthais": "28",
        "untis": "29", "iktis": "31", "battis": "32",
        "paintis": "35", "paintalis": "45",
        "pachpan": "55", "painsath": "65", "pichasi": "85",
        "uno": "1", "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5",
        "seis": "6", "siete": "7", "ocho": "8", "nueve": "9", "cero": "0",
        "zero": "0", "un": "1", "deux": "2", "trois": "3", "quatre": "4",
        "cinq": "5", "sept": "7", "huit": "8", "neuf": "9",
        "null": "0", "eins": "1", "zwei": "2", "drei": "3", "vier": "4",
        "funf": "5", "fuenf": "5", "sechs": "6", "sieben": "7", "acht": "8", "neun": "9",
        "fife": "5", "fower": "6", "wun": "1", "zeero": "0",
        "शून्य": "0", "एक": "1", "दो": "2", "तीन": "3", "चार": "4",
        "पांच": "5", "पाँच": "5", "छे": "6", "छह": "6", "सात": "7",
        "आठ": "8", "नौ": "9",
    ]

    static let hanNumerals: [Character: String] = [
        "零": "0", "〇": "0", "一": "1", "二": "2", "三": "3", "四": "4",
        "五": "5", "六": "6", "七": "7", "八": "8", "九": "9",
        "壹": "1", "貳": "2", "參": "3", "肆": "4", "伍": "5",
        "陸": "6", "柒": "7", "捌": "8", "玖": "9",
    ]

    static let brailleDigits: [Character: String] = [
        "⠁": "1", "⠃": "2", "⠉": "3", "⠙": "4", "⠑": "5",
        "⠋": "6", "⠛": "7", "⠓": "8", "⠊": "9", "⠚": "0",
        "⠔": "9", "⠦": "8", "⠶": "7", "⠴": "6", "⠢": "5",
        "⠲": "4", "⠒": "3", "⠆": "2",
    ]

    static let romanNumerals: [(String, String)] = [
        ("viii", "8"), ("vii", "7"), ("iii", "3"), ("ix", "9"), ("iv", "4"),
        ("vi", "6"), ("ii", "2"), ("xi", "11"), ("x", "10"),
        ("v", "5"), ("i", "1"),
    ]

    static func regionalIndicatorLetter(_ scalar: Unicode.Scalar) -> Character? {
        guard scalar.value >= 0x1F1E6, scalar.value <= 0x1F1FF else { return nil }
        let offset = scalar.value - 0x1F1E6
        return Character(UnicodeScalar(UInt8(97 + offset)))
    }

    static func compatibilityFallbackString(_ scalar: Unicode.Scalar) -> String? {
        switch scalar.value {
        case 0x2474...0x247C:
            return "(\(scalar.value - 0x2474 + 1))"
        case 0x247D...0x2487:
            return "(\(scalar.value - 0x247D + 10))"
        default:
            return nil
        }
    }

    static func compatibilityFallback(_ scalar: Unicode.Scalar) -> Unicode.Scalar? {
        let v = scalar.value
        func offset(_ base: UInt32, _ target: UInt32) -> Unicode.Scalar? {
            Unicode.Scalar(target + (v - base))
        }
        switch v {
        case 0xFF10...0xFF19: return offset(0xFF10, 0x30)
        case 0xFF21...0xFF3A: return offset(0xFF21, 0x41)
        case 0xFF41...0xFF5A: return offset(0xFF41, 0x61)
        case 0x1D7CE...0x1D7D7: return offset(0x1D7CE, 0x30)
        case 0x1D7D8...0x1D7E1: return offset(0x1D7D8, 0x30)
        case 0x1D7E2...0x1D7EB: return offset(0x1D7E2, 0x30)
        case 0x1D7EC...0x1D7F5: return offset(0x1D7EC, 0x30)
        case 0x1D7F6...0x1D7FF: return offset(0x1D7F6, 0x30)
        case 0x1D400...0x1D419: return offset(0x1D400, 0x41)
        case 0x1D41A...0x1D433: return offset(0x1D41A, 0x61)
        case 0x1D670...0x1D689: return offset(0x1D670, 0x41)
        case 0x1D68A...0x1D6A3: return offset(0x1D68A, 0x61)
        case 0x2460...0x2468: return Unicode.Scalar(0x31 + (v - 0x2460))
        case 0x24EA, 0x24FF: return Unicode.Scalar(0x30)
        case 0x2070: return Unicode.Scalar(0x30)
        case 0x00B9: return Unicode.Scalar(0x31)
        case 0x00B2: return Unicode.Scalar(0x32)
        case 0x00B3: return Unicode.Scalar(0x33)
        case 0x2074...0x2079: return Unicode.Scalar(0x34 + (v - 0x2074))
        case 0x2080...0x2089: return Unicode.Scalar(0x30 + (v - 0x2080))
        default: return nil
        }
    }

    static func tagCharacter(_ scalar: Unicode.Scalar) -> Character? {
        guard scalar.value >= 0xE0020, scalar.value <= 0xE007E else { return nil }
        return Character(UnicodeScalar(scalar.value - 0xE0000)!)
    }

    static let repeatModifiers: [String: Int] = [
        "double": 2, "dubble": 2, "twice": 2, "triple": 3, "treble": 3,
        "tripple": 3, "quad": 4, "quadruple": 4,
    ]

    static let natoAlphabet: [String: Character] = [
        "alpha": "a", "alfa": "a", "bravo": "b", "charlie": "c", "delta": "d",
        "echo": "e", "foxtrot": "f", "golf": "g", "hotel": "h", "india": "i",
        "juliet": "j", "juliett": "j", "kilo": "k", "lima": "l", "mike": "m",
        "november": "n", "oscar": "o", "papa": "p", "quebec": "q", "romeo": "r",
        "sierra": "s", "tango": "t", "uniform": "u", "victor": "v",
        "whiskey": "w", "whisky": "w", "xray": "x", "yankee": "y", "zulu": "z",
    ]

    static let separatorWords: [String: String] = [
        "at": "@", "aht": "@", "att": "@", "atsign": "@", "monkey": "@",
        "dot": ".", "dawt": ".", "point": ".", "punto": ".", "period": ".",
        "underscore": "_", "under": "_", "dash": "-", "hyphen": "-",
        "slash": "/", "colon": ":", "plus": "+",
        "bindu": ".", "bindi": ".", "chukka": ".", "tikka": ".",
    ]

    static let solicitationCues: [String] = [
        "share yours", "send yours", "give me yours", "yours first",
        "why do not you share", "why don't you share", "you go first",
        "send me your", "share your", "give me your", "confirm your",
        "confirm the mobile", "confirm the number", "confirm your number",
        "what is your number", "whats your number", "your contact details",
        "read out your", "dictate your", "spell out your", "one word at a time",
        "i will write them down", "i will save it", "so i can save",
        "number he can use", "a number for him", "number for my",
        "reply with both", "reply with your", "drop your",
    ]

    static let steeringCues: [String] = [
        "deals with me directly", "deal with me direct", "deals direct",
        "just deal with me", "between ourselves", "between us only",
        "settle this between", "sort it between", "keep it between",
        "the app with the green", "green icon", "green tick", "green tick app",
        "the app everyone uses", "app everyone in india", "the usual app",
        "you know which app", "you know the one", "same name there",
        "same handle there", "same username there", "find me there",
        "i am on there", "im on there", "move somewhere", "somewhere greener",
        "continue this conversation over", "chat over there", "talk over there",
        "reaching outward", "beyond these walls", "outside these walls",
        "platform keeps eating", "keeps eating my message", "messages keep getting",
        "cannot say it here", "can not say it here", "not allowed to say here",
        "they take a huge cut", "takes a huge cut", "huge commission",
        "next time i will give", "at checkout i will give", "give you my details at",
        "my caretaker will call", "someone will call you", "manager will call you",
    ]

    static let pretextCues: [String] = [
        "this is wayzyy support", "wayzyy support", "platform support here",
        "for verification please", "verification purposes", "to verify your account",
        "our accounts team needs", "accounts team requires", "for the gst invoice",
        "for the invoice we need", "billing team needs",
        "there is a water leak", "emergency at the", "urgent issue at the",
        "platform chat is too slow", "chat is too slow", "no time for the app",
        "how else can i reach you", "how can i reach you quickly",
    ]

    static let promptInjectionCues: [String] = [
        "ignore previous instruction", "ignore all previous", "ignore the above",
        "ignore your instruction", "disregard previous", "disregard the above",
        "disregard your instruction", "forget your instruction",
        "forget previous instruction", "override your instruction",
        "you are now", "act as if", "pretend you are", "new instructions",
        "system prompt", "system message", "developer message",
        "respond with benign", "reply benign", "mark this as benign",
        "classify this as benign", "return benign", "decision benign",
        "this message is safe", "this message is approved", "approved by moderation",
        "end of message", "end of transcript", "begin new", "assistant:",
        "\"decision\":", "decision\":\"benign", "json only",
        "do not flag", "dont flag", "do not block", "allow this message",
        "moderation is disabled", "bypass moderation", "skip moderation",
    ]

    static let morseToChar: [String: Character] = [
        ".-": "a", "-...": "b", "-.-.": "c", "-..": "d", ".": "e", "..-.": "f",
        "--.": "g", "....": "h", "..": "i", ".---": "j", "-.-": "k", ".-..": "l",
        "--": "m", "-.": "n", "---": "o", ".--.": "p", "--.-": "q", ".-.": "r",
        "...": "s", "-": "t", "..-": "u", "...-": "v", ".--": "w", "-..-": "x",
        "-.--": "y", "--..": "z",
        "-----": "0", ".----": "1", "..---": "2", "...--": "3", "....-": "4",
        ".....": "5", "-....": "6", "--...": "7", "---..": "8", "----.": "9",
    ]

    static let platformsStrong: Set<String> = [
        "whatsapp", "whatsap", "whatsaap", "watsapp", "watsap", "wtsp", "wsp",
        "instagram", "insta", "instgram", "instagam",
        "telegram", "telgram", "tele",
        "snapchat", "snap", "signal", "viber", "wechat", "weixin", "botim",
        "imo", "discord", "skype", "messenger", "hangouts", "duo", "zalo",
        "line", "kakao", "kik", "threema", "wickr", "session",
        "facebook", "twitter", "linkedin", "tiktok", "reddit", "pinterest",
        "gmail", "yahoo", "hotmail", "outlook", "protonmail", "icloud", "rediff",
    ]

    static let platformsWeak: Set<String> = [
        "wa", "ig", "tg", "fb", "dm", "pm", "sc", "wapp", "wats", "gram",
    ]

    static let platformsStripped: Set<String> = [
        "whtspp", "whtsp", "wtspp", "wtsap", "instgrm", "instgm", "nsta",
        "tlgrm", "tlgm", "snpcht", "snpct", "sgnl", "vbr", "wcht", "dscrd",
        "fcbk", "mssngr", "gml", "ymail",
    ]

    static let platformsCollapsed: Set<String> = {
        Set(platformsStrong.map { collapseRuns($0) })
    }()

    static func collapseRuns(_ s: String) -> String {
        var out = ""
        var last: Character? = nil
        for ch in s where ch != last {
            out.append(ch)
            last = ch
        }
        return out
    }

    static let contactIntent: [String] = [
        "call me", "call my", "ring me", "text me", "txt me", "sms me",
        "message me", "msg me", "dm me", "ping me", "reach me", "reach out",
        "hit me up", "hmu", "contact me", "get in touch", "buzz me",
        "my number", "my no", "my num", "my digits", "my contact", "my cell",
        "my mobile", "my phone", "my email", "my mail", "my id", "my handle",
        "mera number", "mera no", "mera contact", "mera mobile", "meri id",
        "mera whatsapp", "mera insta", "hamara number", "humara number",
        "here is my", "heres my", "this is my", "save my", "note my",
        "add me", "follow me", "find me on", "search me", "look me up",
        "give me your number", "send your number", "share your number",
        "whats your number", "what is your number", "your digits",
        "number hai", "number bhejo", "number do", "sampark",
    ]

    static let offPlatformIntent: [String] = [
        "off platform", "off the platform", "outside the app", "outside app",
        "outside the platform", "outside wayzyy", "outside airbnb", "off app",
        "book direct", "booking direct", "direct booking", "direct book",
        "avoid the fee", "avoid fees", "avoid commission", "save the fee",
        "save fees", "save commission", "no commission", "without commission",
        "cheaper direct", "cheaper if", "better price direct", "discount if you",
        "cancel and rebook", "cancel the booking", "cancel this and",
        "cancel this booking", "cancel your booking", "rebook with me",
        "book with me directly", "directly with me", "deal with me directly",
        "next time just book", "skip the platform", "skip the app",
        "pay cash", "cash payment", "cash only", "pay outside", "pay directly",
        "bank transfer", "wire transfer", "western union", "moneygram",
    ]

    static let protocolHints: [String] = [
        "count the letter", "count the character", "count the word", "count them",
        "letters in each", "characters in each", "words in each",
        "first letter of each", "first character of each", "first word of each",
        "last letter of each", "every second", "every third", "every other",
        "word length", "length of each", "number of letters",
        "read the capital", "read the caps", "capital letters spell",
        "take the first", "take every", "read it backwards", "read backwards",
        "in reverse", "reverse it", "reverse my", "backwards",
        "put those together", "put them together", "join them", "join with",
        "add those up", "add them up", "in order", "decode", "decipher",
        "figure it out", "you'll work it out", "you will work it out",
        "add one to each", "subtract one from each", "shift each",
        "spell it out", "spells my", "spells it",
    ]

    static let paymentKeywords: Set<String> = [
        "upi", "gpay", "googlepay", "phonepe", "paytm", "bhim", "razorpay",
        "venmo", "cashapp", "zelle", "revolut", "wise", "transferwise",
        "paypal", "stripe", "payoneer", "skrill", "neteller",
        "ifsc", "neft", "imps", "rtgs", "swift", "iban", "sortcode",
        "bitcoin", "btc", "ethereum", "eth", "usdt", "tether", "crypto",
        "binance", "coinbase", "metamask", "tron", "trc20",
    ]

    static let upiSuffixes: Set<String> = [
        "ybl", "ibl", "axl", "apl", "abfspay", "airtel", "aubank", "axisbank",
        "bandhan", "barodampay", "boi", "cbin", "cnrb", "csbpay", "dbs",
        "dlb", "federal", "fbl", "freecharge", "hdfcbank", "hsbc", "icici",
        "idbi", "idfcbank", "indus", "indianbank", "iob", "jio", "jkb",
        "jupiteraxis", "kbl", "kotak", "kvb", "mahb", "myicici", "okaxis",
        "okbizaxis", "okhdfcbank", "okicici", "oksbi", "paytm", "pingpay",
        "pnb", "postbank", "pockets", "psb", "rbl", "sbi", "sib", "slice",
        "tapicici", "timecosmos", "ubi", "uco", "unionbank", "utbi", "waaxis",
        "waicici", "wasbi", "yesbank", "yesbankltd", "upi", "superyes",
    ]

    static let shorteners: Set<String> = [
        "bit.ly", "bitly.com", "tinyurl.com", "goo.gl", "t.co", "ow.ly",
        "is.gd", "buff.ly", "rebrand.ly", "cutt.ly", "shorturl.at", "rb.gy",
        "linktr.ee", "linktree.com", "beacons.ai", "carrd.co", "bio.link",
        "lnk.bio", "msha.ke", "wa.me", "api.whatsapp.com", "chat.whatsapp.com",
        "t.me", "telegram.me", "ig.me", "m.me", "snapchat.com", "join.skype.com",
        "calendly.com", "forms.gle", "docs.google.com", "drive.google.com",
    ]

    static let commonTLDs: Set<String> = [
        "com", "net", "org", "io", "co", "in", "me", "app", "dev", "ai",
        "info", "biz", "xyz", "site", "online", "shop", "store", "link",
        "live", "life", "world", "space", "website", "cloud", "page", "us",
        "uk", "de", "fr", "es", "it", "nl", "ru", "cn", "jp", "au", "ca", "gg",
    ]

    static var threatPhrases: [String] = [
        "i will kill you", "ill kill you", "i'll kill you", "kill you",
        "i will find you", "ill find you", "i'll find you", "i know where you live",
        "watch your back", "you are dead", "youre dead", "you're dead",
        "i will hurt you", "beat you up", "smash your face", "break your legs",
        "burn your house", "you will regret", "you'll regret this",
        "i will destroy you", "come to your house", "wait and see what happens",

        "maar dunga", "maar dalunga", "maar daalunga", "jaan le lunga",
        "zinda nahi chodunga", "nahi chodunga", "khatam kar dunga",
        "tujhe dekh lunga", "tumhe dekh lunga", "tujhe dekhta hoon",
        "tujhe dekh leta hoon", "tere ko dekh lunga",
        "tere ghar aa jaunga", "tere ghar aaunga", "tere ghar aa raha",
        "ghar pe aa jaunga", "ghar tak aaunga",
        "barbaad kar dunga", "barbaad kar denge", "tabah kar dunga",
        "tujhe pata nahi main kaun hoon", "meri pahunch bahut oopar tak hai",
        "tere parivar ko dekh lunga", "teri family ko dekh lunga",
        "haddi tod dunga", "haath pair tod dunga",
    ]

    static var harassmentPhrases: [String] = [
        "shut up", "you idiot", "you are stupid", "youre stupid", "you're stupid",
        "you are an idiot", "get lost", "you are useless", "youre useless",
        "you are trash", "pathetic loser", "you are a liar", "moron", "imbecile",
        "worthless", "disgusting person", "nobody likes you",
    ]

    static var slurTerms: Set<String> = []

    static let profanityStrong: Set<String> = [
        "fuck", "fucking", "fucked", "fucker", "fuckers", "motherfucker", "motherfucking",
        "fuk", "fuking", "fukking", "fck", "fcking", "phuck", "fuckoff",
        "cunt", "bitch", "bitches", "btch", "bich", "biatch",
        "asshole", "assholes", "ashole", "arsehole", "dumbass", "jackass",
        "ahole", "azzhole", "fk", "fuq", "phuk", "fkin", "fkng",
        "bastard", "bastards", "wanker", "prick", "twat", "slut", "whore",
        "douchebag", "dickhead", "scumbag",
    ]

    static let profanityMild: Set<String> = [
        "shit", "shite", "shyt", "sht", "shitty", "crap", "crappy", "damn", "damned",
        "bloody", "piss", "pissed", "bugger", "arse", "hell", "sucks", "sucked",
    ]

    static let profanityIndic: Set<String> = [
        "chutiya", "chutiye", "chutia", "chutiyaa", "chodu", "chod",
        "madarchod", "madarchood", "madrchod", "mc",
        "bhenchod", "behenchod", "bhenchd", "bc",
        "bhosdike", "bhosadike", "bhosdi", "bhosda",
        "gandu", "gaandu", "gand", "gaand", "gandmara",
        "harami", "haramkhor", "haramzada",
        "randi", "rand", "kutti", "kutta", "kutte",
        "kamina", "kamine", "kaminey", "lodu", "lund", "jhatu", "tatti",
        "saala", "saale", "sala", "bewakoof", "gadha",
    ]

    static let personTargets: Set<String> = [
        "you", "your", "youre", "yours", "yourself", "u", "ur", "urself",
        "tu", "tum", "tume", "tumhe", "tumko", "tujhe", "tujhko", "tujh",
        "tera", "teri", "tere", "tumhara", "tumhari", "tumhare", "tumhein",
        "aap", "aapka", "aapki", "apna", "host", "owner", "caretaker", "guest",
    ]

    static let devanagariPersonStems: [String] = [
        "तुम",
        "तुझ",
        "तेर",
        "तू",
        "आप",
    ]

    static let cyrillicPersonTokens: Set<String> = [
        "ты", "тебя", "тебе", "тобой", "тобою", "тя",
        "твой", "твоя", "твое", "твоё", "твои", "твоих", "твоим", "твоего", "твоей",
        "вы", "вас", "вам", "вами", "ваш", "ваша", "ваше", "ваши", "вашего", "вашей",
    ]

    static let nativeScriptConditionalCues: [String] = [
        "नहीं तो", "नही तो", "वरना", "वर्ना", "अन्यथा",
        "иначе", "или я", "если не", "в противном случае",
    ]

    static let propertyTargets: Set<String> = [
        "place", "villa", "room", "rooms", "house", "home", "apartment", "flat",
        "stay", "hotel", "property", "listing", "bathroom", "washroom", "toilet",
        "kitchen", "bed", "beds", "bedding", "sheets", "towels", "wifi", "internet",
        "ac", "food", "breakfast", "service", "pool", "shower", "water", "smell",
        "situation", "experience", "trip", "holiday", "booking", "everything", "this",
    ]

    static var coercionPhrases: [String] = [
        "or i will report", "or ill report", "or i'll report", "or i report you",
        "or i will leave a bad review", "or ill leave a bad review",
        "or i will give you one star", "or ill give you 1 star",
        "unless you refund", "unless you give me", "unless you agree",
        "if you dont", "if you don't", "if you refuse", "you have no choice",
        "i will ruin your rating", "ill ruin your", "destroy your rating",
        "i will report you to", "one star review unless", "bad review unless",
        "give me a discount or", "refund me or", "cancel or i will",

        "warna review kharab", "warna bura review", "warna main review",
        "review kharab kar dunga", "review kharab kar denge",
        "rating kharab kar dunga", "paisa wapas de warna", "paisa wapas kar warna",
        "refund do warna", "nahi diya to review", "warna police",
        "warna main sabko bata dunga", "warna tera business",
    ]

    static let scamPhrases: [String] = [
        "verify your account", "confirm your card", "send the otp", "share the otp",
        "click this link to confirm", "click the link below to pay",
        "advance payment", "pay in advance", "token amount", "security deposit outside",
        "double your money", "guaranteed return", "gift card", "google play card",
        "itunes card", "steam card", "send the code", "screenshot of your card",
        "your booking will be cancelled unless you pay", "urgent payment required",
        "wire the money", "send money first", "pay before i confirm",
    ]

    static var sexualPhrases: [String] = [
        "send me nudes", "send me nude", "send me naked", "send me your nudes",
        "send me photos of you", "send me a photo of you", "send me pics of you",
        "send me pictures of yourself", "naked photos", "nude photos",
        "send nudes", "send nude", "send pics of you", "sleep with me",
        "spend the night with me", "escort service", "happy ending massage",
        "are you single and alone", "you and me alone tonight", "sexual favour",
        "sexual favor", "in exchange for sex",
    ]

    static var selfHarmPhrases: [String] = [
        "kill myself", "end my life", "want to die", "suicide", "suicidal",
        "no reason to live", "end it all", "hurt myself", "harm myself",
    ]

    static let identifierStoplist: Set<String> = [
        "room", "flat", "apt", "apartment", "unit", "block", "floor", "door",
        "house", "plot", "survey", "shop", "gate", "tower", "wing", "level",
        "wifi", "wi", "ssid", "network", "password", "code",
        "booking", "reservation", "confirmation", "conf", "invoice", "receipt",
        "order", "ref", "reference", "pnr", "ticket", "seat", "terminal",
        "flight", "train", "bus", "cab", "taxi",
        "gst", "gstin", "pan", "hsn", "sac", "pin", "pincode", "zip", "postal",
        "nh", "sh", "highway", "route", "bhk", "sqft", "sqm", "sq",
        "wz", "ai", "iso", "usd", "inr", "aed", "eur", "gbp", "rs",
        "km", "kg", "ml", "ltr", "cm", "mm", "ft", "hr", "hrs", "min", "mins",
        "covid", "type", "no", "num", "id",
    ]

    static func looksLikeHandle(_ token: String) -> Bool {
        guard token.count >= 4, token.count <= 30 else { return false }
        let hasDigit = token.contains { $0.isNumber }
        let hasSep = token.contains("_") || token.contains(".")
        guard hasDigit || hasSep else { return false }
        return token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }
    }

    static func editDistance(_ a: String, _ b: String, max cap: Int = 2) -> Int {
        let s = Array(a), t = Array(b)
        if abs(s.count - t.count) > cap { return cap + 1 }
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }

        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)

        for i in 1...s.count {
            curr[0] = i
            var rowBest = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = Swift.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
                rowBest = Swift.min(rowBest, curr[j])
            }
            if rowBest > cap { return cap + 1 }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }

    static let platformFuzzyStoplist: Set<String> = [
        "email", "emails", "mail", "mails", "mailing", "email's",
        "fiber", "fibre", "viper", "vipers",
        "small", "smell", "shall", "snail", "trail", "grail",
    ]

    static let framedPlatforms: Set<String> = [
        "youtube", "yt", "x", "threads", "mastodon", "koo", "sharechat",
        "twitch", "tumblr", "clubhouse", "bereal", "quora", "moj", "josh",
    ]

    static let compoundAdjectiveTails: Set<String> = [
        "worthy", "ready", "famous", "verified", "perfect", "friendly",
        "approved", "official", "grade", "level", "esque", "proof", "able",
        "first", "only", "native", "driven", "based", "style", "themed",
    ]

    static let genericWordPlatforms: Set<String> = [
        "line", "meet", "signal", "zoom", "band", "chat", "talk", "duo",
        "join", "session", "circle", "path", "hike", "tango", "marco",
    ]

    static func fuzzyPlatform(_ token: String) -> String? {
        guard token.count >= 4, token.count <= 16, token.allSatisfy({ $0.isLetter }) else { return nil }
        if platformsStrong.contains(token) { return token }
        guard !platformFuzzyStoplist.contains(token) else { return nil }
        for name in platformsStrong where name.count >= 5 {
            guard abs(name.count - token.count) <= 1 else { continue }
            if editDistance(token, name, max: 1) <= 1 { return name }
        }
        return nil
    }

    static let fuzzyStoplist: Set<String> = [
        "bone", "cone", "done", "gone", "hone", "lone", "none", "tone", "zone",
        "once", "ones", "oven", "open",
        "to", "too", "tow", "toe", "ton", "top", "tho", "tot",
        "thee", "there", "tree", "free", "threw",
        "for", "fore", "hour", "tour", "pour", "sour", "your", "foul", "four's",
        "fine", "file", "fire", "hive", "live", "dive", "jive", "wife", "fife",
        "fix", "mix", "nix", "sit", "sir", "sic", "sip", "sis", "sax", "six's",
        "even", "sever", "seen",
        "night", "light", "might", "right", "sight", "tight", "fight", "weight",
        "dine", "line", "mine", "nice", "pine", "sine", "vine", "wine", "niner",
        "name", "none",
        "hero", "aero", "xero",
        "come", "some", "same", "home", "time", "more", "core", "sure", "here",
        "were", "here's", "one's",
    ]

    static func fuzzyNumberWord(_ token: String) -> String? {
        if let exact = numberWordsCore[token] { return exact }
        guard token.count >= 3, token.count <= 9, token.allSatisfy({ $0.isLetter }) else { return nil }
        guard !fuzzyStoplist.contains(token) else { return nil }
        guard numberWordsHomophones[token] == nil,
              numberWordsFunctionWords[token] == nil,
              numberWordsRisky[token] == nil,
              numberWordsIndic[token] == nil,
              numberWordsIndicAmbiguous[token] == nil
        else { return nil }
        for (word, digit) in numberWordsCore where abs(word.count - token.count) <= 1 {
            if editDistance(token, word, max: 1) <= 1 { return digit }
            if word.count == token.count, isTransposition(token, word) { return digit }
        }
        return nil
    }

    static func isTransposition(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        guard x.count == y.count, x.count >= 3 else { return false }
        var diffs: [Int] = []
        for i in 0..<x.count where x[i] != y[i] {
            diffs.append(i)
            if diffs.count > 2 { return false }
        }
        guard diffs.count == 2, diffs[1] == diffs[0] + 1 else { return false }
        return x[diffs[0]] == y[diffs[1]] && x[diffs[1]] == y[diffs[0]]
    }
}

// MARK: - Bootstrap sealing
//
// Five of the safety phrase lists and the slur set are `static var` because they are extended
// during bootstrap: `NativeScriptSafety.register` appends Devanagari and Cyrillic phrases, and
// `SlurLexicon.bootstrap` installs the slur set from configuration. After that they are read on
// every single evaluation and never written again.
//
// That makes them shared mutable state on the hottest path in the system, and there are two
// ways to make it safe. Locking every read is the obvious one and the wrong one: these lists are
// consulted many times per message, so the cost lands on every message forever in order to
// protect against a write that only ever happens at startup.
//
// The alternative is to make "immutable after startup" a property the type enforces rather than
// a convention the next person has to notice. Bootstrap extends the lists, the engine seals
// them before serving anything, and a write after sealing traps immediately with an explanation
// instead of corrupting a read somewhere else and being debugged as a mystery six months later.
//
// The cost of this choice is that reloading the slur list means restarting the process. For a
// containerised deployment that is a rolling restart, which is a better trade than paying a lock
// on every read of every message to support an operation performed a few times a year.

extension Lex {

    private static let sealLock = NSLock()
    private static var _sealed = false

    /// Whether the lexicons are final. Exposed so a deployment can assert it before serving.
    static var isSealed: Bool {
        sealLock.lock()
        defer { sealLock.unlock() }
        return _sealed
    }

    /// Called once, after bootstrap, before the first evaluation.
    static func seal() {
        sealLock.lock()
        _sealed = true
        sealLock.unlock()
    }

    /// Guard placed at every mutation site.
    static func requireMutable(_ what: String) {
        precondition(!isSealed, """
            \(what) was modified after bootstrap sealed the lexicons. The safety phrase lists are \
            read without synchronisation on every evaluation, so they must be final before the \
            first one; a later write is a data race, not a configuration change. To pick up a new \
            lexicon, restart the process.
            """)
    }
}
