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

interface BeamSemver {
  /** Check if a version satisfies a requirement (Elixir `Version` syntax). */
  satisfies(version: string, range: string): boolean
  /** Compare two semver strings. Returns -1, 0, 1, or null if invalid. */
  order(a: string, b: string): -1 | 0 | 1 | null
}

interface BeamPeek {
  /**
   * Read a promise's result without `await`. Returns the promise itself if still pending.
   * Note: settled detection requires a microtask drain (separate eval call).
   */
  (promise: unknown): unknown
  /** Read a promise's status. Pending detection is synchronous; settled detection requires a microtask drain. */
  status(promise: unknown): 'fulfilled' | 'rejected' | 'pending'
}

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

  // --- Bun-parity utilities ---

  /** QuickBEAM version string. */
  readonly version: string

  /** Returns a Promise that resolves after the given number of milliseconds. */
  sleep(ms: number): Promise<void>

  /** Blocks the JS thread for the given number of milliseconds. */
  sleepSync(ms: number): void

  /** Fast non-cryptographic hash via `:erlang.phash2`. Optional range limits the output. */
  hash(data: unknown, range?: number): number

  /** Escape HTML entities: `& < > " '`. */
  escapeHTML(str: string): string

  /** Find an executable on PATH, like `which`. Returns absolute path or null. */
  which(bin: string): string | null

  /** Read a promise's result without await. Returns the value, error, or promise if pending. */
  peek: BeamPeek

  /** Generate a UUIDv7 (monotonic, sortable). */
  randomUUIDv7(): string

  /** Deep structural equality check. */
  deepEquals(a: unknown, b: unknown): boolean

  /** Semver operations backed by Elixir's `Version` module. */
  semver: BeamSemver

  // --- Unique to BEAM ---

  /** List connected BEAM nodes (including self). */
  nodes(): string[]

  /** Call a function in a named runtime on a remote BEAM node. */
  rpc(node: string, runtimeName: string, fnName: string, ...args: unknown[]): Promise<unknown>

  /** Spawn a new JS runtime (BEAM process) that evaluates the given script. */
  spawn(script: string): BeamPid

  /** Register the runtime under a name for discovery. */
  register(name: string): boolean

  /** Look up a registered runtime by name. Returns PID or null. */
  whereis(name: string): BeamPid | null

  /** Create a bidirectional link with another BEAM process. */
  link(pid: BeamPid): boolean

  /** Remove a bidirectional link with another BEAM process. */
  unlink(pid: BeamPid): boolean

  /** BEAM VM introspection: schedulers, memory, process count, atom count, OTP release. */
  systemInfo(): Record<string, unknown>

  /** Info about the owning GenServer process: memory, reductions, message queue, status. */
  processInfo(): Record<string, unknown> | null
}

declare const Beam: BeamAPI

// --- Compression ---

interface CompressionAPI {
  compress(format: 'gzip' | 'deflate' | 'deflate-raw', data: Uint8Array): Uint8Array
  decompress(format: 'gzip' | 'deflate' | 'deflate-raw', data: Uint8Array): Uint8Array
}

declare const compression: CompressionAPI
