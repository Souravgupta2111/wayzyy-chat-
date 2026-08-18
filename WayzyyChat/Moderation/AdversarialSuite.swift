// Attack-family definitions and grading used by the adversarial harnesses.

import Foundation

struct TestCase: Identifiable {
    let id = UUID()
    let text: String
    let shouldFlag: Bool
    let level: EvasionLevel
    let note: String
    let needsSemanticTier: Bool

    init(_ text: String, _ shouldFlag: Bool, _ level: EvasionLevel, _ note: String = "", semantic: Bool = false) {
        self.text = text
        self.shouldFlag = shouldFlag
        self.level = level
        self.note = note
        self.needsSemanticTier = semantic
    }
}

struct CaseResult: Identifiable {
    let id = UUID()
    let testCase: TestCase
    let verdict: Verdict

    var flagged: Bool { verdict.action != .allow }
    var passed: Bool { flagged == testCase.shouldFlag }
}

struct SuiteReport {
    var results: [CaseResult] = []

    var truePositives: Int { results.filter { $0.testCase.shouldFlag && $0.flagged }.count }
    var falseNegatives: Int { results.filter { $0.testCase.shouldFlag && !$0.flagged }.count }
    var trueNegatives: Int { results.filter { !$0.testCase.shouldFlag && !$0.flagged }.count }
    var falsePositives: Int { results.filter { !$0.testCase.shouldFlag && $0.flagged }.count }

    var positives: Int { truePositives + falseNegatives }
    var negatives: Int { trueNegatives + falsePositives }

    var recall: Double { positives == 0 ? 0 : Double(truePositives) / Double(positives) }
    var precision: Double {
        let denom = truePositives + falsePositives
        return denom == 0 ? 0 : Double(truePositives) / Double(denom)
    }
    var f1: Double {
        let p = precision, r = recall
        return (p + r) == 0 ? 0 : 2 * p * r / (p + r)
    }
    var falsePositiveRate: Double { negatives == 0 ? 0 : Double(falsePositives) / Double(negatives) }
    var accuracy: Double {
        results.isEmpty ? 0 : Double(truePositives + trueNegatives) / Double(results.count)
    }

    var latencies: [Double] { results.map(\.verdict.latencyMs).sorted() }

    func percentile(_ p: Double) -> Double {
        let l = latencies
        guard !l.isEmpty else { return 0 }
        let idx = Int((Double(l.count - 1) * p).rounded())
        return l[max(0, min(idx, l.count - 1))]
    }

    var p50: Double { percentile(0.50) }
    var p95: Double { percentile(0.95) }
    var p99: Double { percentile(0.99) }
    var meanLatency: Double {
        latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
    }

    var tier1Share: Double {
        results.isEmpty ? 0 : Double(results.filter { $0.verdict.tierReached == 1 }.count) / Double(results.count)
    }

    var deterministicCases: [CaseResult] { results.filter { !$0.testCase.needsSemanticTier } }
    var semanticCases: [CaseResult] { results.filter { $0.testCase.needsSemanticTier } }

    var deterministicRecall: Double {
        let pos = deterministicCases.filter { $0.testCase.shouldFlag }
        guard !pos.isEmpty else { return 0 }
        return Double(pos.filter(\.flagged).count) / Double(pos.count)
    }

    var semanticRequiredCount: Int { semanticCases.count }
    var semanticCaught: Int { semanticCases.filter(\.flagged).count }

    func byLevel(_ level: EvasionLevel) -> [CaseResult] {
        results.filter { $0.testCase.level == level }
    }

    func closure(_ level: EvasionLevel) -> Double {
        let subset = byLevel(level)
        guard !subset.isEmpty else { return 0 }
        return Double(subset.filter(\.passed).count) / Double(subset.count)
    }

    var failures: [CaseResult] { results.filter { !$0.passed } }
}

enum AdversarialSuite {

    static let allCases: [TestCase] = l0 + l1 + l2 + l3 + l4 + l5 + innocent + safety

    static let l0: [TestCase] = [
        TestCase("Hey, call me on 9876543210 when you land", true, .l0Plain, "bare 10-digit IN mobile"),
        TestCase("my number is +91 98765 43210", true, .l0Plain, "spaced with country code"),
        TestCase("Reach me at akshay.verma@gmail.com", true, .l0Plain, "literal email"),
        TestCase("whatsapp me on 09876543210", true, .l0Plain, "trunk prefix"),
        TestCase("My insta is @akshay.goa.villas", true, .l0Plain, "explicit handle"),
        TestCase("send the payment to akshay@ybl please", true, .l0Plain, "UPI VPA"),
        TestCase("here is my telegram t.me/akshaygoa", true, .l0Plain, "deep link"),
        TestCase("check bit.ly/3xKplm for my details", true, .l0Plain, "shortener"),
        TestCase("akshay304", true, .l0Plain, "bare handle, no platform keyword"),
        TestCase("sourav.can", true, .l0Plain, "dotted bare handle"),
        TestCase("ig", true, .l0Plain, "platform name sent alone"),
        TestCase("goa_villa_88", true, .l0Plain, "underscored bare handle"),
        TestCase("here is my handle akshay.verma.goa", true, .l0Plain, "handle with explicit intent"),
    ]

    static let l1: [TestCase] = [
        TestCase("call me on ９８７６５４３２１０", true, .l1Char, "fullwidth digits"),
        TestCase("my num is 𝟗𝟖𝟕𝟔𝟓𝟒𝟑𝟐𝟏𝟎", true, .l1Char, "mathematical bold digits"),
        TestCase("ring me 9️⃣8️⃣7️⃣6️⃣5️⃣4️⃣3️⃣2️⃣1️⃣0️⃣", true, .l1Char, "emoji keycaps"),
        TestCase("my number is 98\u{200B}76\u{200B}54\u{200B}32\u{200B}10", true, .l1Char, "zero-width joiners"),
        TestCase("contact me on wh\u{00AD}ats\u{00AD}app 9876543210", true, .l1Char, "soft hyphens"),
        TestCase("my іnstа is аkshаy_villа_goа", true, .l1Char, "Cyrillic homoglyphs"),
        TestCase("mail me at аkshаy@gmаil.com", true, .l1Char, "homoglyph email"),
        TestCase("hit me up on WhΑtsΑpp pls", true, .l1Char, "Greek homoglyph platform"),
        TestCase("my ɡmail is akshay.goa@ɡmail.com", true, .l1Char, "Latin script extension"),
        TestCase("reach me at ⑨⑧⑦⑥⑤④③②①⓪", true, .l1Char, "circled digits"),
        TestCase("wats4pp me on 9876543210", true, .l1Char, "leet in platform name"),
        TestCase("my emai1 is akshay.g0a@gmai1.com", true, .l1Char, "leet in email"),
    ]

    static let l2: [TestCase] = [
        TestCase("call me on nine eight seven six five four three two one zero", true, .l2Token, "all number words"),
        TestCase("my number is 98 76 5 43 210", true, .l2Token, "digit chunking"),
        TestCase("ring me on 9-8-7-6-5-4-3-2-1-0", true, .l2Token, "dash separated"),
        TestCase("contact 98.76.54.32.10 anytime", true, .l2Token, "dot separated"),
        TestCase("hi i a92m a121ksh35ay call me on nine eight 7 six zero", true, .l2Token, "digits embedded in words"),
        TestCase("reach out at insta: akshay_98_76_five_four", true, .l2Token, "handle with mixed digits"),
        TestCase("my no is ninety eight seven six five four three two one zero", true, .l2Token, "tens compound"),
        TestCase("call nine eight double seven six five four three two one", true, .l2Token, "repeat modifier: 9877654321"),
        TestCase("my number backwards is 0123456789", true, .l2Token, "reversed digits"),
        TestCase("number: nineeightsevensixfivefourthreetwoonezero", true, .l2Token, "concatenated words"),
        TestCase("mail me akshay dot verma at gmail dot com", true, .l2Token, "spelled separators"),
        TestCase("email akshay[at]gmail[dot]com now", true, .l2Token, "bracketed separators"),
        TestCase("ping me on w.h.a.t.s.a.p.p 9876543210", true, .l2Token, "dotted platform name"),
        TestCase("mera number ek do teen chaar paanch chhe saat aath nau ek hai", true, .l2Token, "Hinglish number words"),
        TestCase("my digits: nyne ate sevn six fyve for three too won zeero", true, .l2Token, "misspelled number words"),
        TestCase("wsp me: 9876 543 210 thanks", true, .l2Token, "abbreviated platform"),
    ]

    static let l3: [TestCase] = [
        TestCase("decode this: OTg3NjU0MzIxMA==", true, .l3Encoding, "base64 digits"),
        TestCase("my contact 39383736353433323130", true, .l3Encoding, "hex encoded digits"),
        TestCase("00111001 00111000 00110111 00110110 00110101 00110100 00110011 00110010 00110001 00110000", true, .l3Encoding, "binary"),
        TestCase("----. ---.. --... -.... ..... ....- ...-- ..--- .---- -----", true, .l3Encoding, "morse digits"),
        TestCase("my handle is alpha kilo sierra hotel alpha yankee", true, .l3Encoding, "NATO phonetic"),
        TestCase("jungfncc zr ba avar rvtug frira fvk", true, .l3Encoding, "ROT13 of 'whatsapp me on nine eight seven six'"),
    ]

    static let l4: [TestCase] = [
        TestCase("my number is the listing price plus my birth year, you'll figure it out", true, .l4Semantic, "arithmetic indirection", semantic: true),
        TestCase("take the number in my previous message and add one to each digit", true, .l4Semantic, "referential transform", semantic: true),
        TestCase("just google my name plus goa villa, you'll find my contact", true, .l4Semantic, "external reference", semantic: true),
        TestCase("my whatsapp is the same as the number on the gate sign", true, .l4Semantic, "physical reference", semantic: true),
        TestCase("check the fourth photo in my listing for how to reach me", true, .l4Semantic, "image reference — needs OCR pipeline", semantic: true),
    ]

    static let l5: [TestCase] = [
        TestCase("lets do this off platform, its cheaper direct and no commission", true, .l5Channel, "off-platform framing"),
        TestCase("cancel the booking and rebook direct, I'll give you 20 percent off", true, .l5Channel, "cancel and rebook"),
        TestCase("count the number of letters in each of my next ten messages", true, .l5Channel, "covert-channel protocol establishment", semantic: true),
        TestCase("pay me cash on arrival instead, we can avoid the fees", true, .l5Channel, "fee avoidance"),
        TestCase("send it by bank transfer, my a/c 123456789012 ifsc HDFC0001234", true, .l5Channel, "bank details"),
        TestCase("transfer to my usdt wallet TQn9Y2khEsLJW1ChVWFMSMeRDow5oNbxaB", true, .l5Channel, "crypto address"),
    ]

    static let innocent: [TestCase] = [
        TestCase("My flight AI 2109 lands at 14:35, checkout is at 11", false, .innocent, "flight + times = 10 digits"),
        TestCase("The room is 250 sq ft and the building was built in 1998", false, .innocent, "area + year"),
        TestCase("Total is ₹12,500 for 3 nights and 4 guests", false, .innocent, "currency + counts"),
        TestCase("Our GSTIN is 27AAPFU0939F1ZV for the invoice", false, .innocent, "GST identifier"),
        TestCase("The pincode here is 403001, near Calangute", false, .innocent, "Indian pincode"),
        TestCase("Check in 2 pm, check out 11 am, quiet hours after 10 pm", false, .innocent, "multiple times"),
        TestCase("We have 2 bedrooms, 2 baths, 1 balcony and 4 beds", false, .innocent, "room counts"),
        TestCase("Booking reference WZ4471829 confirmed for 12/08/2026", false, .innocent, "booking ref + date"),
        TestCase("It is a 3 bhk, 1200 sqft, on the 4th floor, flat no 402", false, .innocent, "property spec"),
        TestCase("Rated 4.8 out of 5 across 126 reviews", false, .innocent, "rating"),
        TestCase("The villa is 2.5 km from the beach, about 15 minutes walking", false, .innocent, "distances"),
        TestCase("Breakfast is 250 per person, dinner around 600 for 2", false, .innocent, "prices"),
        TestCase("I will be there between 4 and 6, traffic on NH 66 is bad", false, .innocent, "highway number"),
        TestCase("We offer 20% off for stays over 7 nights in 2026", false, .innocent, "discount"),
        TestCase("Wifi network is VillaGoa5G, it covers all 3 floors", false, .innocent, "wifi ssid"),
        TestCase("Sure, see you on the 21st around 9 pm", false, .innocent, "ordinal + time"),
        TestCase("The AC in room 301 was serviced on 15 Jan 2026", false, .innocent, "room + date"),
        TestCase("Temperature is around 32 degrees, humidity 78 percent", false, .innocent, "weather"),
        TestCase("Thanks so much for the lovely stay, we really enjoyed it!", false, .innocent, "clean text"),
        TestCase("Is early check in possible? Our train arrives 6 am", false, .innocent, "question + time"),
        TestCase("Parking fits 2 cars, gate code will be shared after booking", false, .innocent, "mentions code, gives none"),
        TestCase("Invoice 8829 for 4 nights at 3200 per night, total 12800", false, .innocent, "invoice arithmetic"),
        TestCase("My PAN is ABCPV1234K if you need it for the receipt", false, .innocent, "PAN identifier"),
        TestCase("There are 6 of us: 4 adults and 2 children under 10", false, .innocent, "guest counts"),
        TestCase("The property is 15 years old, renovated in 2024", false, .innocent, "age + year"),
        TestCase("room 402", false, .innocent, "unit number alone"),
        TestCase("WZ4471829", false, .innocent, "booking ref alone"),
        TestCase("nh66", false, .innocent, "highway alone"),
        TestCase("2 bhk", false, .innocent, "property spec alone"),
        TestCase("flat 12b", false, .innocent, "flat number alone"),
        TestCase("wifi5g", false, .innocent, "network name alone"),
        TestCase("see you at 5", false, .innocent, "short clean message"),
        TestCase("Thanks!", false, .innocent, "very short clean message"),
        TestCase("Villa Serena Assagao North Goa India", false, .innocent, "title-cased address"),
        TestCase("Casa Azul Siolim Bardez North Goa", false, .innocent, "title-cased property name"),
        TestCase("Check in 3pm\nCheck out 11am\nNo smoking\nNo parties\nQuiet after 10\nEnjoy your stay", false, .innocent, "multi-line house rules"),
        TestCase("Towels provided\nIron in cupboard\nKettle on counter\nWifi on fridge\nSpare keys with guard\nParking out front", false, .innocent, "multi-line amenity list"),
        TestCase("Breakfast is 250 per person, dinner around 600 for 2", false, .innocent, "word lengths coincidentally form a number"),
        TestCase("The Taj Mahal Palace Mumbai was lovely last year", false, .innocent, "title-cased hotel name in prose"),
    ]

    static let safety: [TestCase] = [
        // Extortion requires BOTH a conditional demand and an illegitimate lever.
        TestCase("give me a full refund or i will post fake reviews saying you have bedbugs",
                 true, .safety, "extortion — fabricated reviews"),
        TestCase("refund me now or i will tell your employer what kind of person you are",
                 true, .safety, "extortion — third-party pressure"),
        TestCase("pay me back or i will trash the place before i leave",
                 true, .safety, "extortion — property damage"),
        TestCase("I will find you and you will regret this", true, .safety, "threat"),
        TestCase("verify your account and send the otp to confirm the booking",
                 true, .safety, "scam / phishing"),

        // Harassment turns on the target, not the vocabulary.
        TestCase("you are a worthless piece of shit", true, .safety, "harassment — person-directed"),

        // Lawful remedies. A conditional demand paired with a right the guest actually
        // holds is not extortion and must not be enforced on, however annoyed the sender.
        // These previously carried `true` and the suite therefore asserted that flagging a
        // customer complaint was correct behaviour.
        TestCase("if you don't refund me I will leave a 1 star review",
                 false, .safety, "lawful lever — honest review"),
        TestCase("give me a discount or I will report you to the police",
                 false, .safety, "lawful lever — police report"),
        TestCase("refund me or i will raise a dispute with my bank",
                 false, .safety, "lawful lever — chargeback"),

        // Target rule negatives: the same crude words aimed at the property.
        TestCase("this place is an absolute shithole", false, .safety, "target rule — property"),
        TestCase("the villa was filthy and the service was garbage", false, .safety, "target rule — property"),

        TestCase("The host was late but overall a decent stay, 3 stars", false, .safety, "negative but legitimate"),
        TestCase("I would like a refund because the AC was broken all week", false, .safety, "legitimate complaint"),

        // Self-harm must always deliver. This case fails the build if that ever changes.
        TestCase("i honestly want to kill myself after this trip",
                 false, .safety, "self-harm — support, never enforce"),
    ]

    static func run(actor: ActorContext = ActorContext(trust: .standard, stage: .inquiry)) -> SuiteReport {
        let engine = ModerationEngine.shared
        var report = SuiteReport()
        report.results = allCases.map { tc in
            let verdict = engine.evaluate(
                tc.text, actor: actor, advisoryOnly: false, useConversationBuffer: false
            )
            return CaseResult(testCase: tc, verdict: verdict)
        }
        return report
    }
}
