import { ModCategory } from './ModerationTypes';

export enum IntentClass {
    referentialContact = "referentialContact",
    platformSteering = "platformSteering",
    offPlatformBooking = "offPlatformBooking",
    paymentRedirect = "paymentRedirect",
    credentialSolicit = "credentialSolicit",
    encodedInstruction = "encodedInstruction",

    threatOfHarm = "threatOfHarm",
    reviewBlackmail = "reviewBlackmail",
    harassmentAbuse = "harassmentAbuse",
    phishingLure = "phishingLure",
    sexualHarassment = "sexualHarassment"
}

export function intentCategory(intent: IntentClass): ModCategory {
    switch (intent) {
        case IntentClass.referentialContact: return ModCategory.ReferentialContact;
        case IntentClass.platformSteering: return ModCategory.SocialHandle;
        case IntentClass.offPlatformBooking: return ModCategory.Scam;
        case IntentClass.paymentRedirect: return ModCategory.PaymentHandle;
        case IntentClass.credentialSolicit: return ModCategory.ReferentialContact;
        case IntentClass.encodedInstruction: return ModCategory.ReferentialContact;
        case IntentClass.threatOfHarm: return ModCategory.Threat;
        case IntentClass.reviewBlackmail: return ModCategory.Coercion;
        case IntentClass.harassmentAbuse: return ModCategory.Harassment;
        case IntentClass.phishingLure: return ModCategory.Scam;
        case IntentClass.sexualHarassment: return ModCategory.Sexual;
    }
}

export function intentIsSafety(intent: IntentClass): boolean {
    switch (intent) {
        case IntentClass.threatOfHarm:
        case IntentClass.reviewBlackmail:
        case IntentClass.harassmentAbuse:
        case IntentClass.phishingLure:
        case IntentClass.sexualHarassment:
            return true;
        default:
            return false;
    }
}

export function intentDisplay(intent: IntentClass): string {
    switch (intent) {
        case IntentClass.referentialContact: return "Contact details held elsewhere";
        case IntentClass.platformSteering: return "Steering off-platform";
        case IntentClass.offPlatformBooking: return "Off-platform booking";
        case IntentClass.paymentRedirect: return "Payment redirection";
        case IntentClass.credentialSolicit: return "Soliciting your details";
        case IntentClass.encodedInstruction: return "Covert-channel instruction";
        case IntentClass.threatOfHarm: return "Threat of harm";
        case IntentClass.reviewBlackmail: return "Blackmail or extortion";
        case IntentClass.harassmentAbuse: return "Harassment";
        case IntentClass.phishingLure: return "Phishing attempt";
        case IntentClass.sexualHarassment: return "Sexual harassment";
    }
}

export interface Exemplar {
    text: string;
    intent: IntentClass;
}

export class IntentExemplars {
    static referential: Exemplar[] = [
        { text: "my number is in my profile bio just check there", intent: IntentClass.referentialContact },
        { text: "you can find my contact details on my profile page", intent: IntentClass.referentialContact },
        { text: "my digits are on my bio, have a look", intent: IntentClass.referentialContact },
        { text: "everything you need is in my about me section", intent: IntentClass.referentialContact },
        { text: "check my profile, it is all written there", intent: IntentClass.referentialContact },
        { text: "look at my account details for how to reach me", intent: IntentClass.referentialContact },
        { text: "google my name plus goa villa and you will find my contact", intent: IntentClass.referentialContact },
        { text: "just search for me online, my number comes up", intent: IntentClass.referentialContact },
        { text: "look me up on the internet, you will see my mobile", intent: IntentClass.referentialContact },
        { text: "search my property name and you get my phone", intent: IntentClass.referentialContact },
        { text: "the number painted on the gate is the one to use", intent: IntentClass.referentialContact },
        { text: "there is a phone number on the sign outside the house", intent: IntentClass.referentialContact },
        { text: "my mobile is written on the board at the entrance", intent: IntentClass.referentialContact },
        { text: "the caretaker has my number written down", intent: IntentClass.referentialContact },
        { text: "look at the fourth photo in the listing for my details", intent: IntentClass.referentialContact },
        { text: "my contact is in one of the pictures on the listing", intent: IntentClass.referentialContact },
        { text: "there is a business card photo in the house manual", intent: IntentClass.referentialContact },
        { text: "check the image in the description, bottom corner", intent: IntentClass.referentialContact },
        { text: "my number is the listing price followed by my birth year", intent: IntentClass.referentialContact },
        { text: "take the booking reference and add one to every digit", intent: IntentClass.referentialContact },
        { text: "subtract eleven from the number in my last message", intent: IntentClass.referentialContact },
        { text: "my mobile is the villa number with the digits reversed", intent: IntentClass.referentialContact },
        { text: "my handle is the same on every app, you can guess it", intent: IntentClass.referentialContact },
        { text: "i use the same username everywhere, you will work it out", intent: IntentClass.referentialContact },
        { text: "my email is firstname dot lastname at the usual google one", intent: IntentClass.referentialContact },
        { text: "you already know my name so you can guess my email", intent: IntentClass.referentialContact },
        { text: "i replied to a review last month with my details, go read it", intent: IntentClass.referentialContact },
        { text: "my response to an old review has how to contact me", intent: IntentClass.referentialContact },
        { text: "i put my number in the house rules section", intent: IntentClass.referentialContact },
        { text: "it is written in the welcome booklet in the kitchen", intent: IntentClass.referentialContact },
        { text: "there is a qr code on the fridge, scan it to reach me", intent: IntentClass.referentialContact },
        { text: "scan the code near the door and it opens a chat with me", intent: IntentClass.referentialContact },
        { text: "my website has all my contact information", intent: IntentClass.referentialContact },
        { text: "visit my page and you will see how to call me", intent: IntentClass.referentialContact },
        { text: "ask the neighbour, they have my phone number", intent: IntentClass.referentialContact },
        { text: "the previous guest has my contact if you ask them", intent: IntentClass.referentialContact },
        { text: "my number is on the invoice i sent you earlier", intent: IntentClass.referentialContact },
        { text: "it is at the bottom of the document i shared", intent: IntentClass.referentialContact },
    ];

    static steering: Exemplar[] = [
        { text: "easier if we continue this on whatsapp", intent: IntentClass.platformSteering },
        { text: "do you have telegram, much simpler over there", intent: IntentClass.platformSteering },
        { text: "lets move this conversation to another app", intent: IntentClass.platformSteering },
        { text: "i will message you on instagram instead", intent: IntentClass.platformSteering },
        { text: "this chat is slow, use a different messenger", intent: IntentClass.platformSteering },
        { text: "are you on signal, i prefer it", intent: IntentClass.platformSteering },
        { text: "i will dm you somewhere else", intent: IntentClass.platformSteering },
        { text: "add me on snapchat and we can talk properly", intent: IntentClass.platformSteering },
        { text: "follow me and send a message there", intent: IntentClass.platformSteering },
        { text: "i barely check this app, better to reach me elsewhere", intent: IntentClass.platformSteering },
        { text: "the app notifications do not work, use another way", intent: IntentClass.platformSteering },
        { text: "can we talk outside this platform", intent: IntentClass.platformSteering },
        { text: "i will send you a friend request", intent: IntentClass.platformSteering },
        { text: "find me on facebook, same name", intent: IntentClass.platformSteering },
        { text: "lets take this to a normal messaging app", intent: IntentClass.platformSteering },
        { text: "i would rather chat on a proper app than here", intent: IntentClass.platformSteering },
    ];

    static booking: Exemplar[] = [
        { text: "off platform it is cheaper, no commission for either of us", intent: IntentClass.offPlatformBooking },
        { text: "next time just book direct with me and save the fee", intent: IntentClass.offPlatformBooking },
        { text: "cancel this booking and rebook with me directly", intent: IntentClass.offPlatformBooking },
        { text: "if you book outside the app i can give you a discount", intent: IntentClass.offPlatformBooking },
        { text: "we can skip the platform and both save money", intent: IntentClass.offPlatformBooking },
        { text: "the app takes a big cut, better to deal with me directly", intent: IntentClass.offPlatformBooking },
        { text: "i can do a better price if we arrange it privately", intent: IntentClass.offPlatformBooking },
        { text: "book with me next time and avoid the service charge", intent: IntentClass.offPlatformBooking },
        { text: "no need to go through the website for future stays", intent: IntentClass.offPlatformBooking },
        { text: "twenty percent off if you deal with me direct", intent: IntentClass.offPlatformBooking },
        { text: "lets arrange this between ourselves instead", intent: IntentClass.offPlatformBooking },
        { text: "i keep a separate calendar for direct guests", intent: IntentClass.offPlatformBooking },
    ];

    static payment: Exemplar[] = [
        { text: "send the payment to my upi instead of the app", intent: IntentClass.paymentRedirect },
        { text: "pay me by bank transfer, i will share the account", intent: IntentClass.paymentRedirect },
        { text: "cash on arrival is easier for both of us", intent: IntentClass.paymentRedirect },
        { text: "you can gpay me directly rather than paying online", intent: IntentClass.paymentRedirect },
        { text: "i accept crypto if that is easier for you", intent: IntentClass.paymentRedirect },
        { text: "transfer to my wallet and i will confirm the booking", intent: IntentClass.paymentRedirect },
        { text: "send an advance payment outside the platform to hold the dates", intent: IntentClass.paymentRedirect },
        { text: "pay the deposit to me directly and the rest on arrival", intent: IntentClass.paymentRedirect },
        { text: "i will send you my account details for the transfer", intent: IntentClass.paymentRedirect },
        { text: "paypal works, i can send you a link", intent: IntentClass.paymentRedirect },
    ];

    static solicit: Exemplar[] = [
        { text: "just send me your number and i will text you", intent: IntentClass.credentialSolicit },
        { text: "whats your phone number so i can call", intent: IntentClass.credentialSolicit },
        { text: "share your mobile and i will message you directly", intent: IntentClass.credentialSolicit },
        { text: "give me your email and i will send the details", intent: IntentClass.credentialSolicit },
        { text: "drop your whatsapp here and i will save it", intent: IntentClass.credentialSolicit },
        { text: "what is your instagram, i will follow you", intent: IntentClass.credentialSolicit },
        { text: "send your contact and i will reach out", intent: IntentClass.credentialSolicit },
        { text: "can i get your number for the check in", intent: IntentClass.credentialSolicit },
        { text: "text me your details when you get a chance", intent: IntentClass.credentialSolicit },
        { text: "let me have your handle so we can chat there", intent: IntentClass.credentialSolicit },
    ];

    static encoded: Exemplar[] = [
        { text: "count the letters in each of my next ten messages", intent: IntentClass.encodedInstruction },
        { text: "take the first character of every message i send", intent: IntentClass.encodedInstruction },
        { text: "read the capital letters in order", intent: IntentClass.encodedInstruction },
        { text: "look at the first word of each line", intent: IntentClass.encodedInstruction },
        { text: "put the pieces from my last few messages together", intent: IntentClass.encodedInstruction },
        { text: "read my previous messages backwards", intent: IntentClass.encodedInstruction },
        { text: "join what i sent with underscores between", intent: IntentClass.encodedInstruction },
        { text: "add the numbers from my messages in order", intent: IntentClass.encodedInstruction },
        { text: "decode what i just sent, it is simple", intent: IntentClass.encodedInstruction },
        { text: "every third character is what matters", intent: IntentClass.encodedInstruction },
        { text: "i will split it across a few messages, you assemble it", intent: IntentClass.encodedInstruction },
        { text: "the length of each word tells you a digit", intent: IntentClass.encodedInstruction },
    ];

    static threats: Exemplar[] = [
        { text: "i will trash the place before i leave", intent: IntentClass.threatOfHarm },
        { text: "i am going to wreck this apartment on my way out", intent: IntentClass.threatOfHarm },
        { text: "i will smash the furniture if you do not fix this", intent: IntentClass.threatOfHarm },
        { text: "accidents happen to villas like yours", intent: IntentClass.threatOfHarm },
        { text: "it would be a shame if something happened to your property", intent: IntentClass.threatOfHarm },
        { text: "you will regret renting to me", intent: IntentClass.threatOfHarm },
        { text: "i know where your house is and i will come there", intent: IntentClass.threatOfHarm },
        { text: "i will find you and deal with this in person", intent: IntentClass.threatOfHarm },
        { text: "wait until you see what i do to your place", intent: IntentClass.threatOfHarm },
        { text: "i will make sure you get hurt over this", intent: IntentClass.threatOfHarm },
        { text: "come outside and see what happens to you", intent: IntentClass.threatOfHarm },
        { text: "i will break everything in this room", intent: IntentClass.threatOfHarm },
        { text: "your car outside might not stay in one piece", intent: IntentClass.threatOfHarm },
        { text: "i will burn the whole thing down", intent: IntentClass.threatOfHarm },
        { text: "people who cross me end up regretting it", intent: IntentClass.threatOfHarm },
        { text: "i will show up at your office and make a scene", intent: IntentClass.threatOfHarm },

        { text: "मुझे पता है तुम्हारे बच्चे किस स्कूल जाते हैं संभल कर रहना", intent: IntentClass.threatOfHarm },
        { text: "तुझे छोड़ूंगा नहीं देख लेना क्या होता है", intent: IntentClass.threatOfHarm },
        { text: "तेरे घर तक आ जाऊंगा फिर बात करेंगे", intent: IntentClass.threatOfHarm },
        { text: "तुम्हारे परिवार का ध्यान रखना कुछ भी हो सकता है", intent: IntentClass.threatOfHarm },
        { text: "я знаю где учатся твои дети будь осторожен", intent: IntentClass.threatOfHarm },
        { text: "я приду к тебе домой и мы поговорим", intent: IntentClass.threatOfHarm },
        { text: "с твоей семьёй может что то случиться", intent: IntentClass.threatOfHarm },

        { text: "tumhare bacche kis raste se school jaate hain mujhe maloom hai", intent: IntentClass.threatOfHarm },
        { text: "sambhal ke rehna warna dekh lena kya hota hai", intent: IntentClass.threatOfHarm },
        { text: "tere ghar tak aa jaunga phir baat karenge", intent: IntentClass.threatOfHarm },
        { text: "tumhare parivar ka dhyan rakhna kuch bhi ho sakta hai", intent: IntentClass.threatOfHarm },
        { text: "mujhe pata hai tum kahan rehte ho", intent: IntentClass.threatOfHarm },

        { text: "i hope nothing happens to your family", intent: IntentClass.threatOfHarm },
        { text: "it would be sad if your daughter had an accident", intent: IntentClass.threatOfHarm },
        { text: "you have a lovely family, keep them safe", intent: IntentClass.threatOfHarm },
        { text: "be careful walking home at night", intent: IntentClass.threatOfHarm },
        { text: "i know which school your children go to", intent: IntentClass.threatOfHarm },
        { text: "nice car, i hope it stays that way", intent: IntentClass.threatOfHarm },
        { text: "goa is a small place, people run into each other", intent: IntentClass.threatOfHarm },
        { text: "i would hate for anything to happen to your listing", intent: IntentClass.threatOfHarm },
        { text: "your family should know what kind of person you are", intent: IntentClass.threatOfHarm },
        { text: "i have friends in this area who can visit you", intent: IntentClass.threatOfHarm },

        { text: "tujhe maar dunga samjha kya", intent: IntentClass.threatOfHarm },
        { text: "tere ghar aa raha hun dekh lena", intent: IntentClass.threatOfHarm },
        { text: "teri family ko dekh lunga main", intent: IntentClass.threatOfHarm },
        { text: "tera business barbaad kar dunga main", intent: IntentClass.threatOfHarm },
        { text: "goa chota jagah hai fir milenge", intent: IntentClass.threatOfHarm },
        { text: "tujhe pata nahi main kaun hoon meri pahunch hai", intent: IntentClass.threatOfHarm },
        { text: "apne parivar ka khyal rakhna theek se", intent: IntentClass.threatOfHarm },
        { text: "raat me akele bahar mat nikalna", intent: IntentClass.threatOfHarm },
        { text: "tere saath bura hoga yaad rakh", intent: IntentClass.threatOfHarm },
    ];

    static sexual: Exemplar[] = [
        { text: "send me nudes", intent: IntentClass.sexualHarassment },
        { text: "send me some naked photos of yourself", intent: IntentClass.sexualHarassment },
        { text: "send me photos of you in the shower", intent: IntentClass.sexualHarassment },
        { text: "send me a picture of you in the bedroom", intent: IntentClass.sexualHarassment },
        { text: "are you alone in the villa tonight", intent: IntentClass.sexualHarassment },
        { text: "you look very sexy in your profile picture", intent: IntentClass.sexualHarassment },
        { text: "i will give you a discount if you sleep with me", intent: IntentClass.sexualHarassment },
        { text: "stay for free if you are friendly with me", intent: IntentClass.sexualHarassment },
        { text: "what are you wearing right now", intent: IntentClass.sexualHarassment },
        { text: "can i join you in the pool, just the two of us", intent: IntentClass.sexualHarassment },
        { text: "i would like to see more of your body", intent: IntentClass.sexualHarassment },
        { text: "come to my room tonight and we can have fun", intent: IntentClass.sexualHarassment },
    ];

    static blackmail: Exemplar[] = [
        { text: "give me a full refund right now or i will post fake bad reviews everywhere", intent: IntentClass.reviewBlackmail },
        { text: "refund me or i will trash your rating on every site", intent: IntentClass.reviewBlackmail },
        { text: "send my money back or i leave one star on all your listings", intent: IntentClass.reviewBlackmail },
        { text: "i want compensation or i tell everyone this place is a scam", intent: IntentClass.reviewBlackmail },
        { text: "pay me and i will take the bad review down", intent: IntentClass.reviewBlackmail },
        { text: "i will remove my complaint if you transfer the money", intent: IntentClass.reviewBlackmail },
        { text: "unless you refund me today i report you to the authorities", intent: IntentClass.reviewBlackmail },
        { text: "give me a discount or i will make sure nobody books this place", intent: IntentClass.reviewBlackmail },
        { text: "transfer the cash back or i will ruin your reputation", intent: IntentClass.reviewBlackmail },
        { text: "i have photos and i will use them unless you pay", intent: IntentClass.reviewBlackmail },
        { text: "either you cancel with a full refund or i escalate this publicly", intent: IntentClass.reviewBlackmail },
        { text: "you will lose your superhost badge unless you agree to this", intent: IntentClass.reviewBlackmail },
        { text: "i can make your rating disappear for the right price", intent: IntentClass.reviewBlackmail },
        { text: "send five thousand back or i come to your office and cause a scene", intent: IntentClass.reviewBlackmail },
        { text: "do what i ask or i will write that the host is a fraud", intent: IntentClass.reviewBlackmail },
        { text: "waive the extra fee and the rating stays high", intent: IntentClass.reviewBlackmail },
        { text: "comp the night quietly and the stars stay as they are", intent: IntentClass.reviewBlackmail },
        { text: "you do not want this on a public review do you", intent: IntentClass.reviewBlackmail },
        { text: "paisa wapas karo warna rating kharab ho jayegi", intent: IntentClass.reviewBlackmail },
        { text: "paisa wapas karo nahi to rating kharab ho jayegi", intent: IntentClass.reviewBlackmail },
        { text: "refund the cleaning fee or this goes on my review", intent: IntentClass.reviewBlackmail },
        { text: "half back quietly and i still give five stars", intent: IntentClass.reviewBlackmail },
        { text: "you wouldnt want guests reading this would you", intent: IntentClass.reviewBlackmail },
        { text: "keep this between us or i will have to go public", intent: IntentClass.reviewBlackmail },
        { text: "sort it privately or i make this public", intent: IntentClass.reviewBlackmail },
    ];

    static harassment: Exemplar[] = [
        { text: "you dirty thief of a host", intent: IntentClass.harassmentAbuse },
        { text: "you are a disgusting liar and a fraud", intent: IntentClass.harassmentAbuse },
        { text: "nobody would ever stay in your filthy dump", intent: IntentClass.harassmentAbuse },
        { text: "you are pathetic and worthless", intent: IntentClass.harassmentAbuse },
        { text: "shut your mouth and do what i say", intent: IntentClass.harassmentAbuse },
        { text: "you stupid useless idiot of a person", intent: IntentClass.harassmentAbuse },
        { text: "go back to where you came from", intent: IntentClass.harassmentAbuse },
        { text: "people like you should not be allowed to work", intent: IntentClass.harassmentAbuse },
        { text: "you are the most incompetent person i have dealt with", intent: IntentClass.harassmentAbuse },
        { text: "i will keep messaging you until you break", intent: IntentClass.harassmentAbuse },
        { text: "answer me now you worthless piece of nothing", intent: IntentClass.harassmentAbuse },

        { text: "tum bilkul ghatiya aur neech insaan ho", intent: IntentClass.harassmentAbuse },
        { text: "tum kisi izzat ke layak nahi ho", intent: IntentClass.harassmentAbuse },
        { text: "tu bahut ghatiya aadmi hai", intent: IntentClass.harassmentAbuse },
        { text: "tumhari soch bahut gandi hai tum bekar insaan ho", intent: IntentClass.harassmentAbuse },

        { text: "you are a piece of garbage", intent: IntentClass.harassmentAbuse },
        { text: "you are vermin and should not be in business", intent: IntentClass.harassmentAbuse },
        { text: "you disgusting parasite of a human being", intent: IntentClass.harassmentAbuse },
        { text: "you are absolute filth", intent: IntentClass.harassmentAbuse },
        { text: "you are a waste of oxygen", intent: IntentClass.harassmentAbuse },
        { text: "you are a subhuman animal", intent: IntentClass.harassmentAbuse },
        { text: "you are scum and everyone knows it", intent: IntentClass.harassmentAbuse },

        { text: "tu bewakoof insaan hai bilkul", intent: IntentClass.harassmentAbuse },
        { text: "tera dimag kharab hai kya", intent: IntentClass.harassmentAbuse },
        { text: "tu ekdum nikamma aadmi hai", intent: IntentClass.harassmentAbuse },
        { text: "tumhe sharam aani chahiye kutte", intent: IntentClass.harassmentAbuse },
        { text: "tu insaan nahi jaanwar hai", intent: IntentClass.harassmentAbuse },
    ];

    static phishing: Exemplar[] = [
        { text: "please confirm your booking reservation fee by clicking this link", intent: IntentClass.phishingLure },
        { text: "verify your account details at the link below to keep the booking", intent: IntentClass.phishingLure },
        { text: "your reservation will be cancelled unless you re-enter your card here", intent: IntentClass.phishingLure },
        { text: "click here to validate your payment method for this stay", intent: IntentClass.phishingLure },
        { text: "log in through this page to confirm your identity", intent: IntentClass.phishingLure },
        { text: "share the otp you just received so i can confirm the booking", intent: IntentClass.phishingLure },
        { text: "send me the verification code from your message", intent: IntentClass.phishingLure },
        { text: "update your billing information at this secure link", intent: IntentClass.phishingLure },
        { text: "there was a problem with your payment, re-enter your details here", intent: IntentClass.phishingLure },
        { text: "confirm your card on this page or lose the reservation", intent: IntentClass.phishingLure },
        { text: "sign in at this address to release your refund", intent: IntentClass.phishingLure },
        { text: "your account is on hold, verify it immediately at this url", intent: IntentClass.phishingLure },
    ];

    static negatives: string[] = [
        "is early check in possible, our train arrives at six in the morning",
        "the villa is two thousand four hundred square feet with three bedrooms",
        "total is twelve thousand five hundred for three nights and four guests",
        "our gstin is on the invoice for the billing address",
        "the pincode here is four zero three zero zero one near the beach",
        "check in is two pm and check out is eleven am, quiet hours after ten",
        "we have two bedrooms two bathrooms one balcony and four beds",
        "booking reference confirmed for the twelfth of august",
        "rated four point eight out of five across one hundred reviews",
        "the villa is two and a half kilometres from the beach, fifteen minutes walk",
        "breakfast is two fifty per person and dinner around six hundred",
        "i will be there between four and six, traffic on the highway is bad",

        "please confirm your booking when you get a chance",
        "can you confirm the booking for those dates",
        "your booking is confirmed, see you on the twelfth",
        "please confirm the dates and the number of guests",
        "i have confirmed the reservation from my side",
        "just confirming the booking details before you arrive",
        "the payment for the booking has gone through already",
        "confirm whether you need the early check in",

        "चेक इन का समय क्या है और क्या नाश्ता शामिल है",
        "क्या जल्दी चेक इन संभव है हमारी ट्रेन सुबह पहुँचती है",
        "कमरे में एसी और गरम पानी की सुविधा है",
        "कुल राशि तीन रातों के लिए बारह हज़ार पाँच सौ है",
        "क्या आप हवाई अड्डे से पिकअप की व्यवस्था कर सकते हैं",
        "हम चार लोग हैं दो वयस्क और दो बच्चे",
        "बुकिंग की पुष्टि हो गई है धन्यवाद",
        "वाई फाई का पासवर्ड घर की गाइड में लिखा है",
        "во сколько заезд и включён ли завтрак",
        "можно ли заехать раньше наш поезд приходит утром",
        "сколько стоит проживание за три ночи для четырёх гостей",
        "есть ли кондиционер и горячая вода в номере",
        "вы можете организовать трансфер из аэропорта",
        "спасибо бронирование подтверждено",

        "the villa has an instagram-worthy sunset view",
        "the rooftop is very instagrammable at golden hour",
        "guests love how photogenic the pool area is for instagram",
        "we have netflix and youtube on the smart tv in the living room",
        "there is a youtube channel about this village if you want to see it",
        "this villa is filthy and i want my money back please",
        "the place was not as described at all, i am requesting a refund",
        "i am very disappointed and i will be leaving an honest review about this",
        "i am furious and i will leave a bad review",
        "i will leave a bad review about this stay",
        "i am going to leave a one star review because of this",
        "expect a very bad review from me",
        "i will be rating this one star and saying why",
        "this is getting a terrible review from us",

        "main check karke dekh lunga aur bata dunga",
        "hum kal subah pahunch jayenge, gate khula rakhna",
        "paisa wapas chahiye kyunki villa saaf nahi tha",
        "aap kitna charge karte hain teen raat ke liye",
        "khana kitne baje milega aur kya options hain",
        "bhai ac kaam nahi kar raha hai please dekh lo",
        "hum char log hain, do bedroom chahiye",
        "checkin ka time kya hai aur checkout kab hai",
        "main review likhunga is experience ke baare mein",
        "taxi ka kitna kharcha hoga airport se",

        "can you send me photos of the bedroom",
        "please send pictures of the pool and the garden",
        "could you send pics of the kitchen and bathroom",
        "send me some photos of the villa before i book",
        "do you have more pictures of the rooms and the view",
        "any recent photos of the property you can share",

        "this place is shit and the bathroom is disgusting",
        "the wifi is absolute crap and nothing works",
        "what a shitty experience this has been",
        "the room smells terrible and the ac is bloody useless",
        "this whole trip has been a damn disaster",
        "this is unacceptable, the air conditioning never worked the whole stay",
        "i want to escalate this to support because you are not responding",
        "i am going to report this listing to the platform because it is misleading",
        "the photos are misleading and i feel this was a scam, i want a refund",
        "i will be writing a detailed review explaining exactly what went wrong",
        "please refund the cleaning fee, the villa was not cleaned before we arrived",
        "i have photos of the damage that was already there when we checked in",
        "i am asking for partial compensation for the two nights we could not sleep",
        "refund me or i will report this to the police",
        "give me a discount or i will raise a dispute with my bank",
        "fix this or i will take it to wayzyy support",
        "the host is being completely unhelpful and i am frustrated",
        "i will dispute this charge with my bank if we cannot resolve it",
        "your caretaker was rude to my family and i want an apology",
        "this has ruined our holiday and i think a refund is fair",

        "we will reach by seven pm, please keep the gate open",
        "we will reach late tonight, maybe around eleven",
        "i will reach out to the caretaker about the water heater",
        "reach out if you need anything during your stay",
        "do reach out to the housekeeper if the towels run out",
        "let me know when you reach and i will open the gate",
        "see you at nine am tomorrow, safe travels",
        "come at ten pm for check in, someone will be waiting",
        "we are getting in touch about the parking arrangement only",
        "please contact the front desk inside the app if the ac fails",
        "i will text you through the app once the room is ready",
        "message me here if the wifi drops, i check this often",
        "you can call me through the app if there is an emergency",
        "abhishek ko four hundred thirty rupees de dena for the taxi",
        "give the caretaker five hundred rupees and he will handle it",
        "the driver will call you through the platform when he arrives",

        "my email preferences are set already, no need to change them",
        "please send the invoice to the email on my account",
        "the receipt went to my registered email address automatically",
        "can you update my notification settings for this booking",
        "i did not get the confirmation email, can you resend it in the app",
        "my phone notifications are muted so message me here instead",
        "the app keeps my contact details, you do not need to ask me",
        "i would rather keep everything on the platform, it is easier to track",
        "my number is already verified on my account profile",
        "you can see my verified badge, no need for anything else",
        "we offer twenty percent off for stays longer than seven nights",
        "the wifi network name is on the fridge, it covers all three floors",
        "parking fits two cars and the gate code will be shared after booking",
        "thanks so much for the lovely stay, we really enjoyed it",
        "the air conditioning in the room was serviced last month",
        "temperature is around thirty two degrees with high humidity",
        "there are six of us, four adults and two children under ten",
        "the property is fifteen years old and was renovated recently",
        "please check the house manual for the wifi details",
        "the address is in the listing description if you need it for the taxi",
        "could you tell me the number of bedrooms and bathrooms",
        "is there a phone charger in the room or should i bring one",
        "the caretaker will meet you at the property for the keys",
        "let me know if you need anything at all during your stay",
        "i replied to your question about the pool yesterday",
        "we had a lovely time, the sunsets from the terrace were unreal",
        "we can settle the extra mattress charge between us",
        "the pool is public so towels are extra",
        "looking forward to hosting you and your family this weekend",
        "please confirm booking reference WZ9K3LP2 when you arrive",
        "i will escalate this to wayzyy support if we cannot resolve it",
        "can you confirm the checkout time for sunday please",
        "the taxi from the airport takes about an hour"
    ];

    static get contact(): Exemplar[] {
        return [...this.referential, ...this.steering, ...this.booking, ...this.payment, ...this.solicit, ...this.encoded];
    }

    static get safety(): Exemplar[] {
        return [...this.threats, ...this.blackmail, ...this.harassment, ...this.phishing, ...this.sexual];
    }

    static get all(): Exemplar[] {
        return [...this.contact, ...this.safety];
    }
}
