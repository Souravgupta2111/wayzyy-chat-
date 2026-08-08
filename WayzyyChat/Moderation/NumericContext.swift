// Classifies what a number means — price, time, booking reference, dimension — so legitimate digits are not masked.

import Foundation

enum NumericContext {

    private static let placeholder: Character = "·"

    private static let patternSources: [(String, String)] = [
        ("time", #"\b\d{1,2}\s*[:.]\s*\d{2}\s*(?:am|pm|hrs)?\b"#),
        ("time-bare", #"\b\d{1,2}\s*(?:am|pm)\b"#),
        ("time-range", #"\b\d{1,2}\s*(?:-|to|till|until)\s*\d{1,2}\s*(?:am|pm)\b"#),

        ("year", #"\b(?:19|20)\d{2}\b"#),
        ("built-in", #"\b(?:built|renovated|since|established|est)\D{0,6}\d{4}\b"#),

        ("currency-pre", #"(?:₹|rs\.?|inr|\$|usd|us\$|€|eur|£|gbp|aed|sgd)\s*\d[\d,]*(?:\.\d+)?"#),
        ("currency-post", #"\b\d[\d,]*(?:\.\d+)?\s*(?:rupees|rupee|rupay|rupaye|rupaiya|rupaya|rs\b|inr|usd|dollars?|euros?|eur|pounds?|gbp|aed|k\b|hazaar|hazar|lakh|lakhs|lac|crore|crores|taka|paise|paisa)\b"#),
        ("currency-verb", #"\b\d[\d,]*(?:\.\d+)?\s*(?:\w+\s+)?(?:de\s?dena|dedena|de\s?do|dedo|bhej\s?dena|bhejdena|bhej\s?do|le\s?lena|lelena|paid|pay|refund)\b"#),
        ("per-night", #"\b\d[\d,]*\s*(?:per|a|\/)\s*(?:night|day|week|month|person|guest|head)\b"#),

        ("units", #"\b\d+(?:\.\d+)?\s*(?:sq\.?\s?(?:ft|m|feet|meters?|metres?)|sqft|sqm|km|kms|kilometer?s?|mtr|meters?|metres?|ft\b|feet|inch(?:es)?|cm|mm|kg|kgs|gms?|grams?|lit(?:re|er)s?|ltr|ml|mins?|minutes?|hrs?|hours?|days?|nights?|weeks?|months?|years?|guests?|adults?|children|kids|infants?|people|persons?|pax|bhk|bedrooms?|beds?|bathrooms?|baths?|washrooms?|rooms?|floors?|storey|stories|balcon(?:y|ies)|star|stars|reviews?|ratings?|seats?|cars?|steps?|degrees?|°c|°f|%)\b"#),

        ("ordinal", #"\b\d{1,2}(?:st|nd|rd|th)\b"#),
        ("date-slash", #"\b\d{1,2}\s*[/\-.]\s*\d{1,2}(?:\s*[/\-.]\s*\d{2,4})?\b"#),
        ("date-month", #"\b\d{1,2}\s*(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\b"#),
        ("month-date", #"\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\s*\d{1,2}\b"#),

        ("gstin", #"\b\d{2}[a-z]{5}\d{4}[a-z]\d[a-z]{2}\b"#),
        ("pan", #"\b[a-z]{5}\d{4}[a-z]\b"#),
        ("pincode", #"\b(?:pin\s?-?code|pincode|pin|zip|postal\s?code)\D{0,8}\d{6}\b"#),
        ("hsn", #"\b(?:hsn|sac)\D{0,6}\d{4,8}\b"#),

        ("flight", #"\b(?:flight|fl|pnr|train|bus|ticket|seat|gate|terminal)\D{0,8}[a-z0-9]{0,3}\s?\d{1,6}\b"#),
        ("booking-ref", #"\b(?:booking|reservation|confirmation|conf|order|invoice|receipt|ref|reference|id)\W{0,4}(?:no\.?|number|code|id|#)?\W{0,4}[a-z0-9][a-z0-9\-]{3,20}\b"#),

        ("unit-no", #"\b(?:flat|apt|apartment|room|unit|block|floor|door|house|villa|plot|survey|shop|gate|tower|wing)\s*(?:no\.?|#)?\s*\d{1,5}\b"#),
        ("highway", #"\b(?:nh|sh|highway|route)\s*-?\s*\d{1,3}\b"#),

        ("rating", #"\b\d(?:\.\d)?\s*(?:/|out of)\s*(?:5|10)\b"#),
        ("percent", #"\b\d{1,3}\s*(?:%|percent|percentage)\b"#),

        ("wifi", #"\b(?:wifi|wi-fi|ssid|network)\D{0,10}[a-z0-9_\-]{2,20}\b"#),

        ("approx", #"\b(?:approx|about|around|roughly|nearly|almost|under|over|within)\s*\d{1,4}\b"#),
    ]

    private static let compiled: [(String, NSRegularExpression)] = {
        patternSources.compactMap { name, pattern in
            guard let rx = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                assertionFailure("NumericContext: bad pattern \(name)")
                return nil
            }
            return (name, rx)
        }
    }()

    struct Result {
        var view: CharView
        var firedRules: [String]
        var maskedCharacterCount: Int
        var protectedRanges: [Range<Int>]
    }

    private static let chainRX = try? NSRegularExpression(
        pattern: #"\d{1,5}(?:[\s.,\-/]{1,3}\d{1,5}){3,}"#,
        options: []
    )

    static func analyze(_ view: CharView) -> Result {
        let text = view.text
        guard !text.isEmpty else {
            return Result(view: view, firedRules: [], maskedCharacterCount: 0, protectedRanges: [])
        }

        var maskedIndices = Set<Int>()
        var fired: [String] = []
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let table = OffsetTable(text)

        var protectedIndices = Set<Int>()
        var protectedRanges: [Range<Int>] = []
        chainRX?.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
            guard let match, let r = Range(match.range, in: text) else { return }
            let body = String(text[r])
            let digitCount = body.filter { $0.isNumber }.count
            guard digitCount >= 9, digitCount <= 15 else { return }
            guard let start = table.offset(r.lowerBound),
                  let end = table.offset(r.upperBound) else { return }
            protectedRanges.append(start..<end)
            for i in start..<end { protectedIndices.insert(i) }
        }

        for (name, rx) in compiled {
            var ruleFired = false
            rx.enumerateMatches(in: text, options: [], range: full) { match, _, _ in
                guard let match,
                      let range = Range(match.range, in: text) else { return }
                guard let start = table.offset(range.lowerBound),
                      let end = table.offset(range.upperBound) else { return }
                for i in start..<end where i < view.chars.count {
                    if view.chars[i].isNumber, !protectedIndices.contains(i) {
                        maskedIndices.insert(i)
                        ruleFired = true
                    }
                }
            }
            if ruleFired { fired.append(name) }
        }

        guard !maskedIndices.isEmpty else {
            return Result(view: view, firedRules: [], maskedCharacterCount: 0, protectedRanges: protectedRanges)
        }

        var chars = view.chars
        for i in maskedIndices { chars[i] = placeholder }

        let masked = CharView(
            chars: chars,
            offsets: view.offsets,
            transforms: view.transforms + ["numeric-context-mask"]
        )

        return Result(
            view: masked,
            firedRules: fired,
            maskedCharacterCount: maskedIndices.count,
            protectedRanges: protectedRanges
        )
    }

    static func mask(_ view: CharView) -> CharView {
        analyze(view).view
    }
}
