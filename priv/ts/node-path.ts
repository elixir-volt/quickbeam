const sep = '/'
const delimiter = ':'

function isAbsolute(p: string): boolean {
  return p.startsWith('/')
}

function normalize(p: string): string {
  if (p === '') return '.'
  const absolute = isAbsolute(p)
  const parts = p.split('/')
  const stack: string[] = []
  for (const part of parts) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (stack.length > 0 && stack[stack.length - 1] !== '..') stack.pop()
      else if (!absolute) stack.push('..')
    } else {
      stack.push(part)
    }
  }
  let result = stack.join('/')
  if (absolute) result = '/' + result
  return result || (absolute ? '/' : '.')
}

function join(...parts: string[]): string {
  return normalize(parts.filter(Boolean).join('/'))
}

function resolve(...parts: string[]): string {
  let resolved = ''
  for (let i = parts.length - 1; i >= 0; i--) {
    const p = parts[i]
    if (!p) continue
    resolved = resolved ? p + '/' + resolved : p
    if (isAbsolute(p)) break
  }
  if (!isAbsolute(resolved)) {
    const cwd = (globalThis as Record<string, unknown>).process
      ? ((globalThis as Record<string, unknown>).process as { cwd(): string }).cwd()
      : '/'
    resolved = cwd + '/' + resolved
  }
  return normalize(resolved)
}

function basename(p: string, ext?: string): string {
  const parts = p.replace(/\/+$/, '').split('/')
  let base = parts[parts.length - 1] || ''
  if (ext && base.endsWith(ext)) base = base.slice(0, -ext.length)
  return base
}

function dirname(p: string): string {
  const parts = p.replace(/\/+$/, '').split('/')
  parts.pop()
  const result = parts.join('/')
  return result || (isAbsolute(p) ? '/' : '.')
}

function extname(p: string): string {
  const base = basename(p)
  const dot = base.lastIndexOf('.')
  if (dot <= 0) return ''
  return base.slice(dot)
}

interface ParsedPath {
  root: string
  dir: string
  base: string
  ext: string
  name: string
}

function parse(p: string): ParsedPath {
  const dir = dirname(p)
  const base = basename(p)
  const ext = extname(p)
  const name = ext ? base.slice(0, -ext.length) : base
  return { root: isAbsolute(p) ? '/' : '', dir, base, ext, name }
}

function format(obj: Partial<ParsedPath>): string {
  const dir = obj.dir || obj.root || ''
  const base = obj.base || (obj.name || '') + (obj.ext || '')
  return dir ? (dir === '/' ? dir + base : dir + '/' + base) : base
}

function relative(from: string, to: string): string {
  const fromParts = resolve(from).split('/').filter(Boolean)
  const toParts = resolve(to).split('/').filter(Boolean)
  let i = 0
  while (i < fromParts.length && i < toParts.length && fromParts[i] === toParts[i]) i++
  const ups = Array(fromParts.length - i).fill('..')
  return [...ups, ...toParts.slice(i)].join('/') || '.'
}

const path = {
  sep,
  delimiter,
  posix: null as unknown,
  win32: null as unknown,
  isAbsolute,
  normalize,
  join,
  resolve,
  basename,
  dirname,
  extname,
  parse,
  format,
  relative,
}

// Self-reference for Node.js compat
path.posix = path
path.win32 = path

;(globalThis as Record<string, unknown>).path = path
