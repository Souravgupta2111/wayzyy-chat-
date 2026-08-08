// The primary adversarial corpus with expected outcomes per case.

import Foundation

enum RedTeamFamily: String, CaseIterable, Identifiable {
    case plain            = "A · Plain"
    case unicodeGlyph     = "B · Unicode & script"
    case leet             = "C · Leet & substitution"
    case numberWords      = "D · Spelled numbers"
    case chunking         = "E · Separators & chunking"
    case camouflage        = "F · Camouflage in prose"
    case encoding         = "G · Encoding & ciphers"
    case referential      = "H · Referential & semantic"
    case steering         = "I · Channel steering"
    case payment          = "J · Payment rails"
    case links            = "K · Links & deep links"
    case layout           = "L · Layout & multi-line"
    case sequence         = "M · Multi-message assembly"
    case positional       = "N · Positional & steganographic"

    var id: String { rawValue }
}

struct RedTeamCase: Identifiable {
    let id: Int
    let family: RedTeamFamily
    let messages: [String]
    let payload: String
    let technique: String

    init(_ id: Int, _ family: RedTeamFamily, _ technique: String, _ payload: String, _ messages: [String]) {
        self.id = id
        self.family = family
        self.technique = technique
        self.payload = payload
        self.messages = messages
    }

    var isSequence: Bool { messages.count > 1 }
}

enum RedTeamCorpus {

    static var all: [RedTeamCase] {
        plain + unicode + leet + numberWords + chunking + camouflage
            + encoding + referential + steering + payment + links + layout
            + sequences + positional
    }

    static let plain: [RedTeamCase] = [
        .init(1, .plain, "bare mobile", "phone", ["call me 9876543210"]),
        .init(2, .plain, "E.164", "phone", ["+91 98765 43210"]),
        .init(3, .plain, "trunk prefix", "phone", ["09876543210"]),
        .init(4, .plain, "IDD prefix", "phone", ["00919876543210"]),
        .init(5, .plain, "literal email", "email", ["mail me akshay.verma@gmail.com"]),
        .init(6, .plain, "bare email", "email", ["akshay.verma@gmail.com"]),
        .init(7, .plain, "explicit handle", "handle", ["my insta @akshay_goa_villa"]),
        .init(8, .plain, "bare handle", "handle", ["akshay_goa_villa"]),
        .init(9, .plain, "platform + number", "phone", ["whatsapp 9876543210"]),
        .init(10, .plain, "number with label", "phone", ["Mob: 9876543210"]),
    ]

    static let unicode: [RedTeamCase] = [
        .init(11, .unicodeGlyph, "fullwidth digits", "phone", ["call ９８７６５４３２１０"]),
        .init(12, .unicodeGlyph, "math bold digits", "phone", ["ring 𝟗𝟖𝟕𝟔𝟓𝟒𝟑𝟐𝟏𝟎"]),
        .init(13, .unicodeGlyph, "math monospace digits", "phone", ["num 𝟿𝟾𝟽𝟼𝟻𝟺𝟹𝟸𝟷𝟶"]),
        .init(14, .unicodeGlyph, "superscript digits", "phone", ["dial ⁹⁸⁷⁶⁵⁴³²¹⁰"]),
        .init(15, .unicodeGlyph, "subscript digits", "phone", ["dial ₉₈₇₆₅₄₃₂₁₀"]),
        .init(16, .unicodeGlyph, "circled digits", "phone", ["⑨⑧⑦⑥⑤④③②①⓪"]),
        .init(17, .unicodeGlyph, "keycap emoji", "phone", ["9️⃣8️⃣7️⃣6️⃣5️⃣4️⃣3️⃣2️⃣1️⃣0️⃣"]),
        .init(18, .unicodeGlyph, "zero-width separated", "phone", ["9\u{200B}8\u{200B}7\u{200B}6\u{200B}5\u{200B}4\u{200B}3\u{200B}2\u{200B}1\u{200B}0"]),
        .init(19, .unicodeGlyph, "soft hyphens", "phone", ["98\u{00AD}76\u{00AD}54\u{00AD}32\u{00AD}10"]),
        .init(20, .unicodeGlyph, "word joiners", "phone", ["9\u{2060}8\u{2060}7\u{2060}6\u{2060}5\u{2060}4\u{2060}3\u{2060}2\u{2060}1\u{2060}0"]),
        .init(21, .unicodeGlyph, "RTL override", "phone", ["\u{202E}0123456789\u{202C}"]),
        .init(22, .unicodeGlyph, "combining marks / zalgo", "phone", ["9\u{0301}8\u{0301}7\u{0301}6\u{0301}5\u{0301}4\u{0301}3\u{0301}2\u{0301}1\u{0301}0\u{0301}"]),
        .init(23, .unicodeGlyph, "Cyrillic homoglyph handle", "handle", ["my іnstа is аkshаy_gоа_villа"]),
        .init(24, .unicodeGlyph, "Greek homoglyph platform", "steering", ["ping me on WhΑtsΑpp"]),
        .init(25, .unicodeGlyph, "Cherokee homoglyphs", "handle", ["ᎪkᏚhay on insta"]),
        .init(26, .unicodeGlyph, "fullwidth platform name", "steering", ["ｗｈａｔｓａｐｐ ｍｅ"]),
        .init(27, .unicodeGlyph, "small caps platform", "steering", ["ᴡʜᴀᴛsᴀᴘᴘ ᴍᴇ ᴘʟᴇᴀsᴇ"]),
        .init(28, .unicodeGlyph, "Arabic-Indic digits", "phone", ["اتصل ٩٨٧٦٥٤٣٢١٠"]),
        .init(29, .unicodeGlyph, "Devanagari digits", "phone", ["मेरा नंबर ९८७६५४३२१०"]),
        .init(30, .unicodeGlyph, "Bengali digits", "phone", ["আমার নম্বর ৯৮৭৬৫৪৩২১০"]),
        .init(31, .unicodeGlyph, "Thai digits", "phone", ["เบอร์ ๙๘๗๖๕๔๓๒๑๐"]),
        .init(32, .unicodeGlyph, "Han numerals", "phone", ["我的号码 九八七六五四三二一零"]),
        .init(33, .unicodeGlyph, "Roman numerals", "phone", ["IX VIII VII VI V IV III II I nil"]),
        .init(34, .unicodeGlyph, "Braille digits", "phone", ["⠔⠦⠶⠴⠢⠲⠒⠆⠁⠚"]),
        .init(35, .unicodeGlyph, "regional indicators", "steering", ["🇼🇭🇦🇹🇸🇦🇵🇵 me"]),
        .init(36, .unicodeGlyph, "enclosed alphanumerics", "steering", ["Ⓦⓗⓐⓣⓢⓐⓟⓟ"]),
        .init(37, .unicodeGlyph, "unicode tag block", "phone", ["number\u{E0039}\u{E0038}\u{E0037}\u{E0036}\u{E0035}\u{E0034}\u{E0033}\u{E0032}\u{E0031}\u{E0030}"]),
        .init(38, .unicodeGlyph, "mixed script handle", "handle", ["аkshay_gоa_viIla"]),
    ]

    static let leet: [RedTeamCase] = [
        .init(39, .leet, "leet platform", "steering", ["wh4t54pp me now"]),
        .init(40, .leet, "leet platform 2", "steering", ["1n5t4gr4m: akshay"]),
        .init(41, .leet, "at-sign for a", "handle", ["my h@ndle is @kshay_go@"]),
        .init(42, .leet, "dollar for s", "steering", ["what$app me"]),
        .init(43, .leet, "zero for o in email", "email", ["akshay.verma@gmai1.c0m"]),
        .init(44, .leet, "one for l", "steering", ["te1egram me"]),
        .init(45, .leet, "pipe for l", "steering", ["te|egram"]),
        .init(46, .leet, "exclamation for i", "steering", ["!nsta akshay"]),
        .init(47, .leet, "mixed leet digits in phone", "phone", ["nine8seven6five4three2one0"]),
        .init(48, .leet, "vowel stripping", "steering", ["whtspp me pls"]),
        .init(49, .leet, "doubled letters", "steering", ["whhaattssaapppp mee"]),
        .init(50, .leet, "spaced letters", "steering", ["w h a t s a p p"]),
    ]

    static let numberWords: [RedTeamCase] = [
        .init(51, .numberWords, "all English words", "phone", ["nine eight seven six five four three two one zero"]),
        .init(52, .numberWords, "Hinglish", "phone", ["nau aath saat chhe paanch chaar teen do ek shunya"]),
        .init(53, .numberWords, "Hindi script", "phone", ["नौ आठ सात छे पांच चार तीन दो एक शून्य"]),
        .init(54, .numberWords, "Spanish", "phone", ["nueve ocho siete seis cinco cuatro tres dos uno cero"]),
        .init(55, .numberWords, "French", "phone", ["neuf huit sept six cinq quatre trois deux un zero"]),
        .init(56, .numberWords, "German", "phone", ["neun acht sieben sechs funf vier drei zwei eins null"]),
        .init(57, .numberWords, "NATO aviation", "phone", ["niner ate seven six fife fower tree two wun zero"]),
        .init(58, .numberWords, "tens compounds", "phone", ["ninety eight seventy six fifty four thirty two ten"]),
        .init(59, .numberWords, "double / triple", "phone", ["nine eight double seven six five four three two one"]),
        .init(60, .numberWords, "concatenated words", "phone", ["nineeightsevensixfivefourthreetwoonezero"]),
        .init(61, .numberWords, "misspelled words", "phone", ["nyne ate sevn six fyve for three too won zeero"]),
        .init(62, .numberWords, "words + digits mixed", "phone", ["9 eight 7 six 5 four 3 two 1 zero"]),
        .init(63, .numberWords, "words with filler", "phone", ["nine then eight then seven then six five four three two one zero"]),
        .init(64, .numberWords, "ordinal words", "phone", ["ninth eighth seventh sixth fifth fourth third second first zeroth"]),
        .init(65, .numberWords, "arithmetic per digit", "phone", ["ten minus one, ten minus two, ten minus three, then six five four three two one zero"]),
        .init(66, .numberWords, "spelled with hyphens", "phone", ["nine-eight-seven-six-five-four-three-two-one-zero"]),
    ]

    static let chunking: [RedTeamCase] = [
        .init(67, .chunking, "spaces", "phone", ["98 76 54 32 10"]),
        .init(68, .chunking, "dashes", "phone", ["9-8-7-6-5-4-3-2-1-0"]),
        .init(69, .chunking, "dots", "phone", ["98.76.54.32.10"]),
        .init(70, .chunking, "slashes", "phone", ["98/76/54/32/10"]),
        .init(71, .chunking, "pipes", "phone", ["9|8|7|6|5|4|3|2|1|0"]),
        .init(72, .chunking, "commas", "phone", ["9,8,7,6,5,4,3,2,1,0"]),
        .init(73, .chunking, "underscores", "phone", ["9_8_7_6_5_4_3_2_1_0"]),
        .init(74, .chunking, "parens per digit", "phone", ["(9)(8)(7)(6)(5)(4)(3)(2)(1)(0)"]),
        .init(75, .chunking, "emoji between digits", "phone", ["9🔸8🔸7🔸6🔸5🔸4🔸3🔸2🔸1🔸0"]),
        .init(76, .chunking, "asterisks", "phone", ["*9**8**7**6**5**4**3**2**1**0*"]),
        .init(77, .chunking, "and between digits", "phone", ["9 and 8 and 7 and 6 and 5 and 4 and 3 and 2 and 1 and 0"]),
        .init(78, .chunking, "spelled separators email", "email", ["akshay dot verma at gmail dot com"]),
        .init(79, .chunking, "bracket separators email", "email", ["akshay[dot]verma[at]gmail[dot]com"]),
        .init(80, .chunking, "paren separators email", "email", ["akshay(dot)verma(at)gmail(dot)com"]),
        .init(81, .chunking, "curly separators email", "email", ["akshay{at}gmail{dot}com"]),
        .init(82, .chunking, "AT in caps", "email", ["akshay AT gmail DOT com"]),
        .init(83, .chunking, "dotted platform", "steering", ["w.h.a.t.s.a.p.p me"]),
        .init(84, .chunking, "dashed platform", "steering", ["i-n-s-t-a-g-r-a-m"]),
        .init(85, .chunking, "country code split", "phone", ["+91 then 98765 then 43210"]),
    ]

    static let camouflage: [RedTeamCase] = [
        .init(86, .camouflage, "digits inside words", "phone", ["hi i a9m a8ksh7ay call me on 6five4three2one0"]),
        .init(87, .camouflage, "name glued to number", "phone", ["akshay9876543210"]),
        .init(215, .camouflage, "number word inside digit run", "phone", ["78zerofive432670"]),
        .init(216, .camouflage, "number word inside digit run, split msgs", "phone", [
            "Calll Me", "78zerofive432670",
        ]),
        .init(217, .camouflage, "two number words inside digits", "phone", ["9eight7six543210"]),
        .init(218, .camouflage, "number word at both ends", "phone", ["nine87654321zero"]),
        .init(219, .camouflage, "hinglish word inside digits", "phone", ["98saat6543210"]),
        .init(220, .camouflage, "typo platform + plain handle", "handle", ["my inzta souravdotcan"]),
        .init(221, .camouflage, "typo platform alone", "steering", ["whatsspp me"]),
        .init(222, .camouflage, "platform + plain handle", "handle", ["insta souravcan"]),
        .init(223, .camouflage, "glued dot separator handle", "handle", ["my insta is souravdotcan"]),
        .init(88, .camouflage, "disguised as gate code", "phone", ["the gate code is 9876543210, save it"]),
        .init(89, .camouflage, "disguised as invoice", "phone", ["invoice number 9876543210 for your records"]),
        .init(90, .camouflage, "disguised as wifi password", "phone", ["wifi password is 9876543210"]),
        .init(91, .camouflage, "disguised as price", "phone", ["the rate is 9876543210 rupees per night"]),
        .init(92, .camouflage, "disguised as booking ref", "phone", ["booking ref 9876543210 confirmed"]),
        .init(93, .camouflage, "disguised as GST", "phone", ["our gstin is 9876543210 for the bill"]),
        .init(94, .camouflage, "lucky numbers", "phone", ["my lucky numbers are 9 8 7 6 5 4 3 2 1 0"]),
        .init(95, .camouflage, "fake product code", "phone", ["model no AK-9876543210-X"]),
        .init(96, .camouflage, "IP address shape", "phone", ["server at 98.76.54.32"]),
        .init(97, .camouflage, "time shape", "phone", ["meet at 98:76 and 54:32 and 10"]),
        .init(98, .camouflage, "coordinates shape", "phone", ["we are at 9.876543210 N"]),
        .init(99, .camouflage, "handle as property name", "handle", ["the villa is called akshay_goa_villa, look it up"]),
        .init(100, .camouflage, "email as reference", "email", ["quote reference akshay.verma@gmail.com when you write"]),
    ]

    static let encoding: [RedTeamCase] = [
        .init(101, .encoding, "base64 phone", "phone", ["OTg3NjU0MzIxMA=="]),
        .init(102, .encoding, "base64 email", "email", ["YWtzaGF5LnZlcm1hQGdtYWlsLmNvbQ=="]),
        .init(103, .encoding, "base64 no padding", "phone", ["OTg3NjU0MzIxMA"]),
        .init(104, .encoding, "base32 phone", "phone", ["HE3TOMRUGU2TILBA"]),
        .init(105, .encoding, "hex phone", "phone", ["39383736353433323130"]),
        .init(106, .encoding, "hex with 0x", "phone", ["0x39383736353433323130"]),
        .init(107, .encoding, "binary phone", "phone", ["00111001 00111000 00110111 00110110 00110101 00110100 00110011 00110010 00110001 00110000"]),
        .init(108, .encoding, "decimal ASCII codes", "phone", ["57 56 55 54 53 52 51 50 49 48"]),
        .init(109, .encoding, "octal", "phone", ["071 070 067 066 065 064 063 062 061 060"]),
        .init(110, .encoding, "ROT13 platform", "steering", ["jungfncc zr ba avar rvtug frira fvk"]),
        .init(111, .encoding, "Caesar +1", "steering", ["xibutbqq nf"]),
        .init(112, .encoding, "Atbash", "steering", ["dszghzkk nv"]),
        .init(113, .encoding, "Morse digits", "phone", ["----. ---.. --... -.... ..... ....- ...-- ..--- .---- -----"]),
        .init(114, .encoding, "reversed digits", "phone", ["0123456789 read it backwards"]),
        .init(115, .encoding, "URL percent encoding", "phone", ["%39%38%37%36%35%34%33%32%31%30"]),
        .init(116, .encoding, "HTML entities", "phone", ["&#57;&#56;&#55;&#54;&#53;&#52;&#51;&#50;&#49;&#48;"]),
        .init(117, .encoding, "NATO alphabet handle", "handle", ["alpha kilo sierra hotel alpha yankee golf oscar alpha"]),
        .init(118, .encoding, "every other char is noise", "phone", ["9x8x7x6x5x4x3x2x1x0"]),
        .init(119, .encoding, "punycode domain", "links", ["visit xn--80ak6aa92e.com for my details"]),
        .init(120, .encoding, "base64 of handle", "handle", ["YWtzaGF5X2dvYV92aWxsYQ=="]),
    ]

    static let referential: [RedTeamCase] = [
        .init(121, .referential, "look at profile", "phone", ["my number is in my profile bio, just check there"]),
        .init(122, .referential, "search my name", "phone", ["google akshay verma goa villa, you will find my contact"]),
        .init(123, .referential, "arithmetic on price", "phone", ["my number is the listing price followed by my birth year"]),
        .init(124, .referential, "transform previous", "phone", ["take the booking ref and add one to every digit, that's my mobile"]),
        .init(125, .referential, "photo reference", "phone", ["look at the fourth photo in the listing, bottom right corner"]),
        .init(126, .referential, "physical sign", "phone", ["the number painted on the gate is the one to use"]),
        .init(127, .referential, "guessable email format", "email", ["you already know my name, my email is firstname dot lastname at the usual google one"]),
        .init(128, .referential, "same handle everywhere", "handle", ["my handle is the same on every app, you can guess it"]),
        .init(129, .referential, "reverse the ref", "phone", ["reverse my booking reference and dial it"]),
        .init(130, .referential, "review response", "phone", ["I replied to a review last month with my details, go read it"]),
        .init(131, .referential, "business card in listing", "phone", ["there is a business card photo in the house manual"]),
        .init(132, .referential, "subtract to reveal", "phone", ["11111111111 minus 1234567901 is what you want"]),
        .init(133, .referential, "count the letters", "phone", ["count the letters in each word of my next ten messages"]),
        .init(134, .referential, "ask them to share first", "phone", ["just send me your number and I'll text you straight away"]),
    ]

    static let steering: [RedTeamCase] = [
        .init(135, .steering, "move to whatsapp", "steering", ["easier if we continue on whatsapp"]),
        .init(136, .steering, "do you have telegram", "steering", ["do you have telegram? much simpler there"]),
        .init(137, .steering, "I will DM you", "steering", ["I'll DM you on instagram instead"]),
        .init(138, .steering, "off platform cheaper", "steering", ["off platform it's cheaper, no commission for either of us"]),
        .init(139, .steering, "book direct", "steering", ["next time just book direct with me and save the fee"]),
        .init(140, .steering, "cancel and rebook", "steering", ["cancel this booking and rebook with me directly, 20 percent off"]),
        .init(141, .steering, "pay cash", "steering", ["pay cash on arrival and we can skip the platform entirely"]),
        .init(142, .steering, "platform name alone", "steering", ["whatsapp?"]),
        .init(143, .steering, "abbreviation alone", "steering", ["ig?"]),
        .init(144, .steering, "emoji as channel hint", "steering", ["📞? 💬?"]),
    ]

    static let payment: [RedTeamCase] = [
        .init(145, .payment, "UPI VPA", "payment", ["send it to akshay@ybl instead"]),
        .init(146, .payment, "UPI obfuscated", "payment", ["send to akshay at ybl"]),
        .init(147, .payment, "phone as UPI", "payment", ["9876543210@paytm works"]),
        .init(148, .payment, "IFSC and account", "payment", ["a/c 123456789012 ifsc HDFC0001234"]),
        .init(149, .payment, "BTC address", "payment", ["btc 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"]),
        .init(150, .payment, "ETH address", "payment", ["eth 0x742d35Cc6634C0532925a3b844Bc454e4438f44e"]),
        .init(151, .payment, "USDT TRON", "payment", ["usdt TQn9Y2khEsLJW1ChVWFMSMeRDow5oNbxaB"]),
        .init(152, .payment, "PayPal.me", "payment", ["paypal.me/akshayverma"]),
        .init(153, .payment, "Venmo handle", "payment", ["venmo @akshay-verma-9"]),
        .init(154, .payment, "gpay the number", "payment", ["gpay this number 9876543210"]),
    ]

    static let links: [RedTeamCase] = [
        .init(155, .links, "wa.me deep link", "phone", ["wa.me/919876543210"]),
        .init(156, .links, "t.me link", "handle", ["t.me/akshaygoa"]),
        .init(157, .links, "instagram url", "handle", ["instagram.com/akshay_goa_villa"]),
        .init(158, .links, "shortener", "links", ["bit.ly/3xKplm"]),
        .init(159, .links, "linktree", "links", ["linktr.ee/akshaygoa"]),
        .init(160, .links, "spaced domain", "links", ["akshayvilla . com"]),
        .init(161, .links, "domain with dot spelled", "links", ["akshayvilla dot com"]),
        .init(162, .links, "google form", "links", ["forms.gle/abc123 fill this"]),
        .init(163, .links, "qr code mention", "links", ["there is a QR code on the fridge, scan it"]),
        .init(164, .links, "calendly", "links", ["calendly.com/akshaygoa/15min"]),
    ]

    static let layout: [RedTeamCase] = [
        .init(165, .layout, "one digit per line", "phone", ["9\n8\n7\n6\n5\n4\n3\n2\n1\n0"]),
        .init(166, .layout, "acrostic first letters", "phone", ["Nine\nEight\nSeven\nSix\nFive\nFour\nThree\nTwo\nOne\nZero"]),
        .init(167, .layout, "digits in a table", "phone", ["| 98 | 76 |\n| 54 | 32 |\n| 10 |  |"]),
        .init(168, .layout, "label then value on next line", "phone", ["my mobile:\n9876543210"]),
        .init(169, .layout, "email split over lines", "email", ["akshay.verma\n@\ngmail.com"]),
        .init(170, .layout, "handle in signature block", "handle", ["Thanks!\n--\nAkshay\ninsta: akshay_goa_villa"]),
        .init(171, .layout, "digits padded with spaces", "phone", ["9   8   7   6   5   4   3   2   1   0"]),
        .init(172, .layout, "trailing whitespace noise", "phone", ["9\t8\t7\t6\t5\t4\t3\t2\t1\t0"]),
    ]

    static let sequences: [RedTeamCase] = [
        .init(173, .sequence, "halves", "phone", [
            "my number starts 98765",
            "and ends 43210",
        ]),
        .init(174, .sequence, "thirds", "phone", [
            "note this down: 987",
            "then 654",
            "then 3210",
        ]),
        .init(175, .sequence, "one digit per message", "phone", [
            "9", "8", "7", "6", "5", "4", "3", "2", "1", "0",
        ]),
        .init(176, .sequence, "digits with innocent filler between", "phone", [
            "so about the checkout time",
            "98",
            "the cleaner comes at 11",
            "765",
            "and there is parking outside",
            "43210",
        ]),
        .init(177, .sequence, "reversed halves", "phone", [
            "second half first: 43210",
            "first half: 98765",
        ]),
        .init(178, .sequence, "country code then rest", "phone", [
            "+91",
            "98765",
            "43210",
        ]),
        .init(179, .sequence, "words then digits", "phone", [
            "nine eight seven",
            "six five four",
            "three two one zero",
        ]),
        .init(180, .sequence, "platform then handle", "handle", [
            "are you on instagram",
            "akshay_goa_villa",
        ]),
        .init(181, .sequence, "email local then domain", "email", [
            "akshay.verma",
            "gmail.com",
            "put those together",
        ]),
        .init(182, .sequence, "protocol then payload", "phone", [
            "I'll send ten messages, take the first character of each",
            "9pm is checkin", "8am checkout", "7 guests max", "6 towels",
            "5 min to beach", "4 bedrooms", "3 baths", "2 cars", "1 pool", "0 pets",
        ]),
        .init(183, .sequence, "handle split by syllable", "handle", [
            "ak", "shay", "goa", "villa", "join with underscores on insta",
        ]),
        .init(184, .sequence, "number as answers to questions", "phone", [
            "how many bedrooms? nine",
            "how many baths? eight",
            "how many guests? seven six five",
            "and the rest four three two one zero",
        ]),
        .init(185, .sequence, "steer then share", "phone", [
            "this chat is so slow",
            "let's use another app",
            "9876543210",
        ]),
        .init(186, .sequence, "innocent number then instruction", "phone", [
            "the villa number is 9876543210",
            "that's also my mobile by the way",
        ]),
        .init(187, .sequence, "digits as prices", "phone", [
            "breakfast is 98",
            "lunch is 765",
            "dinner is 43210",
            "add those up in order and call it",
        ]),
        .init(188, .sequence, "spelled across messages", "phone", [
            "n i n e",
            "e i g h t",
            "s e v e n",
            "six five four three two one zero",
        ]),
        .init(189, .sequence, "two-message email with separators", "email", [
            "akshay dot verma",
            "at gmail dot com",
        ]),
        .init(190, .sequence, "obfuscated across messages", "phone", [
            "９８７６５",
            "43210",
        ]),
        .init(191, .sequence, "ask them, then confirm", "phone", [
            "whats your number",
            "mine is 9876543210 so you have it too",
        ]),
        .init(192, .sequence, "delayed payload after small talk", "phone", [
            "hope you had a good trip",
            "the weather has been lovely",
            "anyway save this: nine eight seven six five four three two one zero",
        ]),
    ]

    static let positional: [RedTeamCase] = [
        .init(193, .positional, "capitals spell handle", "handle", [
            "Always Keep Some House And Yard Guests Organised Always",
        ]),
        .init(194, .positional, "capitals spell handle, with hint", "handle", [
            "Always Keep Some House And Yard Guests Organised Always — read the capitals",
        ]),
        .init(195, .positional, "scattered capitals mid-word", "handle", [
            "the villA is Kept Spotless, House has Ample Yard space",
        ]),
        .init(196, .positional, "capitals spell platform", "steering", [
            "We Have A Terrace, Sunset Are Perfect, Peaceful too",
        ]),

        .init(197, .positional, "first letter of each line", "handle", [
            "Anyone can park outside.\nKids are welcome too.\nShoes off inside please.\nHot water is always on.\nAsk if you need towels.\nYou will love the view.",
        ]),
        .init(198, .positional, "first word of each line is a digit word", "phone", [
            "Nine am checkin\nEight pm checkout\nSeven guests max\nSix towels provided\nFive minutes to beach\nFour bedrooms total\nThree bathrooms\nTwo parking spots\nOne swimming pool\nZero pets allowed",
        ]),
        .init(199, .positional, "first word of each paragraph", "handle", [
            "Airy and bright rooms throughout.\n\nKitchen fully stocked for you.\n\nSpotless linen every stay.\n\nHot water round the clock.\n\nAmple parking on site.\n\nYard is completely private.",
        ]),
        .init(200, .positional, "first letter of each sentence", "handle", [
            "All guests get a welcome drink. Kitchen is yours to use. Sunsets here are unreal. House keys in the lockbox. Ask me anything at all. Yard has a hammock.",
        ]),
        .init(201, .positional, "last letter of each word", "handle", [
            "extrA silK cheS higH extrA anY",
        ]),

        .init(202, .positional, "word lengths encode digits", "phone", [
            "wonderful elephant giraffe cannot bring four the be a incredible",
        ]),
        .init(203, .positional, "count of dots encodes digit", "phone", [
            "yes......... no........ maybe....... ok...... sure..... fine.... hmm... ah.. k. done",
        ]),
        .init(204, .positional, "emoji count encodes digit", "phone", [
            "🙂🙂🙂🙂🙂🙂🙂🙂🙂 then 🙂🙂🙂🙂🙂🙂🙂🙂 then 🙂🙂🙂🙂🙂🙂🙂",
        ]),
        .init(205, .positional, "list item count", "phone", [
            "Bring:\n- towel\n- hat\n- shoes\n- book\n- charger\n- snacks\n- water\n- cash\n- map\ncount them",
        ]),

        .init(206, .positional, "bold markers around letters", "handle", [
            "*a*nother *k*ind *s*pot, *h*appy *a*lways, *y*ours",
        ]),
        .init(207, .positional, "letters in brackets", "handle", [
            "the villa(a) is(k) very(s) nice(h) and(a) sunny(y)"
        ]),
        .init(208, .positional, "every second word initial", "handle", [
            "come Along and Keep it Simple with Hot tea And Yoga",
        ]),

        .init(209, .positional, "first letter of each message", "handle", [
            "Always available for questions",
            "Kitchen is fully stocked",
            "Spotless linen every time",
            "Hot water all day",
            "Ample parking outside",
            "Yard is totally private",
        ]),
        .init(210, .positional, "word count per message encodes digit", "phone", [
            "one two three four five six seven eight nine",
            "one two three four five six seven eight",
            "one two three four five six seven",
        ]),
        .init(211, .positional, "message length encodes digit", "phone", [
            "aaaaaaaaa", "aaaaaaaa", "aaaaaaa", "aaaaaa", "aaaaa",
            "aaaa", "aaa", "aa", "a", "",
        ]),
        .init(212, .positional, "capitals across messages", "steering", [
            "Weather is lovely today",
            "Hope the trip went well",
            "Anyway let me know",
            "Tomorrow is fine too",
            "Sunset is at seven",
            "All good from my side",
            "Perfect then",
            "ประtty much sorted",
        ]),
        .init(213, .positional, "acrostic poem", "handle", [
            "Away from the noise\nKind hosts nearby\nSunlight all morning\nHammocks on the deck\nAlways a warm welcome\nYours to enjoy",
        ]),
        .init(214, .positional, "nth character rule stated", "phone", [
            "take every third character: x9xx8xx7xx6xx5xx4xx3xx2xx1xx0",
        ]),
    ]
}

struct RedTeamResult: Identifiable {
    let id = UUID()
    let testCase: RedTeamCase
    let verdicts: [Verdict]

    var caught: Bool {
        verdicts.contains { $0.action != .allow && $0.action != .hint }
    }
    var hintedOnly: Bool {
        !caught && verdicts.contains { $0.action == .hint }
    }
    var bestScore: Double { verdicts.map(\.score).max() ?? 0 }
    var totalLatency: Double { verdicts.map(\.latencyMs).reduce(0, +) }
    var strongestAction: ModAction {
        verdicts.max(by: { $0.action.rank < $1.action.rank })?.action ?? .allow
    }
}

struct RedTeamReport {
    var results: [RedTeamResult] = []

    var total: Int { results.count }
    var caught: Int { results.filter(\.caught).count }
    var hintedOnly: Int { results.filter(\.hintedOnly).count }
    var missed: Int { total - caught }
    var catchRate: Double { total == 0 ? 0 : Double(caught) / Double(total) }

    var meanLatency: Double {
        let all = results.flatMap { $0.verdicts.map(\.latencyMs) }
        return all.isEmpty ? 0 : all.reduce(0, +) / Double(all.count)
    }

    func byFamily(_ family: RedTeamFamily) -> [RedTeamResult] {
        results.filter { $0.testCase.family == family }
    }

    func catchRate(_ family: RedTeamFamily) -> Double {
        let subset = byFamily(family)
        guard !subset.isEmpty else { return 0 }
        return Double(subset.filter(\.caught).count) / Double(subset.count)
    }

    var misses: [RedTeamResult] { results.filter { !$0.caught } }
}

enum RedTeamSuite {

    static func run(
        trust: TrustTier = .standard,
        stage: BookingStage = .inquiry
    ) -> RedTeamReport {
        let engine = ModerationEngine.shared
        var report = RedTeamReport()

        for testCase in RedTeamCorpus.all {
            let actor = ActorContext(
                trust: trust,
                stage: stage,
                priorViolations: 0,
                conversationID: "redteam-\(testCase.id)",
                senderID: "broker"
            )
            engine.resetBuffer(actor: actor)

            var verdicts: [Verdict] = []
            for message in testCase.messages {
                let verdict = engine.evaluate(message, actor: actor, useConversationBuffer: true)
                verdicts.append(verdict)
                if !verdict.action.withholdsMessage {
                    engine.remember(message, actor: actor)
                }
            }

            report.results.append(RedTeamResult(testCase: testCase, verdicts: verdicts))
        }

        return report
    }
}
