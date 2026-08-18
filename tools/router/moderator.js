/**
 * Wayzyy on-device HINTS only. Enforcement is the HTTP service.
 *
 * This must never withhold a message. A patched client skips it, and substring
 * matching here used to block "chutney". The server token-matches and masks.
 *
 *   allow  — nothing to hint
 *   hint   — underline / toast; still send through POST /v1/moderate
 */

// ── FNV-1a hash (must match train.py and AbuseRouter.swift)
const encoder = typeof TextEncoder !== 'undefined'
  ? new TextEncoder()
  : new (require('util').TextEncoder)();

function fnv1a(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h;
}

function features(text, ngrams, buckets) {
  const padded = ' ' + text.toLowerCase().replace(/\s+/g, ' ').trim() + ' ';
  const codePoints = [...padded];
  const counts = new Map();
  for (const n of ngrams) {
    for (let i = 0; i <= codePoints.length - n; i++) {
      const gram = codePoints.slice(i, i + n).join('');
      const key = fnv1a(encoder.encode(gram)) % buckets;
      counts.set(key, (counts.get(key) || 0) + 1);
    }
  }
  return counts;
}

function routerScore(model, text) {
  const f = features(text, model.ngrams, model.buckets);
  let norm = 0;
  for (const v of f.values()) norm += v * v;
  norm = Math.sqrt(norm) || 1;
  let z = model.bias;
  for (const [k, v] of f) z += model.weights[k] * (v / norm);
  z = Math.max(-30, Math.min(30, z));
  return 1 / (1 + Math.exp(-z));
}

function parseWeights(content) {
  let buckets = 0, ngrams = [], bias = 0, threshold = 0.08, weights = null;
  for (const line of content.split('\n')) {
    const p = line.trim().split(' ');
    if (!p[0]) continue;
    if (p[0] === 'buckets') { buckets = parseInt(p[1]); weights = new Float32Array(buckets); }
    else if (p[0] === 'ngrams') ngrams = p[1].split(',').map(Number);
    else if (p[0] === 'bias') bias = parseFloat(p[1]);
    else if (p[0] === 'threshold') threshold = parseFloat(p[1]);
    else if (p.length === 2 && /^\d+$/.test(p[0]) && weights)
      weights[parseInt(p[0])] = parseFloat(p[1]);
  }
  return { weights, buckets, ngrams, bias, threshold };
}

// ── Number word canonicaliser
// Handles mixed word+digit ("786fivefour three 21") and pure word runs.
const NUM_MAP = {
  // English
  zero:0, one:1, two:2, three:3, four:4, five:5, six:6, seven:7, eight:8, nine:9,
  // Hindi / Hinglish
  shunya:0, ek:1, do:2, teen:3, tin:3, chaar:4, char:4, paanch:5, panch:5,
  chhe:6, che:6, saat:7, sat:7, aath:8, ath:8, nau:9, nav:9,
};

const _NUM_WORDS_RE = new RegExp(`(${Object.keys(NUM_MAP).join('|')})(?=${Object.keys(NUM_MAP).join('|')})`, 'gi');

// Split "786fivefour" → "786 five four" so each word is independently mappable
function splitGlued(text) {
  text = text.replace(/(\d+)([a-z]+)/gi, '$1 $2');
  text = text.replace(/([a-z]+)(\d+)/gi, '$1 $2');
  // "fivefour" → "five four" — glued number words with no boundary
  let prev;
  do { prev = text; text = text.replace(_NUM_WORDS_RE, '$1 '); } while (text !== prev);
  return text;
}

function canonicaliseToDigits(text) {
  const split = splitGlued(text.toLowerCase());
  const tokens = split.split(/[\s]+/);
  return tokens.map(t => {
    const n = NUM_MAP[t];
    return n !== undefined ? String(n) : t;
  }).join('');
}

// ── Contact detection
const PLATFORM_RE = /\b(whatsapp|whatsap|watsapp|wp|telegram|tg|insta|instagram|snap|snapchat|signal|viber|wechat|skype|messenger|imessage)\b/i;
const SHORTENER_RE = /\bbit\.ly|t\.me|wa\.me|tinyurl|goo\.gl\b/i;
const EMAIL_RE = /[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}/i;
const URL_RE = /(?:https?:\/\/|www\.)\S+/i;

function checkContact(text) {
  // 1. Direct digit phone (10 digits, or Indian mobile 6-9 prefix)
  if (/\b\d{10}\b/.test(text)) return 'phone:digits';
  if (/\b[6-9]\d{4}[\s\-]?\d{5}\b/.test(text)) return 'phone:indian';

  // 2. Canonicalise mixed word+digit, then check for phone-length runs
  const canon = canonicaliseToDigits(text);
  const digitsOnly = canon.replace(/\D/g, '');
  if (digitsOnly.length >= 8 && /[6-9]\d{7,}/.test(digitsOnly)) return 'phone:mixed';

  // 3. Pure number word run (6+ words = 6+ digits = phone-ish)
  const words = text.toLowerCase().replace(/[^a-z\s]/g, ' ').split(/\s+/);
  let run = 0;
  for (const w of words) {
    if (NUM_MAP[w] !== undefined) { run++; } else { run = 0; }
    if (run >= 6) return 'phone:number_words';
  }

  // 4. Standard contact channels
  if (EMAIL_RE.test(text)) return 'email';
  if (URL_RE.test(text)) return 'url';
  if (SHORTENER_RE.test(text)) return 'shortener';
  if (PLATFORM_RE.test(text)) return 'platform';

  return null;
}

// ── Module state (loaded once at app start)
let slurSet = null;
let routerModel = null;

/**
 * Load the lexicon and router weights.
 * In React Native, use expo-asset or require() to get the file contents.
 *
 * @param {string} slursJSON    — contents of config/slurs.json
 * @param {string} weightsText  — contents of config/abuse-router.weights
 */
export function loadModerator(slursJSON, weightsText) {
  slurSet = new Set(JSON.parse(slursJSON));
  routerModel = parseWeights(weightsText);
}

/**
 * Advisory check. Never returns block. The send path must always hit the service.
 *
 * @returns {{ action: 'allow'|'hint', reason?: string, score?: number }}
 */
export function moderate(text) {
  if (!slurSet || !routerModel) {
    return { action: 'allow', reason: 'moderator_not_loaded' };
  }

  const tokens = text.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);

  for (const term of slurSet) {
    if (!term) continue;
    if (term.includes(' ')) {
      if (text.toLowerCase().includes(term)) {
        return { action: 'hint', reason: 'profanity' };
      }
    } else if (tokens.includes(term)) {
      return { action: 'hint', reason: 'profanity' };
    }
  }

  const contactHit = checkContact(text);
  if (contactHit) {
    return { action: 'hint', reason: 'contact', type: contactHit };
  }

  const score = routerScore(routerModel, text);
  if (score >= routerModel.threshold) {
    return { action: 'hint', score };
  }

  return { action: 'allow' };
}

// ── React Native usage example
//
// import { Asset } from 'expo-asset'
// import * as FileSystem from 'expo-file-system'
//
// export async function initModerator() {
//   const [slursAsset, weightsAsset] = await Asset.loadAsync([
//     require('../assets/slurs.json'),
//     require('../assets/abuse-router.weights'),
//   ])
//   const [slursJSON, weightsText] = await Promise.all([
//     FileSystem.readAsStringAsync(slursAsset.localUri),
//     FileSystem.readAsStringAsync(weightsAsset.localUri),
//   ])
//   loadModerator(slursJSON, weightsText)
// }
