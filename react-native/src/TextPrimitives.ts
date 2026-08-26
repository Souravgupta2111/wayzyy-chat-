// Leaf text primitives: CharView, OffsetTable and RX. Deliberately imports
// nothing from the engine so that Canonicalizer, NumericContext and Extractors
// can all depend on this module without forming a cycle.

export class CharView {
    chars: string[];
    offsets: number[];
    transforms: string[];

    constructor(chars: string[], offsets: number[], transforms: string[] = []) {
        this.chars = chars;
        this.offsets = offsets;
        this.transforms = transforms;
    }

    static fromString(source: string): CharView {
        const chars = Array.from(source);
        const offsets = Array.from({ length: chars.length }, (_, i) => i);
        return new CharView(chars, offsets);
    }

    get text(): string {
        return this.chars.join('');
    }

    get isEmpty(): boolean {
        return this.chars.length === 0;
    }

    get count(): number {
        return this.chars.length;
    }

    originalRange(start: number, end: number): [number, number] | null {
        if (start < end && start >= 0 && end <= this.offsets.length) {
            const a = this.offsets[start];
            const b = this.offsets[end - 1];
            const lo = Math.min(a, b);
            const hi = Math.max(a, b);
            return [lo, hi + 1];
        }
        return null;
    }

    mapping(name: string, transform: (ch: string) => string | null): CharView {
        const outChars: string[] = [];
        const outOffsets: number[] = [];
        let changed = false;

        for (let i = 0; i < this.chars.length; i++) {
            const ch = this.chars[i];
            const origin = this.offsets[i];
            const replacement = transform(ch);

            if (replacement === null) {
                changed = true;
                continue;
            }

            if (replacement.length !== 1 || replacement[0] !== ch) {
                changed = true;
            }

            const replacementChars = Array.from(replacement);
            for (const rc of replacementChars) {
                outChars.push(rc);
                outOffsets.push(origin);
            }
        }

        return new CharView(
            outChars,
            outOffsets,
            changed ? [...this.transforms, name] : this.transforms
        );
    }

    filtering(name: string, keep: (ch: string) => boolean): CharView {
        return this.mapping(name, (ch) => keep(ch) ? ch : null);
    }
}

export class OffsetTable {
    private map: Map<number, number> = new Map();

    constructor(text: string) {
        // Convert to array of unicode characters to match swift's string indexing
        const chars = Array.from(text);
        let utf16Index = 0;
        for (let i = 0; i < chars.length; i++) {
            const charLen = chars[i]!.length;
            for (let j = 0; j < charLen; j++) {
                this.map.set(utf16Index + j, i);
            }
            utf16Index += charLen;
        }
        this.map.set(utf16Index, chars.length);
    }

    offset(index: number): number | undefined {
        return this.map.get(index);
    }
}

export interface RXMatch {
    start: number;
    end: number;
    text: string;
    groups: string[];
}

export class RX {
    private rx: RegExp;
    name: string;

    constructor(name: string, pattern: string, flags: string = 'i') {
        this.name = name;
        try {
            this.rx = new RegExp(pattern, flags.includes('g') ? flags : flags + 'g');
        } catch {
            this.rx = new RegExp("(?!)", "g");
        }
    }

    matches(text: string, limit: number = 64, offsets?: OffsetTable): RXMatch[] {
        if (!text) return [];
        const table = offsets ?? new OffsetTable(text);
        const out: RXMatch[] = [];

        this.rx.lastIndex = 0;

        for (const m of text.matchAll(this.rx)) {
            if (out.length >= limit) break;

            const startIdx = m.index;
            if (startIdx === undefined) continue;

            const endIdx = startIdx + m[0].length;

            const start = table.offset(startIdx);
            const end = table.offset(endIdx);

            if (start === undefined || end === undefined) continue;

            const groups = m.slice(1);
            out.push({ start, end, text: m[0], groups });
        }

        return out;
    }
}
