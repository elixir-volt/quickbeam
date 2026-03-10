/**
 * QuickBEAM-specific globals available inside the QuickJS-NG engine.
 */

interface Beam {
  callSync(handler: string, ...args: unknown[]): unknown;
  call(handler: string, ...args: unknown[]): Promise<unknown>;
}

declare const beam: Beam;

type CompressionFormat = "gzip" | "deflate" | "deflate-raw";

interface CompressionAPI {
  compress(format: CompressionFormat, data: Uint8Array): Uint8Array;
  decompress(format: CompressionFormat, data: Uint8Array): Uint8Array;
}

declare const compression: CompressionAPI;
