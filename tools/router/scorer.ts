/**
 * Wayzyy abuse router — TypeScript port.
 *
 * Same algorithm as AbuseRouter.swift and tools/router/train.py.
 * FNV-1a hash over UTF-8 bytes, character n-grams, L2-normalised dot product.
 * Loads the same weights file the Swift service uses — one source of truth.
 *
 * Usage in React Native / Expo:
 *   import { loadRouter, routes } from './scorer';
 *   const router = await loadRouter();          // once, at app start
 *   if (routes(router, draftText)) showHint();  // on every keystroke
 *
 * This is a ROUTING SIGNAL only. It raises a flag so the server makes
 * the authoritative call. It must never be the enforcement point —
 * enforcement must go through the server because anything client-side
 * is bypassable by calling the send API directly.
 */

interface RouterModel {
  weights: Float32Array;
  buckets: number;
  ngrams: number[];
  bias: number;
  threshold: number;
}

// FNV-1a 32-bit. Must stay byte-identical to fnv1a() in train.py and AbuseRouter.swift.
function fnv1a(bytes: Uint8Array): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0; // unsigned 32-bit
}

const encoder = new TextEncoder();

function features(text: string, ngrams: number[], buckets: number): Map<number, number> {
  const padded = ' ' + text.toLowerCase().replace(/\s+/g, ' ').trim() + ' ';
  const counts = new Map<number, number>();
  // Slice by Unicode code points to match Python str slicing.
  const codePoints = [...padded]; // Array.from or spread handles surrogates correctly
  for (const n of ngrams) {
    for (let i = 0; i <= codePoints.length - n; i++) {
      const gram = codePoints.slice(i, i + n).join('');
      const bytes = encoder.encode(gram);
      const key = fnv1a(bytes) % buckets;
      counts.set(key, (counts.get(key) ?? 0) + 1);
    }
  }
  return counts;
}

export function score(model: RouterModel, text: string): number {
  const counts = features(text, model.ngrams, model.buckets);
  let norm = 0;
  for (const v of counts.values()) norm += v * v;
  norm = Math.sqrt(norm) || 1;

  let z = model.bias;
  for (const [k, v] of counts) {
    z += model.weights[k] * (v / norm);
  }
  z = Math.max(-30, Math.min(30, z));
  return 1 / (1 + Math.exp(-z));
}

/** Whether this text deserves a closer look. */
export function routes(model: RouterModel, text: string): boolean {
  return score(model, text) >= model.threshold;
}

/**
 * Load weights from a .weights file (the same file the Swift service uses).
 *
 * In React Native, bundle the file with expo-asset or load from the filesystem.
 * Pass the raw text content here.
 */
export function parseWeights(content: string): RouterModel {
  let buckets = 0;
  let ngrams: number[] = [];
  let bias = 0;
  let threshold = 0.5;
  let nonZero = 0;
  let declared = 0;
  let weights: Float32Array | null = null;

  for (const line of content.split('\n')) {
    const parts = line.trim().split(' ');
    if (!parts[0]) continue;
    switch (parts[0]) {
      case 'WAYZYY-NGRAM-1': break;
      case 'buckets':
        buckets = parseInt(parts[1]);
        weights = new Float32Array(buckets); // initialised to 0
        break;
      case 'ngrams':
        ngrams = parts[1].split(',').map(Number);
        break;
      case 'bias':
        bias = parseFloat(parts[1]);
        break;
      case 'threshold':
        threshold = parseFloat(parts[1]);
        break;
      case 'weights':
        declared = parseInt(parts[1]);
        break;
      default:
        if (parts.length === 2 && /^\d+$/.test(parts[0]) && weights) {
          weights[parseInt(parts[0])] = parseFloat(parts[1]);
          nonZero++;
        }
    }
  }

  if (!weights || buckets === 0 || ngrams.length === 0) {
    throw new Error('weights file missing required header fields');
  }
  if (declared > 0 && declared !== nonZero) {
    throw new Error(`weights file truncated: declared ${declared}, read ${nonZero}`);
  }

  return { weights, buckets, ngrams, bias, threshold };
}

/**
 * Convenience: load from a URL (works in React Native with expo-file-system or fetch).
 * For bundled assets, use require() + Asset.fromModule() instead.
 */
export async function loadRouter(url: string): Promise<RouterModel> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`failed to load weights: ${res.status}`);
  const text = await res.text();
  return parseWeights(text);
}
