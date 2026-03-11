class DOMTokenList {
  #element: Element

  constructor(element: Element) {
    this.#element = element
  }

  #getClasses(): string[] {
    const raw = this.#element.getAttribute('class')
    if (!raw) return []
    return raw.split(/\s+/).filter(Boolean)
  }

  #setClasses(classes: string[]): void {
    if (classes.length === 0) {
      this.#element.removeAttribute('class')
    } else {
      this.#element.setAttribute('class', classes.join(' '))
    }
  }

  get length(): number {
    return this.#getClasses().length
  }

  get value(): string {
    return this.#element.getAttribute('class') ?? ''
  }

  set value(v: string) {
    this.#element.setAttribute('class', v)
  }

  item(index: number): string | null {
    return this.#getClasses()[index] ?? null
  }

  contains(token: string): boolean {
    return this.#getClasses().includes(token)
  }

  add(...tokens: string[]): void {
    const classes = this.#getClasses()
    for (const token of tokens) {
      if (token && !classes.includes(token)) {
        classes.push(token)
      }
    }
    this.#setClasses(classes)
  }

  remove(...tokens: string[]): void {
    const classes = this.#getClasses().filter(c => !tokens.includes(c))
    this.#setClasses(classes)
  }

  toggle(token: string, force?: boolean): boolean {
    const has = this.contains(token)
    if (force !== undefined) {
      if (force) {
        this.add(token)
        return true
      } else {
        this.remove(token)
        return false
      }
    }
    if (has) {
      this.remove(token)
      return false
    } else {
      this.add(token)
      return true
    }
  }

  replace(oldToken: string, newToken: string): boolean {
    const classes = this.#getClasses()
    const idx = classes.indexOf(oldToken)
    if (idx === -1) return false
    classes[idx] = newToken
    this.#setClasses(classes)
    return true
  }

  forEach(callback: (value: string, index: number, list: DOMTokenList) => void): void {
    this.#getClasses().forEach((value, index) => callback(value, index, this))
  }

  toString(): string {
    return this.value
  }

  *[Symbol.iterator](): IterableIterator<string> {
    yield* this.#getClasses()
  }
}

;(globalThis as Record<string, unknown>).DOMTokenList = DOMTokenList

const origCreateElement = document.createElement.bind(document)
const elementCache = new WeakMap<Element, DOMTokenList>()

function getClassList(el: Element): DOMTokenList {
  let list = elementCache.get(el)
  if (!list) {
    list = new DOMTokenList(el)
    elementCache.set(el, list)
  }
  return list
}

;(globalThis as Record<string, unknown>).__qb_get_class_list = getClassList
