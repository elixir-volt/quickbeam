export type QBHeadersInit = [string, string][] | Record<string, string> | QBHeaders;

export class QBHeaders {
  #map = new Map<string, string[]>();

  constructor(init?: QBHeadersInit) {
    if (init instanceof QBHeaders) {
      for (const [name, value] of init) this.append(name, value);
    } else if (Array.isArray(init)) {
      for (const pair of init) this.append(pair[0], pair[1]);
    } else if (init) {
      for (const key of Object.keys(init)) this.append(key, init[key]);
    }
  }

  append(name: string, value: string): void {
    const key = name.toLowerCase();
    const existing = this.#map.get(key);
    if (existing) {
      existing.push(value);
    } else {
      this.#map.set(key, [value]);
    }
  }

  get(name: string): string | null {
    const values = this.#map.get(name.toLowerCase());
    return values ? values.join(", ") : null;
  }

  getSetCookie(): string[] {
    return this.#map.get("set-cookie")?.slice() ?? [];
  }

  set(name: string, value: string): void {
    this.#map.set(name.toLowerCase(), [value]);
  }

  delete(name: string): void {
    this.#map.delete(name.toLowerCase());
  }

  has(name: string): boolean {
    return this.#map.has(name.toLowerCase());
  }

  forEach(
    callback: (value: string, name: string, parent: QBHeaders) => void,
    thisArg?: unknown,
  ): void {
    for (const [name, value] of this) {
      callback.call(thisArg, value, name, this);
    }
  }

  *entries(): IterableIterator<[string, string]> {
    const keys = [...this.#map.keys()].sort();
    for (const key of keys) {
      yield [key, this.#map.get(key)?.join(", ") ?? ""];
    }
  }

  *keys(): IterableIterator<string> {
    const keys = [...this.#map.keys()].sort();
    for (const key of keys) yield key;
  }

  *values(): IterableIterator<string> {
    const keys = [...this.#map.keys()].sort();
    for (const key of keys) yield this.#map.get(key)?.join(", ") ?? "";
  }

  [Symbol.iterator](): IterableIterator<[string, string]> {
    return this.entries();
  }
}

(globalThis as Record<string, unknown>).Headers = QBHeaders;
