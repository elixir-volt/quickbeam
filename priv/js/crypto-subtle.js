(() => {
  function toByteArray(data) {
    if (data instanceof ArrayBuffer) return [...new Uint8Array(data)];
    if (ArrayBuffer.isView(data)) return [...new Uint8Array(data.buffer, data.byteOffset, data.byteLength)];
    if (Array.isArray(data)) return data;
    return [];
  }

  function normalizeAlgo(algo) {
    return typeof algo === 'string' ? { name: algo } : algo;
  }

  function keyForTransport(key) {
    if (!key || !key.data) return key;
    return { ...key, data: toByteArray(key.data) };
  }

  function toArrayBuffer(result) {
    if (result instanceof ArrayBuffer) return result;
    if (result instanceof Uint8Array) return result.buffer;
    return new Uint8Array(result).buffer;
  }

  const subtle = {
    async digest(algorithm, data) {
      const algo = normalizeAlgo(algorithm);
      const result = beam.callSync('__crypto_digest', algo.name, toByteArray(data));
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
      const result = beam.callSync('__crypto_sign', algo, keyForTransport(key), toByteArray(data));
      return toArrayBuffer(result);
    },

    async verify(algorithm, key, signature, data) {
      const algo = normalizeAlgo(algorithm);
      return beam.callSync('__crypto_verify', algo, keyForTransport(key), toByteArray(signature), toByteArray(data));
    },

    async encrypt(algorithm, key, data) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.iv) algo.iv = toByteArray(algo.iv);
      if (algo.additionalData) algo.additionalData = toByteArray(algo.additionalData);
      const result = beam.callSync('__crypto_encrypt', algo, keyForTransport(key), toByteArray(data));
      return toArrayBuffer(result);
    },

    async decrypt(algorithm, key, data) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.iv) algo.iv = toByteArray(algo.iv);
      if (algo.additionalData) algo.additionalData = toByteArray(algo.additionalData);
      const result = beam.callSync('__crypto_decrypt', algo, keyForTransport(key), toByteArray(data));
      return toArrayBuffer(result);
    },

    async deriveBits(algorithm, baseKey, length) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.salt) algo.salt = toByteArray(algo.salt);
      if (algo.public) algo.public = baseKey._ecdhPublic || algo.public;
      return toArrayBuffer(
        beam.callSync('__crypto_derive_bits', algo, keyForTransport(baseKey), length)
      );
    },

    async deriveKey(algorithm, baseKey, derivedKeyAlgorithm, extractable, keyUsages) {
      const algo = { ...normalizeAlgo(algorithm) };
      if (algo.salt) algo.salt = toByteArray(algo.salt);
      const dkAlgo = normalizeAlgo(derivedKeyAlgorithm);
      const bits = dkAlgo.length || 256;
      const derived = await this.deriveBits(algo, baseKey, bits);
      return {
        type: 'secret',
        algorithm: dkAlgo.name,
        data: [...new Uint8Array(derived)],
        extractable,
        usages: keyUsages
      };
    },

    async importKey(format, keyData, algorithm, extractable, keyUsages) {
      const algo = normalizeAlgo(algorithm);
      let data;
      if (format === 'raw') {
        data = toByteArray(keyData);
      } else if (format === 'jwk') {
        if (keyData.k) {
          const b64 = keyData.k.replace(/-/g, '+').replace(/_/g, '/');
          data = [...atob(b64)].map(c => c.charCodeAt(0));
        } else {
          data = [];
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
