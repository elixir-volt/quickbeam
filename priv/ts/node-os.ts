let qbOsPlatform: string | undefined
let qbOsArch: string | undefined
let qbOsHostname: string | undefined

const os = {
  EOL: '\n' as const,

  platform(): string {
    return (qbOsPlatform ??= Beam.callSync('__os_platform') as string)
  },

  arch(): string {
    return (qbOsArch ??= Beam.callSync('__os_arch') as string)
  },

  type(): string {
    const p = os.platform()
    switch (p) {
      case 'darwin': return 'Darwin'
      case 'linux': return 'Linux'
      case 'win32': return 'Windows_NT'
      case 'freebsd': return 'FreeBSD'
      default: return p
    }
  },

  release(): string {
    return Beam.callSync('__os_release') as string
  },

  hostname(): string {
    return (qbOsHostname ??= Beam.callSync('__os_hostname') as string)
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
