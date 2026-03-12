interface ExecSyncOptions {
  cwd?: string
  timeout?: number
  encoding?: string
  maxBuffer?: number
}

interface ExecResult {
  stdout: string
  status: number | null
  error?: string
}

function execSync(command: string, options?: ExecSyncOptions): string | Uint8Array {
  const result = Beam.callSync('__child_process_exec_sync', command, options || {}) as ExecResult

  if (result.error === 'ETIMEDOUT') {
    const err = new Error(`Command timed out: "${command}"`)
    ;(err as Record<string, unknown>).killed = true
    ;(err as Record<string, unknown>).code = 'ETIMEDOUT'
    throw err
  }

  if (result.status !== 0) {
    const err = new Error(`Command failed: ${command}\n${result.stdout}`)
    ;(err as Record<string, unknown>).status = result.status
    ;(err as Record<string, unknown>).stdout = result.stdout
    ;(err as Record<string, unknown>).stderr = ''
    throw err
  }

  return result.stdout
}

type ExecCallback = (error: Error | null, stdout: string, stderr: string) => void

function exec(command: string, optionsOrCallback?: ExecSyncOptions | ExecCallback, callback?: ExecCallback): void {
  const cb = typeof optionsOrCallback === 'function' ? optionsOrCallback : callback
  const opts = typeof optionsOrCallback === 'function' ? undefined : optionsOrCallback

  queueMicrotask(() => {
    try {
      const stdout = execSync(command, opts) as string
      if (cb) cb(null, stdout, '')
    } catch (err) {
      if (cb) {
        const e = err as Error & { stdout?: string }
        cb(e, e.stdout || '', '')
      }
    }
  })
}

const child_process = {
  execSync,
  exec,
}

;(globalThis as Record<string, unknown>).child_process = child_process
