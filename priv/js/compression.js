(() => {
  function toUint8Array(data) {
    if (data instanceof Uint8Array) return data;
    if (data instanceof ArrayBuffer) return new Uint8Array(data);
    if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    if (typeof data === 'string') return new TextEncoder().encode(data);
    return new Uint8Array(0);
  }

  const compression = {
    compress(format, data) {
      if (!['gzip', 'deflate', 'deflate-raw'].includes(format)) {
        throw new TypeError(`Unsupported format: ${format}`);
      }
      return beam.callSync('__compress', format, toUint8Array(data));
    },

    decompress(format, data) {
      if (!['gzip', 'deflate', 'deflate-raw'].includes(format)) {
        throw new TypeError(`Unsupported format: ${format}`);
      }
      return beam.callSync('__decompress', format, toUint8Array(data));
    }
  };

  Object.defineProperty(globalThis, 'compression', { value: compression, writable: false });
})();
