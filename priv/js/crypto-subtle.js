(() => {
  // priv/ts/crypto-subtle.ts
  function normalizeCryptoAlgo(algo) {
    return typeof algo === "string" ? { name: algo } : algo;
  }
  function bufferSourceToBytes(data) {
    if (data instanceof Uint8Array)
      return data;
    if (data instanceof ArrayBuffer)
      return new Uint8Array(data);
    if (ArrayBuffer.isView(data))
      return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    return new Uint8Array(0);
  }
  function cipher(handler, algorithm, key, data) {
    const algo = { ...normalizeCryptoAlgo(algorithm) };
    if (algo.iv)
      algo.iv = bufferSourceToBytes(algo.iv);
    if (algo.additionalData)
      algo.additionalData = bufferSourceToBytes(algo.additionalData);
    return ensureArrayBuffer(beam.callSync(handler, algo, key, bufferSourceToBytes(data)));
  }
  function ensureArrayBuffer(result) {
    if (result instanceof ArrayBuffer)
      return result;
    if (result instanceof Uint8Array)
      return result.buffer;
    return new Uint8Array(result).buffer;
  }
  var subtle = {
    async digest(algorithm, data) {
      const algo = normalizeCryptoAlgo(algorithm);
      return ensureArrayBuffer(beam.callSync("__crypto_digest", algo.name, bufferSourceToBytes(data)));
    },
    async generateKey(algorithm, extractable, keyUsages) {
      const algo = normalizeCryptoAlgo(algorithm);
      const result = beam.callSync("__crypto_generate_key", algo);
      if ("publicKey" in result) {
        return {
          publicKey: { ...result.publicKey, extractable, usages: keyUsages },
          privateKey: { ...result.privateKey, extractable, usages: keyUsages }
        };
      }
      return { ...result, extractable, usages: keyUsages };
    },
    async sign(algorithm, key, data) {
      const algo = normalizeCryptoAlgo(algorithm);
      return ensureArrayBuffer(beam.callSync("__crypto_sign", algo, key, bufferSourceToBytes(data)));
    },
    async verify(algorithm, key, signature, data) {
      const algo = normalizeCryptoAlgo(algorithm);
      return beam.callSync("__crypto_verify", algo, key, bufferSourceToBytes(signature), bufferSourceToBytes(data));
    },
    async encrypt(algorithm, key, data) {
      return cipher("__crypto_encrypt", algorithm, key, data);
    },
    async decrypt(algorithm, key, data) {
      return cipher("__crypto_decrypt", algorithm, key, data);
    },
    async deriveBits(algorithm, baseKey, length) {
      const algo = { ...normalizeCryptoAlgo(algorithm) };
      if (algo.salt)
        algo.salt = bufferSourceToBytes(algo.salt);
      if (algo.public)
        algo.public = baseKey._ecdhPublic ?? algo.public;
      return ensureArrayBuffer(beam.callSync("__crypto_derive_bits", algo, baseKey, length));
    },
    async deriveKey(algorithm, baseKey, derivedKeyType, extractable, keyUsages) {
      const algo = { ...normalizeCryptoAlgo(algorithm) };
      if (algo.salt)
        algo.salt = bufferSourceToBytes(algo.salt);
      const dkAlgo = normalizeCryptoAlgo(derivedKeyType);
      const bits = dkAlgo.length ?? 256;
      const derived = await this.deriveBits(algo, baseKey, bits);
      return {
        type: "secret",
        algorithm: dkAlgo.name,
        data: new Uint8Array(derived),
        extractable,
        usages: keyUsages
      };
    },
    async importKey(format, keyData, algorithm, extractable, keyUsages) {
      const algo = normalizeCryptoAlgo(algorithm);
      let data;
      if (format === "raw") {
        data = bufferSourceToBytes(keyData);
      } else if (format === "jwk") {
        const jwk = keyData;
        if (jwk.k) {
          const b64 = jwk.k.replace(/-/g, "+").replace(/_/g, "/");
          data = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
        } else {
          data = new Uint8Array(0);
        }
      } else {
        throw new DOMException(`Unsupported format: ${format}`, "NotSupportedError");
      }
      return {
        type: keyUsages.includes("sign") || keyUsages.includes("encrypt") ? "secret" : "public",
        algorithm: algo.name,
        hash: algo.hash,
        data,
        extractable,
        usages: keyUsages
      };
    },
    async exportKey(format, key) {
      if (format === "raw") {
        return ensureArrayBuffer(key.data);
      }
      throw new DOMException(`Unsupported format: ${format}`, "NotSupportedError");
    }
  };
  Object.defineProperty(crypto, "subtle", { value: subtle, writable: false });
  crypto.randomUUID = function() {
    const bytes = new Uint8Array(16);
    crypto.getRandomValues(bytes);
    bytes[6] = bytes[6] & 15 | 64;
    bytes[8] = bytes[8] & 63 | 128;
    const hex = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  };
})();
