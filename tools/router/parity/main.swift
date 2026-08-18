// Does the Swift scorer agree with the Python trainer?
//
// Two implementations of the same hash and the same preprocessing will drift, and the drift is
// silent: the model keeps returning plausible-looking numbers that no longer correspond to what
// it was fitted to. This prints Swift's scores so they can be diffed against Python's.

import Foundation

guard let router = try? AbuseRouter.load(contentsOf: "config/abuse-router.weights") else {
    FileHandle.standardError.write(Data("cannot load weights\n".utf8))
    exit(1)
}

let cases = [
    "Chal chutiye", "Nikal bhosdike", "Gand mara", "Kya karogee bkl",
    "Pussy ass bitch", "Hiey frank , you dogshit peace of crack",
    "chutiyapa band kar", "tu chutiyaa hai", "ch00tiye", "bhosadike saale",
    "madarchod kahin ka", "Kya rate hai bhai", "ghar saaf tha thanks",
    "bhai thoda discount ho jayega", "chal bhai booking kar dete hain",
    "the cleaning was terrible and i am furious about it",
    "this villa is filthy and the host is incompetent",
    "chai milegi subah", "gaon mein hai property", "call me on 9876543210",
    "my whatsapp is 98765 43210", "see you at 5", "nh66", "मैं तुझे मार डालूंगा",
]

for text in cases {
    print(String(format: "%.6f\t", router.score(text)) + text)
}

// Latency: this sits on the send path, so its cost has to be measured rather than assumed.
let sample = "tu ek number ka chutiya hai bhai, nikal ja yahan se"
var warm = 0.0
for _ in 0..<200 { warm += router.score(sample) }
let started = DispatchTime.now().uptimeNanoseconds
let iterations = 5_000
for _ in 0..<iterations { warm += router.score(sample) }
let perCall = Double(DispatchTime.now().uptimeNanoseconds - started) / Double(iterations) / 1000
FileHandle.standardError.write(Data(String(format: "\nweights %d · %.1f us per score\n",
                                           router.weightCount, perCall).utf8))
