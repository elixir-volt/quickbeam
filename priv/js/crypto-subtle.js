(() => {
  function normalizeAlgo(algo) {
    return typeof algo === 'string' ? { name: algo } : algo;
  }

  function toUint8Array(data) {
    if (data instanceof Uint8Array) return data;
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (Array.isArray(data)) return new Uint8Array(data);
    return new Uint8Array(0);
  }

  function toArrayBuffer(result) {
    if (result instanceof ArrayBuffer) return result;
    if (result instanceof Uint8Array) return result.buffer;
    return new Uint8Array(result).buffer;
  }

  const subtle = {
    async digest(algorithm, data) {
      const algo = normalizeAlgo(algorithm);
      const result = beam.callSync('__crypto_digest', algo.name, toUint8Array(data));
      return toArrayBuffer(result);
    },

    async generateKey(algorithm, extractable, keyUsages) {
      const algo = normalizeAlgo(algorithm);
      const result = beam.callSync('__crypto_generate_key', algo);
      if (result.publicKey) {
        return {
          publicKey: { ...result.publicKey, extractable, usages: keyUsages },
          privateKey: { ...result.privateKey, extractable, usages: keyUsages }
        };
      }
      return { ...result, extractable, usages: keyUsages };
    },

    async sign(algorithm, key, data) {
      const algo = normalizeAlgo(algorithm);
      const result = beam.callSync('__crypto_sign', algo, key, toUint8Array(data));
      return toArrayBuffer(result);
    },

    async verify(algorithm, key, signature, data) {
      const algo = normalizeAlgo(algorithm);
      return beam.callSync('__crypto_verify', algo, key, toUint8Array(signature), toUint8Array(data));
    },

    async encrypt(algorithm, key, data) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.iv) algo.iv = toUint8Array(algo.iv);
      if (algo.additionalData) algo.additionalData = toUint8Array(algo.additionalData);
      const result = beam.callSync('__crypto_encrypt', algo, key, toUint8Array(data));
      return toArrayBuffer(result);
    },

    async decrypt(algorithm, key, data) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.iv) algo.iv = toUint8Array(algo.iv);
      if (algo.additionalData) algo.additionalData = toUint8Array(algo.additionalData);
      const result = beam.callSync('__crypto_decrypt', algo, key, toUint8Array(data));
      return toArrayBuffer(result);
    },

    async deriveBits(algorithm, baseKey, length) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.salt) algo.salt = toUint8Array(algo.salt);
      if (algo.public) algo.public = baseKey._ecdhPublic || algo.public;
      return toArrayBuffer(
        beam.callSync('__crypto_derive_bits', algo, baseKey, length)
      );
    },

    async deriveKey(algorithm, baseKey, derivedKeyAlgorithm, extractable, keyUsages) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.salt) algo.salt = toUint8Array(algo.salt);
      const dkAlgo = normalizeAlgo(derivedKeyAlgorithm);
      const bits = dkAlgo.length || 256;
      const derived = await this.deriveBits(algo, baseKey, bits);
      return {
        type: 'secret',
        algorithm: dkAlgo.name,
        data: new Uint8Array(derived),
        extractable,
        usages: keyUsages
      };
    },

    async importKey(format, keyData, algorithm, extractable, keyUsages) {
      const algo = normalizeAlgo(algorithm);
      let data;
      if (format === 'raw') {
        data = toUint8Array(keyData);
      } else if (format === 'jwk') {
        if (keyData.k) {
          const b64 = keyData.k.replace(/-/g, '+').replace(/_/g, '/');
          data = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
        } else {
          data = new Uint8Array(0);
        }
      } else {
        throw new DOMException(`Unsupported format: ${format}`, 'NotSupportedError');
      }

      return {
        type: keyUsages.includes('sign') || keyUsages.includes('encrypt') ? 'secret' : 'public',
        algorithm: algo.name,
        hash: algo.hash,
        data,
        extractable,
        usages: keyUsages
      };
    },

    async exportKey(format, key) {
      if (format === 'raw') {
        return toArrayBuffer(key.data);
      }
      throw new DOMException(`Unsupported format: ${format}`, 'NotSupportedError');
    }
  };

  if (!crypto.subtle) {
    Object.defineProperty(crypto, 'subtle', { value: subtle, writable: false });
  }
})();
