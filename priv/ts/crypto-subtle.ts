/**
 * Internal key representation carrying raw key bytes.
 * The standard CryptoKey is opaque — ours exposes `data` for BEAM transport.
 */
interface CryptoKeyInternal {
  type: string
  algorithm: string
  namedCurve?: string
  hash?: string
  data: Uint8Array
  extractable: boolean
  usages: KeyUsage[]
  _ecdhPublic?: Uint8Array
}

interface CryptoKeyPairInternal {
  publicKey: CryptoKeyInternal
  privateKey: CryptoKeyInternal
}

interface CryptoAlgoParams extends Algorithm {
  hash?: string
  namedCurve?: string
  length?: number
  iv?: Uint8Array
  additionalData?: Uint8Array
  salt?: Uint8Array
  iterations?: number
  public?: Uint8Array
}

function normalizeCryptoAlgo(algo: AlgorithmIdentifier): CryptoAlgoParams {
  return typeof algo === 'string' ? { name: algo } : (algo as CryptoAlgoParams)
}

function bufferSourceToBytes(data: ArrayBuffer | Uint8Array | ArrayBufferView): Uint8Array {
  if (data instanceof Uint8Array) return data
  if (data instanceof ArrayBuffer) return new Uint8Array(data)
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
  return new Uint8Array(0)
}

function cipher(
  handler: string,
  algorithm: AlgorithmIdentifier,
  key: CryptoKeyInternal,
  data: BufferSource
): ArrayBuffer {
  const algo: CryptoAlgoParams = { ...normalizeCryptoAlgo(algorithm) }
  if (algo.iv) algo.iv = bufferSourceToBytes(algo.iv)
  if (algo.additionalData) algo.additionalData = bufferSourceToBytes(algo.additionalData)
  return ensureArrayBuffer(Beam.callSync(handler, algo, key, bufferSourceToBytes(data)))
}

function ensureArrayBuffer(result: unknown): ArrayBuffer {
  if (result instanceof ArrayBuffer) return result
  if (result instanceof Uint8Array) return result.buffer as ArrayBuffer
  return new Uint8Array(result as number[]).buffer
}

const subtle = {
  async digest(algorithm: AlgorithmIdentifier, data: BufferSource): Promise<ArrayBuffer> {
    const algo = normalizeCryptoAlgo(algorithm)
    return ensureArrayBuffer(Beam.callSync('__crypto_digest', algo.name, bufferSourceToBytes(data)))
  },

  async generateKey(
    algorithm: AlgorithmIdentifier,
    extractable: boolean,
    keyUsages: KeyUsage[]
  ): Promise<CryptoKeyInternal | CryptoKeyPairInternal> {
    const algo = normalizeCryptoAlgo(algorithm)
    const result = Beam.callSync('__crypto_generate_key', algo) as
      | CryptoKeyInternal
      | CryptoKeyPairInternal
    if ('publicKey' in result) {
      return {
        publicKey: { ...result.publicKey, extractable, usages: keyUsages },
        privateKey: { ...result.privateKey, extractable, usages: keyUsages }
      }
    }
    return { ...result, extractable, usages: keyUsages }
  },

  async sign(
    algorithm: AlgorithmIdentifier,
    key: CryptoKeyInternal,
    data: BufferSource
  ): Promise<ArrayBuffer> {
    const algo = normalizeCryptoAlgo(algorithm)
    return ensureArrayBuffer(Beam.callSync('__crypto_sign', algo, key, bufferSourceToBytes(data)))
  },

  async verify(
    algorithm: AlgorithmIdentifier,
    key: CryptoKeyInternal,
    signature: BufferSource,
    data: BufferSource
  ): Promise<boolean> {
    const algo = normalizeCryptoAlgo(algorithm)
    return Beam.callSync(
      '__crypto_verify',
      algo,
      key,
      bufferSourceToBytes(signature),
      bufferSourceToBytes(data)
    ) as boolean
  },

  async encrypt(
    algorithm: AlgorithmIdentifier,
    key: CryptoKeyInternal,
    data: BufferSource
  ): Promise<ArrayBuffer> {
    return cipher('__crypto_encrypt', algorithm, key, data)
  },

  async decrypt(
    algorithm: AlgorithmIdentifier,
    key: CryptoKeyInternal,
    data: BufferSource
  ): Promise<ArrayBuffer> {
    return cipher('__crypto_decrypt', algorithm, key, data)
  },

  async deriveBits(
    algorithm: AlgorithmIdentifier,
    baseKey: CryptoKeyInternal,
    length: number
  ): Promise<ArrayBuffer> {
    const algo: CryptoAlgoParams = { ...normalizeCryptoAlgo(algorithm) }
    if (algo.salt) algo.salt = bufferSourceToBytes(algo.salt)
    if (algo.public) algo.public = baseKey._ecdhPublic ?? algo.public
    return ensureArrayBuffer(Beam.callSync('__crypto_derive_bits', algo, baseKey, length))
  },

  async deriveKey(
    algorithm: AlgorithmIdentifier,
    baseKey: CryptoKeyInternal,
    derivedKeyType: AlgorithmIdentifier,
    extractable: boolean,
    keyUsages: KeyUsage[]
  ): Promise<CryptoKeyInternal> {
    const algo: CryptoAlgoParams = { ...normalizeCryptoAlgo(algorithm) }
    if (algo.salt) algo.salt = bufferSourceToBytes(algo.salt)
    const dkAlgo = normalizeCryptoAlgo(derivedKeyType)
    const bits = dkAlgo.length ?? 256
    const derived = await this.deriveBits(algo, baseKey, bits)
    return {
      type: 'secret',
      algorithm: dkAlgo.name,
      data: new Uint8Array(derived),
      extractable,
      usages: keyUsages
    }
  },

  async importKey(
    format: KeyFormat,
    keyData: BufferSource | JsonWebKey,
    algorithm: AlgorithmIdentifier,
    extractable: boolean,
    keyUsages: KeyUsage[]
  ): Promise<CryptoKeyInternal> {
    const algo = normalizeCryptoAlgo(algorithm)
    let data: Uint8Array
    if (format === 'raw') {
      data = bufferSourceToBytes(keyData as BufferSource)
    } else if (format === 'jwk') {
      const jwk = keyData as JsonWebKey
      if (jwk.k) {
        const b64 = jwk.k.replace(/-/g, '+').replace(/_/g, '/')
        data = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
      } else {
        data = new Uint8Array(0)
      }
    } else {
      throw new DOMException(`Unsupported format: ${format}`, 'NotSupportedError')
    }

    return {
      type: keyUsages.includes('sign') || keyUsages.includes('encrypt') ? 'secret' : 'public',
      algorithm: algo.name,
      hash: algo.hash,
      data,
      extractable,
      usages: keyUsages
    }
  },

  async exportKey(format: KeyFormat, key: CryptoKeyInternal): Promise<ArrayBuffer> {
    if (format === 'raw') {
      return ensureArrayBuffer(key.data)
    }
    throw new DOMException(`Unsupported format: ${format}`, 'NotSupportedError')
  }
}

// QuickJS-NG provides `crypto` without `subtle` — we polyfill it
Object.defineProperty(crypto, 'subtle', { value: subtle, writable: false })

crypto.randomUUID = function (): `${string}-${string}-${string}-${string}-${string}` {
  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)
  bytes[6] = (bytes[6] & 0x0f) | 0x40 // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80 // variant 10
  const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}
