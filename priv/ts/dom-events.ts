const targets = new WeakMap<object, EventTarget>()

function getTarget(obj: object): EventTarget {
  let t = targets.get(obj)
  if (!t) {
    t = new EventTarget()
    targets.set(obj, t)
  }
  return t
}

function addEventListener(
  this: object,
  type: string,
  callback: EventListenerOrEventListenerObject | null,
  options?: AddEventListenerOptions | boolean,
): void {
  getTarget(this).addEventListener(type, callback, options)
}

function removeEventListener(
  this: object,
  type: string,
  callback: EventListenerOrEventListenerObject | null,
  options?: EventListenerOptions | boolean,
): void {
  getTarget(this).removeEventListener(type, callback, options)
}

function dispatchEvent(this: object, event: Event): boolean {
  Object.defineProperty(event, 'target', { value: this, writable: true, configurable: true })
  Object.defineProperty(event, 'currentTarget', { value: this, writable: true, configurable: true })
  return getTarget(this).dispatchEvent(event)
}

class CustomEvent extends Event {
  readonly detail: unknown

  constructor(type: string, init?: CustomEventInit) {
    super(type, init)
    this.detail = init?.detail ?? null
  }
}

;(globalThis as Record<string, unknown>).CustomEvent = CustomEvent
;(globalThis as Record<string, unknown>).__qb_addEventListener = addEventListener
;(globalThis as Record<string, unknown>).__qb_removeEventListener = removeEventListener
;(globalThis as Record<string, unknown>).__qb_dispatchEvent = dispatchEvent
