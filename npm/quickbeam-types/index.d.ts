/**
 * QuickBEAM runtime API — BEAM-specific globals available inside the JS engine.
 *
 * Standard Web APIs (TextEncoder, URL, crypto, console, setTimeout, etc.)
 * are typed by TypeScript's lib.dom.d.ts — include "DOM" in your tsconfig lib.
 *
 * This file only declares QuickBEAM-specific extensions.
 */

// --- Opaque BEAM terms ---

/** Opaque BEAM process identifier. Round-trips correctly through JS. */
interface BeamPid {
  readonly __beam_type__: 'pid'
  readonly __beam_data__: Uint8Array
}

/** Opaque BEAM reference. */
interface BeamRef {
  readonly __beam_type__: 'ref'
  readonly __beam_data__: Uint8Array
}

/** Opaque BEAM port. */
interface BeamPort {
  readonly __beam_type__: 'port'
  readonly __beam_data__: Uint8Array
}

type BeamTerm = BeamPid | BeamRef | BeamPort

// --- BEAM bridge ---

interface BeamAPI {
  /** Call a named BEAM handler (async). Returns a Promise with the result. */
  call(handler: string, ...args: unknown[]): Promise<unknown>

  /** Call a named BEAM handler (synchronous, blocks the JS thread). */
  callSync(handler: string, ...args: unknown[]): unknown

  /** Send a message to a BEAM process. Fire-and-forget. */
  send(pid: BeamPid, message: unknown): void

  /** Get the PID of the owning GenServer process. */
  self(): BeamPid

  /** Register a callback for incoming BEAM messages. */
  onMessage(callback: (message: unknown) => void): void

  /** Monitor a BEAM process. Callback fires with exit reason when it dies. */
  monitor(pid: BeamPid, callback: (reason: unknown) => void): BeamRef

  /** Cancel a monitor previously set with `Beam.monitor`. */
  demonitor(ref: BeamRef): void
}

declare const Beam: BeamAPI

// --- Compression ---

interface CompressionAPI {
  compress(format: 'gzip' | 'deflate' | 'deflate-raw', data: Uint8Array): Uint8Array
  decompress(format: 'gzip' | 'deflate' | 'deflate-raw', data: Uint8Array): Uint8Array
}

declare const compression: CompressionAPI
