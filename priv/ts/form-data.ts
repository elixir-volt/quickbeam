import { File, SYM_BYTES } from './blob'

import type { Blob } from './blob'

type FormDataEntryValue = string | File

interface FormDataEntry {
  name: string
  value: FormDataEntryValue
}

function normalizeValue(value: string | Blob, filename?: string): FormDataEntryValue {
  if (typeof value === 'string') return value
  if (value instanceof File) {
    return filename !== undefined
      ? new File([value[SYM_BYTES]().slice()], filename, { type: value.type, lastModified: value.lastModified })
      : value
  }
  return new File([value[SYM_BYTES]().slice()], filename ?? 'blob', { type: value.type })
}

export class FormData {
  #entries: FormDataEntry[] = []

  append(name: string, value: string | Blob, filename?: string): void {
    this.#entries.push({ name, value: normalizeValue(value, filename) })
  }

  set(name: string, value: string | Blob, filename?: string): void {
    const normalized = normalizeValue(value, filename)
    let found = false
    let i = 0
    while (i < this.#entries.length) {
      if (this.#entries[i].name === name) {
        if (!found) {
          this.#entries[i] = { name, value: normalized }
          found = true
          i++
        } else {
          this.#entries.splice(i, 1)
        }
      } else {
        i++
      }
    }
    if (!found) this.#entries.push({ name, value: normalized })
  }

  get(name: string): FormDataEntryValue | null {
    for (const entry of this.#entries) {
      if (entry.name === name) return entry.value
    }
    return null
  }

  getAll(name: string): FormDataEntryValue[] {
    const result: FormDataEntryValue[] = []
    for (const entry of this.#entries) {
      if (entry.name === name) result.push(entry.value)
    }
    return result
  }

  has(name: string): boolean {
    for (const entry of this.#entries) {
      if (entry.name === name) return true
    }
    return false
  }

  delete(name: string): void {
    let i = 0
    while (i < this.#entries.length) {
      if (this.#entries[i].name === name) {
        this.#entries.splice(i, 1)
      } else {
        i++
      }
    }
  }

  forEach(
    callback: (value: FormDataEntryValue, name: string, parent: FormData) => void,
    thisArg?: unknown
  ): void {
    for (const entry of this.#entries) {
      callback.call(thisArg, entry.value, entry.name, this)
    }
  }

  *entries(): IterableIterator<[string, FormDataEntryValue]> {
    for (const entry of this.#entries) {
      yield [entry.name, entry.value]
    }
  }

  *keys(): IterableIterator<string> {
    for (const entry of this.#entries) {
      yield entry.name
    }
  }

  *values(): IterableIterator<FormDataEntryValue> {
    for (const entry of this.#entries) {
      yield entry.value
    }
  }

  [Symbol.iterator](): IterableIterator<[string, FormDataEntryValue]> {
    return this.entries()
  }
}
