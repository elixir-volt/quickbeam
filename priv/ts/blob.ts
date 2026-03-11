import { QBReadableStream } from "./streams";
import type { QBReadableStreamController } from "./streams";

export type QBBlobPart = Uint8Array | ArrayBuffer | DataView | QBBlob | string;

export interface QBBlobPropertyBag {
  type?: string;
  endings?: "transparent" | "native";
}

export const SYM_BYTES = Symbol("bytes");

function normalizeQBBlobPart(part: QBBlobPart): Uint8Array {
  if (part instanceof Uint8Array) return part;
  if (part instanceof ArrayBuffer) return new Uint8Array(part);
  if (part instanceof DataView)
    return new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
  if (part instanceof QBBlob) return part[SYM_BYTES]();
  if (typeof part === "string") return new TextEncoder().encode(part);
  return new Uint8Array(0);
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  if (parts.length === 0) return new Uint8Array(0);
  if (parts.length === 1) return parts[0];

  let total = 0;
  for (const p of parts) total += p.length;

  const result = new Uint8Array(total);
  let offset = 0;
  for (const p of parts) {
    result.set(p, offset);
    offset += p.length;
  }
  return result;
}

function clampIndex(idx: number, size: number): number {
  if (idx < 0) return Math.max(size + idx, 0);
  return Math.min(idx, size);
}

export class QBBlob {
  #parts: Uint8Array[];
  #type: string;

  constructor(parts?: QBBlobPart[], options?: QBBlobPropertyBag) {
    const raw = options?.type ?? "";
    this.#type = /^[\x20-\x7E]*$/.test(raw) ? raw.toLowerCase() : "";
    this.#parts = (parts ?? []).map(normalizeQBBlobPart);
  }

  get size(): number {
    let total = 0;
    for (const p of this.#parts) total += p.length;
    return total;
  }

  get type(): string {
    return this.#type;
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return this[SYM_BYTES]().buffer as ArrayBuffer;
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this[SYM_BYTES]());
  }

  async bytes(): Promise<Uint8Array> {
    return this[SYM_BYTES]();
  }

  slice(start?: number, end?: number, contentType?: string): QBBlob {
    const bytes = this[SYM_BYTES]();
    const s = clampIndex(start ?? 0, bytes.length);
    const e = clampIndex(end ?? bytes.length, bytes.length);
    const raw = contentType ?? "";
    return new QBBlob([bytes.slice(s, Math.max(s, e))], {
      type: /^[\x20-\x7E]*$/.test(raw) ? raw : "",
    });
  }

  stream(): QBReadableStream<Uint8Array> {
    const bytes = this[SYM_BYTES]();
    return new QBReadableStream({
      start(controller: QBReadableStreamController<Uint8Array>) {
        if (bytes.length > 0) controller.enqueue(bytes);
        controller.close();
      },
    });
  }

  [SYM_BYTES](): Uint8Array {
    return concatBytes(this.#parts);
  }
}

export class QBFile extends QBBlob {
  readonly name: string;
  readonly lastModified: number;

  constructor(
    parts: QBBlobPart[],
    name: string,
    options?: QBBlobPropertyBag & { lastModified?: number },
  ) {
    super(parts, options);
    this.name = name;
    this.lastModified = options?.lastModified ?? Date.now();
  }
}

(globalThis as Record<string, unknown>).Blob = QBBlob;
(globalThis as Record<string, unknown>).File = QBFile;
