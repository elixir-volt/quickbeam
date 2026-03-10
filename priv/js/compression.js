(() => {
  // priv/ts/compression.ts
  function toUint8Array(data) {
    if (data instanceof Uint8Array)
      return data;
    if (data instanceof ArrayBuffer)
      return new Uint8Array(data);
    if (typeof data === "string")
      return new TextEncoder().encode(data);
    return new Uint8Array(0);
  }
  var FORMATS = ["gzip", "deflate", "deflate-raw"];
  var compressionImpl = {
    compress(format, data) {
      if (!FORMATS.includes(format)) {
        throw new TypeError(`Unsupported format: ${format}`);
      }
      return beam.callSync("__compress", format, toUint8Array(data));
    },
    decompress(format, data) {
      if (!FORMATS.includes(format)) {
        throw new TypeError(`Unsupported format: ${format}`);
      }
      return beam.callSync("__decompress", format, toUint8Array(data));
    }
  };
  Object.defineProperty(globalThis, "compression", {
    value: compressionImpl,
    writable: false
  });
})();
