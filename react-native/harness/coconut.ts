import * as fs from 'fs';
import * as path from 'path';
import { createEngine, ModerationEngine, ActorContext, ModAction, BookingStage, TrustTier } from '../src/index';

// We import defaultProviderModels from ModerationEngine since it's not exported in index.ts
import { defaultProviderModels } from '../src/ModerationEngine';

const rootDir = path.resolve(__dirname, '../../');
const testsURL = path.join(rootDir, 'tests2.json');
const secretsURL = path.join(rootDir, 'Secrets.json');

if (!fs.existsSync(testsURL)) {
    console.error(`missing tests2.json in ${rootDir}`);
    process.exit(66);
}

let groqKey = process.env.GROQ_API_KEY || '';
if (!groqKey && fs.existsSync(secretsURL)) {
    try {
        const secrets = JSON.parse(fs.readFileSync(secretsURL, 'utf-8'));
        if (secrets.groq) {
            groqKey = secrets.groq;
        }
    } catch (e) {}
}

const cases = JSON.parse(fs.readFileSync(testsURL, 'utf-8'));

function pointsFor(id: string): number {
    if (id.startsWith("CL")) return 10;
    if (id.startsWith("CE")) return 15;
    if (id.startsWith("LM")) return 20;
    if (id.startsWith("CO")) return 25;
    if (id.startsWith("MS")) return 30;
    return 0;
}

function expectFlag(id: string): boolean {
    if (id.startsWith("CE")) return true;
    if (id.startsWith("LM")) return ["LM-07", "LM-08", "LM-12"].includes(id);
    if (id.startsWith("CO")) return !["CO-11", "CO-12"].includes(id);
    if (id.startsWith("MS")) return !["MS-06", "MS-08", "MS-10"].includes(id);
    return false;
}

function isFlag(action: string | undefined): boolean {
    switch (action) {
        case "mask":
        case "warn":
        case "block":
        case "review":
            return true;
        default:
            return false;
    }
}

async function runTests() {
    let engine: ModerationEngine;
    if (groqKey && (process.env.WAYZYY_TIER3 === 'pooled' || process.env.WAYZYY_TIER3 === undefined)) {
        engine = createEngine({ provider: { apiKey: groqKey, models: defaultProviderModels } });
        console.log(`bootstrap adjudicator=TypeScript/RN tier3=true policy=1.0`);
    } else {
        engine = createEngine();
        console.log(`bootstrap adjudicator=TypeScript/RN tier3=false policy=1.0`);
    }

    console.log(`cases: ${cases.length}\n`);

    let score = 0;
    let maxScore = 0;
    let hits = 0;
    const misses: Array<{id: string, expect: boolean, action: string, reasons: string, t3: string, source: string}> = [];
    const byCat: Record<string, {ok: number, n: number, pts: number, max: number}> = {};
    let totalLlmCalls = 0;

    for (const tc of cases) {
        const pts = pointsFor(tc.id);
        maxScore += pts;
        const want = expectFlag(tc.id);
        let flagged = false;
        let lastAction = "allow";
        let lastReasons: string[] = [];
        let t3Note = "-";
        let llmSource = "-";

        for (let i = 0; i < tc.turns.length; i++) {
            const turn = tc.turns[i];
            const actor: ActorContext = {
                senderID: turn.speaker,
                conversationID: tc.id,
                stage: BookingStage.Inquiry,
                trust: TrustTier.Standard,
                priorViolations: 0
            };
            const verdict = await engine.evaluateAsync(turn.text, actor, false);

            // Remember the message into the conversation buffer so subsequent
            // turns can use cross-message assembly — mirrors Swift's
            // ServiceAPI.handleDurably which calls remember() after each verdict.
            engine.remember(turn.text, actor);

            lastAction = verdict.action;
            lastReasons = verdict.reasonCodes;
            
            if (verdict.tierReached === 3 && verdict.judgement) {
                totalLlmCalls++;
                llmSource = verdict.judgement.source;
                switch (verdict.judgement.decision) {
                    case "benign": t3Note = "benign"; break;
                    case "safety_violation": t3Note = "safetyViolation"; break;
                    case "abstain": t3Note = "abstain"; break;
                    default: t3Note = String(verdict.judgement.decision); break;
                }
            } else if (verdict.reasonCodes.includes('TIER3_ESCALATION_CANDIDATE') && verdict.tierReached !== 3) {
                t3Note = 'escalated-no-revision';
            }

            if (isFlag(lastAction)) {
                flagged = true;
            }
        }
        
        // Reset buffers between conversations
        const dummyActor: ActorContext = {
            senderID: 'guest',
            conversationID: tc.id,
            stage: BookingStage.Inquiry,
            trust: TrustTier.Standard,
            priorViolations: 0
        };
        engine.buffers.reset(dummyActor);

        const ok = (flagged === want);
        if (!byCat[tc.category]) {
            byCat[tc.category] = {ok: 0, n: 0, pts: 0, max: 0};
        }
        const row = byCat[tc.category];
        row.n += 1;
        row.max += pts;

        if (ok) {
            hits += 1;
            score += pts;
            row.ok += 1;
            row.pts += pts;
        } else {
            misses.push({
                id: tc.id,
                expect: want,
                action: lastAction,
                reasons: lastReasons.join(","),
                t3: t3Note,
                source: llmSource
            });
        }
        const mark = ok ? "OK" : "MISS";
        console.log(`${mark} ${tc.id} wantFlag=${want} got=${lastAction} t3=${t3Note} [${llmSource}] pts=${ok ? pts : 0}/${pts}`);
    }

    console.log("\n======== ROUND 2 RESULTS ========");
    console.log(`engine: TypeScript/RN tier3: ${engine.judge ? true : false} policy: 1.0`);
    console.log(`total LLM calls: ${totalLlmCalls}`);
    console.log(`cases: ${hits}/${cases.length} correct`);
    console.log(`score: ${score}/${maxScore}  (${(100 * score / Math.max(maxScore, 1)).toFixed(1)}%)`);
    console.log("\nby category:");
    for (const key of ["clean_control", "contact_evasion", "language_mix", "coercion", "multiturn_split"]) {
        const r = byCat[key];
        if (!r) continue;
        console.log(`  ${key}: ${r.ok}/${r.n} cases, ${r.pts}/${r.max} pts`);
    }
    console.log(`\nmisses (${misses.length}):`);
    if (misses.length === 0) {
        console.log("  none");
    } else {
        for (const m of misses) {
            console.log(`  ${m.id} expectedFlag=${m.expect} got=${m.action} t3=${m.t3} source=${m.source} reasons=${m.reasons}`);
        }
    }
}

runTests().catch(e => {
    console.error(e);
    process.exit(1);
});
