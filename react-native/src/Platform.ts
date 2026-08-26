// Platform abstraction: the engine must run identically under Node (tests,
// Supabase Edge Functions) and React Native/Hermes (the Expo app). Nothing in
// the engine may import node builtins directly; everything goes through here.

declare const process: {
    env?: Record<string, string | undefined>;
    versions?: { node?: string };
};
declare const require: (id: string) => any;

export interface PlatformAdapter {
    /** Read a text file, or return null when unavailable (e.g. bundled app). */
    readTextFile(path: string): string | null;
    /** Environment lookup, or null when unavailable. */
    env(name: string): string | null;
}

class NodePlatform implements PlatformAdapter {
    private fs: any = null;
    private tried = false;

    private ensureFs(): any {
        if (this.tried) return this.fs;
        this.tried = true;
        try {
            if (typeof process !== 'undefined' && process.versions?.node) {
                this.fs = require('fs');
            }
        } catch {
            this.fs = null;
        }
        return this.fs;
    }

    readTextFile(path: string): string | null {
        const fs = this.ensureFs();
        if (!fs) return null;
        try {
            if (!fs.existsSync(path)) return null;
            return fs.readFileSync(path, 'utf8') as string;
        } catch {
            return null;
        }
    }

    env(name: string): string | null {
        try {
            if (typeof process !== 'undefined' && process.env && process.env[name]) {
                return process.env[name] as string;
            }
        } catch { /* not available */ }
        return null;
    }
}

let active: PlatformAdapter = new NodePlatform();

/** Apps (Expo/RN) inject an adapter backed by expo-asset / AsyncStorage here. */
export function setPlatformAdapter(adapter: PlatformAdapter): void {
    active = adapter;
}

export function platform(): PlatformAdapter {
    return active;
}

const encoder = typeof TextEncoder !== 'undefined' ? new TextEncoder() : null;

export function utf8Bytes(s: string): Uint8Array {
    if (encoder) return encoder.encode(s);
    // Minimal fallback for runtimes without TextEncoder
    const out: number[] = [];
    for (const cp of s) {
        let c = cp.codePointAt(0)!;
        if (c < 0x80) out.push(c);
        else if (c < 0x800) out.push(0xC0 | (c >> 6), 0x80 | (c & 63));
        else if (c < 0x10000) out.push(0xE0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
        else out.push(0xF0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return new Uint8Array(out);
}

/**
 * Decode UTF-8 bytes to a string without relying on Buffer (Hermes has none).
 * Invalid sequences become U+FFFD, mirroring Buffer.toString('utf8').
 */
export function bytesToUtf8(bytes: number[]): string {
    let out = "";
    let i = 0;
    while (i < bytes.length) {
        const b = bytes[i]!;
        let cp = -1;
        if (b < 0x80) {
            cp = b; i += 1;
        } else if ((b & 0xE0) === 0xC0 && i + 1 < bytes.length) {
            cp = ((b & 31) << 6) | (bytes[i + 1]! & 63); i += 2;
        } else if ((b & 0xF0) === 0xE0 && i + 2 < bytes.length) {
            cp = ((b & 15) << 12) | ((bytes[i + 1]! & 63) << 6) | (bytes[i + 2]! & 63); i += 3;
        } else if ((b & 0xF8) === 0xF0 && i + 3 < bytes.length) {
            cp = ((b & 7) << 18) | ((bytes[i + 1]! & 63) << 12) | ((bytes[i + 2]! & 63) << 6) | (bytes[i + 3]! & 63); i += 4;
        } else {
            cp = 0xFFFD; i += 1;
        }
        if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;
        out += String.fromCodePoint(cp);
    }
    return out;
}
