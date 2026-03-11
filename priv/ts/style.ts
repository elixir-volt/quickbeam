declare function __qb_css_get_property(style: string, name: string): string
declare function __qb_css_get_priority(style: string, name: string): string
declare function __qb_css_serialize(style: string): string

const CAMEL_RE = /[A-Z]/g
const KEBAB_RE = /-([a-z])/g

function toKebab(name: string): string {
  if (name.startsWith('--')) return name
  return name.replace(CAMEL_RE, m => '-' + m.toLowerCase())
}

const OWN_KEYS = new Set([
  'cssText', 'length', 'getPropertyValue', 'getPropertyPriority',
  'setProperty', 'removeProperty', 'item',
])

function createStyleProxy(element: Element): Record<string, unknown> {
  function raw(): string {
    return element.getAttribute('style') ?? ''
  }

  function removeFromRaw(rawStr: string, kebab: string): string {
    return rawStr
      .split(';')
      .map(s => s.trim())
      .filter(s => {
        if (!s) return false
        const colon = s.indexOf(':')
        if (colon === -1) return false
        return s.slice(0, colon).trim() !== kebab
      })
      .join('; ')
  }

  const decl = {
    get cssText(): string {
      const r = raw()
      if (!r) return ''
      return __qb_css_serialize(r)
    },
    set cssText(value: string) {
      if (value) {
        element.setAttribute('style', value)
      } else {
        element.removeAttribute('style')
      }
    },

    getPropertyValue(name: string): string {
      const r = raw()
      if (!r) return ''
      return __qb_css_get_property(r, toKebab(name))
    },

    getPropertyPriority(name: string): string {
      const r = raw()
      if (!r) return ''
      return __qb_css_get_priority(r, toKebab(name))
    },

    setProperty(name: string, value: string | null, priority?: string): void {
      const kebab = toKebab(name)
      if (value === null || value === undefined || value === '') {
        decl.removeProperty(name)
        return
      }
      const d = priority === 'important'
        ? `${kebab}: ${value} !important`
        : `${kebab}: ${value}`

      const r = raw()
      const existing = r ? removeFromRaw(r, kebab) : ''
      const updated = existing ? `${existing}; ${d}` : d
      element.setAttribute('style', updated)
    },

    removeProperty(name: string): string {
      const kebab = toKebab(name)
      const r = raw()
      if (!r) return ''
      const old = __qb_css_get_property(r, kebab)
      const updated = removeFromRaw(r, kebab)
      if (updated) {
        element.setAttribute('style', updated)
      } else {
        element.removeAttribute('style')
      }
      return old
    },

    get length(): number {
      const r = raw()
      if (!r) return 0
      return r.split(';').filter(s => s.trim() && s.includes(':')).length
    },

    item(index: number): string {
      const r = raw()
      if (!r) return ''
      const items = r.split(';').filter(s => s.trim() && s.includes(':'))
      const entry = items[index]
      if (!entry) return ''
      return entry.slice(0, entry.indexOf(':')).trim()
    },
  }

  return new Proxy(decl as unknown as Record<string, unknown>, {
    get(target, prop) {
      if (typeof prop === 'string' && !OWN_KEYS.has(prop) && prop !== 'toString'
          && prop !== 'valueOf' && prop !== 'constructor' && prop !== 'toJSON') {
        return decl.getPropertyValue(prop)
      }
      return (target as Record<string | symbol, unknown>)[prop]
    },
    set(target, prop, value) {
      if (typeof prop === 'string' && !OWN_KEYS.has(prop)) {
        decl.setProperty(prop, value)
        return true
      }
      (target as Record<string | symbol, unknown>)[prop] = value
      return true
    },
  })
}

;(globalThis as Record<string, unknown>).CSSStyleDeclaration = Object

const styleCache = new WeakMap<Element, Record<string, unknown>>()

function getStyle(el: Element): Record<string, unknown> {
  let s = styleCache.get(el)
  if (!s) {
    s = createStyleProxy(el)
    styleCache.set(el, s)
  }
  return s
}

;(globalThis as Record<string, unknown>).__qb_get_style = getStyle
;(globalThis as Record<string, unknown>).getComputedStyle = (el: Element) => getStyle(el)
