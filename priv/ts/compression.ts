function toUint8Array(data: unknown): Uint8Array {
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (typeof data === "string") return new TextEncoder().encode(data);
  return new Uint8Array(0);
}

const FORMATS: CompressionFormat[] = ["gzip", "deflate", "deflate-raw"];

const compressionImpl: CompressionAPI = {
  compress(format: CompressionFormat, data: Uint8Array): Uint8Array {
    if (!FORMATS.includes(format)) {
      throw new TypeError(`Unsupported format: ${format}`);
    }
    return beam.callSync("__compress", format, toUint8Array(data)) as Uint8Array;
  },

  decompress(format: CompressionFormat, data: Uint8Array): Uint8Array {
    if (!FORMATS.includes(format)) {
      throw new TypeError(`Unsupported format: ${format}`);
    }
    return beam.callSync("__decompress", format, toUint8Array(data)) as Uint8Array;
  },
};

Object.defineProperty(globalThis, "compression", {
  value: compressionImpl,
  writable: false,
});
