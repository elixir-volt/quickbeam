class WebStorage {
  getItem(key: string): string | null {
    return Beam.callSync('__storage_get', String(key)) as string | null
  }

  setItem(key: string, value: string): void {
    Beam.callSync('__storage_set', String(key), String(value))
  }

  removeItem(key: string): void {
    Beam.callSync('__storage_remove', String(key))
  }

  clear(): void {
    Beam.callSync('__storage_clear')
  }

  key(index: number): string | null {
    return Beam.callSync('__storage_key', index) as string | null
  }

  get length(): number {
    return Beam.callSync('__storage_length') as number
  }
}

;(globalThis as Record<string, unknown>).localStorage = new WebStorage()
