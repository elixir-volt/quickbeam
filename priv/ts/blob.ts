import { ReadableStream } from './streams'

import type { ReadableStreamController } from './streams'

export type BlobPart = BufferSource | Blob | string

export interface BlobPropertyBag {
  type?: string
  endings?: 'transparent' | 'native'
}

export const SYM_BYTES = Symbol('bytes')

function isArrayBufferView(v: unknown): v is ArrayBufferView {
  return ArrayBuffer.isView(v)
}

function normalizePart(part: BlobPart): Uint8Array {
  if (part instanceof Blob) return part[SYM_BYTES]()
  if (part instanceof ArrayBuffer) return new Uint8Array(part)
  if (isArrayBufferView(part)) {
    return new Uint8Array(part.buffer, part.byteOffset, part.byteLength)
  }
  return new TextEncoder().encode(String(part))
}

function concatBytes(parts: Uint8Array[]): Uint8Array {
  if (parts.length === 0) return new Uint8Array(0)
  if (parts.length === 1) return parts[0]

  let total = 0
  for (const p of parts) total += p.length

  const result = new Uint8Array(total)
  let offset = 0
  for (const p of parts) {
    result.set(p, offset)
    offset += p.length
  }
  return result
}

function clampIndex(idx: number, size: number): number {
  const i = Math.trunc(idx) || 0
  if (i < 0) return Math.max(size + i, 0)
  return Math.min(i, size)
}

function normalizeType(raw: string): string {
  return /^[\x20-\x7E]*$/.test(raw) ? raw.toLowerCase() : ''
}

export class Blob {
  #parts: Uint8Array[]
  #type: string

  constructor(parts?: BlobPart[], options?: BlobPropertyBag) {
    this.#type = normalizeType(options?.type ?? '')
    this.#parts = (parts ?? []).map(normalizePart)
  }

  get size(): number {
    let total = 0
    for (const p of this.#parts) total += p.length
    return total
  }

  get type(): string {
    return this.#type
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return this[SYM_BYTES]().buffer as ArrayBuffer
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this[SYM_BYTES]())
  }

  async bytes(): Promise<Uint8Array> {
    return this[SYM_BYTES]().slice()
  }

  slice(start?: number, end?: number, contentType?: string): Blob {
    const bytes = this[SYM_BYTES]()
    const s = clampIndex(start ?? 0, bytes.length)
    const e = clampIndex(end ?? bytes.length, bytes.length)
    return new Blob([bytes.slice(s, Math.max(s, e))], {
      type: normalizeType(contentType ?? '')
    })
  }

  stream(): ReadableStream<Uint8Array> {
    const bytes = this[SYM_BYTES]()
    return new ReadableStream({
      start(controller: ReadableStreamController<Uint8Array>) {
        if (bytes.length > 0) controller.enqueue(bytes)
        controller.close()
      }
    })
  }

  [SYM_BYTES](): Uint8Array {
    return concatBytes(this.#parts)
  }
}

export class File extends Blob {
  readonly name: string
  readonly lastModified: number

  constructor(
    parts: BlobPart[],
    name: string,
    options?: BlobPropertyBag & { lastModified?: number }
  ) {
    super(parts, options)
    this.name = name
    this.lastModified = options?.lastModified ?? Date.now()
  }
}
