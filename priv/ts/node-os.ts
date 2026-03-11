let _platform: string | undefined
let _arch: string | undefined
let _hostname: string | undefined

const os = {
  EOL: '\n' as const,

  platform(): string {
    return (_platform ??= Beam.callSync('__os_platform') as string)
  },

  arch(): string {
    return (_arch ??= Beam.callSync('__os_arch') as string)
  },

  type(): string {
    const p = os.platform()
    switch (p) {
      case 'darwin': return 'Darwin'
      case 'linux': return 'Linux'
      case 'win32': return 'Windows_NT'
      case 'freebsd': return 'FreeBSD'
      default: return _platform
    }
  },

  release(): string {
    return Beam.callSync('__os_release') as string
  },

  hostname(): string {
    return (_hostname ??= Beam.callSync('__os_hostname') as string)
  },

  homedir(): string {
    return Beam.callSync('__os_homedir') as string
  },

  tmpdir(): string {
    return Beam.callSync('__os_tmpdir') as string
  },

  cpus(): Array<{ model: string; speed: number }> {
    const count = Beam.callSync('__os_cpu_count') as number
    return Array.from({ length: count }, () => ({ model: 'unknown', speed: 0 }))
  },

  totalmem(): number {
    return Beam.callSync('__os_totalmem') as number
  },

  freemem(): number {
    return Beam.callSync('__os_freemem') as number
  },

  uptime(): number {
    return Beam.callSync('__os_uptime') as number
  },

  networkInterfaces(): Record<string, unknown[]> {
    return {}
  },

  endianness(): 'BE' | 'LE' {
    return 'LE'
  },
}

;(globalThis as Record<string, unknown>).os = os
