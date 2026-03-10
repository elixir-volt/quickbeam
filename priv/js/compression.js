(() => {
  function toByteArray(data) {
    if (data instanceof ArrayBuffer) return [...new Uint8Array(data)];
    if (ArrayBuffer.isView(data)) return [...new Uint8Array(data.buffer, data.byteOffset, data.byteLength)];
    if (Array.isArray(data)) return data;
    if (typeof data === 'string') return [...new TextEncoder().encode(data)];
    return [];
  }

  const compression = {
    compress(format, data) {
      if (!['gzip', 'deflate', 'deflate-raw'].includes(format)) {
        throw new TypeError(`Unsupported format: ${format}`);
      }
      const result = beam.callSync('__compress', format, toByteArray(data));
      return result instanceof Uint8Array ? result : new Uint8Array(result);
    },

    decompress(format, data) {
      if (!['gzip', 'deflate', 'deflate-raw'].includes(format)) {
        throw new TypeError(`Unsupported format: ${format}`);
      }
      const result = beam.callSync('__decompress', format, toByteArray(data));
      return result instanceof Uint8Array ? result : new Uint8Array(result);
    }
  };

  Object.defineProperty(globalThis, 'compression', { value: compression, writable: false });
})();
