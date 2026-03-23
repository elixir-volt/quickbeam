interface Stats {
  isFile(): boolean
  isDirectory(): boolean
  isSymbolicLink(): boolean
  size: number
  mode: number
  mtime: Date
  atime: Date
  ctime: Date
  birthtime: Date
  mtimeMs: number
  atimeMs: number
  ctimeMs: number
  birthtimeMs: number
}

function makeStats(raw: Record<string, unknown>): Stats {
  const mtimeMs = raw.mtime as number
  const atimeMs = raw.atime as number
  const ctimeMs = raw.ctime as number
  const birthtimeMs = raw.birthtime as number
  return {
    size: raw.size as number,
    mode: raw.mode as number,
    mtime: new Date(mtimeMs),
    atime: new Date(atimeMs),
    ctime: new Date(ctimeMs),
    birthtime: new Date(birthtimeMs),
    mtimeMs,
    atimeMs,
    ctimeMs,
    birthtimeMs,
    isFile: () => (raw.type as string) === 'regular',
    isDirectory: () => (raw.type as string) === 'directory',
    isSymbolicLink: () => (raw.type as string) === 'symlink',
  }
}

type QBNodeEncoding = 'utf8' | 'utf-8' | 'binary' | 'latin1' | 'base64' | 'hex' | null

interface ReadOptions {
  encoding?: QBNodeEncoding
  flag?: string
}

interface WriteOptions {
  encoding?: QBNodeEncoding
  mode?: number
  flag?: string
}

interface MkdirOptions {
  recursive?: boolean
  mode?: number
}

interface RmOptions {
  recursive?: boolean
  force?: boolean
}

interface ReaddirOptions {
  encoding?: QBNodeEncoding
  withFileTypes?: boolean
}

function readFileSync(path: string, options?: QBNodeEncoding | ReadOptions): string | Uint8Array {
  const encoding = typeof options === 'string' ? options : options?.encoding
  const result = Beam.callSync('__fs_read_file', path) as Uint8Array | null
  if (result === null) throw new Error(`ENOENT: no such file or directory, open '${path}'`)
  if (encoding) return new TextDecoder().decode(result)
  return result
}

function writeFileSync(path: string, data: string | Uint8Array, options?: QBNodeEncoding | WriteOptions): void {
  void options
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data
  const ok = Beam.callSync('__fs_write_file', path, bytes) as boolean
  if (!ok) throw new Error(`EACCES: permission denied, open '${path}'`)
}

function appendFileSync(path: string, data: string | Uint8Array, options?: QBNodeEncoding | WriteOptions): void {
  void options
  const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : data
  const ok = Beam.callSync('__fs_append_file', path, bytes) as boolean
  if (!ok) throw new Error(`EACCES: permission denied, open '${path}'`)
}

function existsSync(path: string): boolean {
  return Beam.callSync('__fs_exists', path) as boolean
}

function mkdirSync(path: string, options?: MkdirOptions): void {
  const ok = Beam.callSync('__fs_mkdir', path, options?.recursive ?? false) as boolean
  if (!ok) throw new Error(`EEXIST: file already exists, mkdir '${path}'`)
}

function readdirSync(path: string, _options?: ReaddirOptions): string[] {
  const result = Beam.callSync('__fs_readdir', path) as string[] | null
  if (result === null) throw new Error(`ENOENT: no such file or directory, scandir '${path}'`)
  return result
}

function statSync(path: string): Stats {
  const result = Beam.callSync('__fs_stat', path) as Record<string, unknown> | null
  if (result === null) throw new Error(`ENOENT: no such file or directory, stat '${path}'`)
  return makeStats(result)
}

function lstatSync(path: string): Stats {
  const result = Beam.callSync('__fs_lstat', path) as Record<string, unknown> | null
  if (result === null) throw new Error(`ENOENT: no such file or directory, lstat '${path}'`)
  return makeStats(result)
}

function unlinkSync(path: string): void {
  const ok = Beam.callSync('__fs_unlink', path) as boolean
  if (!ok) throw new Error(`ENOENT: no such file or directory, unlink '${path}'`)
}

function renameSync(oldPath: string, newPath: string): void {
  const ok = Beam.callSync('__fs_rename', oldPath, newPath) as boolean
  if (!ok) throw new Error(`ENOENT: no such file or directory, rename '${oldPath}' -> '${newPath}'`)
}

function rmSync(path: string, options?: RmOptions): void {
  const ok = Beam.callSync('__fs_rm', path, options?.recursive ?? false, options?.force ?? false) as boolean
  if (!ok && !(options?.force)) throw new Error(`ENOENT: no such file or directory, rm '${path}'`)
}

function copyFileSync(src: string, dest: string): void {
  const ok = Beam.callSync('__fs_copy_file', src, dest) as boolean
  if (!ok) throw new Error(`ENOENT: no such file or directory, copyfile '${src}' -> '${dest}'`)
}

function realpathSync(path: string): string {
  const result = Beam.callSync('__fs_realpath', path) as string | null
  if (result === null) throw new Error(`ENOENT: no such file or directory, realpath '${path}'`)
  return result
}

// Async wrappers
function readFile(path: string, options: QBNodeEncoding | ReadOptions, callback: (err: Error | null, data?: string | Uint8Array) => void): void
function readFile(path: string, callback: (err: Error | null, data?: Uint8Array) => void): void
function readFile(path: string, optionsOrCb: unknown, callback?: unknown): void {
  const cb = (typeof optionsOrCb === 'function' ? optionsOrCb : callback) as (err: Error | null, data?: unknown) => void
  const opts = typeof optionsOrCb === 'function' ? undefined : optionsOrCb
  queueMicrotask(() => {
    try {
      const result = readFileSync(path, opts as QBNodeEncoding | ReadOptions)
      cb(null, result)
    } catch (err) {
      cb(err as Error)
    }
  })
}

function writeFile(path: string, data: string | Uint8Array, options: QBNodeEncoding | WriteOptions, callback: (err: Error | null) => void): void
function writeFile(path: string, data: string | Uint8Array, callback: (err: Error | null) => void): void
function writeFile(path: string, data: string | Uint8Array, optionsOrCb: unknown, callback?: unknown): void {
  const cb = (typeof optionsOrCb === 'function' ? optionsOrCb : callback) as (err: Error | null) => void
  const opts = typeof optionsOrCb === 'function' ? undefined : optionsOrCb
  queueMicrotask(() => {
    try {
      writeFileSync(path, data, opts as QBNodeEncoding | WriteOptions)
      cb(null)
    } catch (err) {
      cb(err as Error)
    }
  })
}

const fs = {
  readFileSync,
  writeFileSync,
  appendFileSync,
  existsSync,
  mkdirSync,
  readdirSync,
  statSync,
  lstatSync,
  unlinkSync,
  renameSync,
  rmSync,
  copyFileSync,
  realpathSync,
  readFile,
  writeFile,
}

;(globalThis as Record<string, unknown>).fs = fs
