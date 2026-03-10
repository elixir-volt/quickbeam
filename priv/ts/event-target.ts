import type { QBAbortSignal } from "./abort";

export type QBEventListener = (event: QBEvent) => void;
interface QBEventListenerObject {
  handleEvent(event: QBEvent): void;
}
export type QBEventListenerOrObject = QBEventListener | QBEventListenerObject;

export interface QBAddEventListenerOptions {
  once?: boolean;
  signal?: QBAbortSignal;
}

export const SYM_STOP_IMMEDIATE = Symbol("stopImmediate");

export class QBEvent {
  readonly type: string;
  readonly timeStamp: number;
  cancelBubble = false;
  #stopImmediatePropagationFlag = false;
  #defaultPrevented = false;

  constructor(type: string) {
    this.type = type;
    this.timeStamp = performance.now();
  }

  get defaultPrevented(): boolean {
    return this.#defaultPrevented;
  }

  preventDefault(): void {
    this.#defaultPrevented = true;
  }

  stopPropagation(): void {
    this.cancelBubble = true;
  }

  stopImmediatePropagation(): void {
    this.#stopImmediatePropagationFlag = true;
    this.cancelBubble = true;
  }

  get [SYM_STOP_IMMEDIATE](): boolean {
    return this.#stopImmediatePropagationFlag;
  }
}

export class QBMessageEvent extends QBEvent {
  readonly data: unknown;
  readonly origin: string;
  readonly lastEventId: string;

  constructor(type: string, init?: { data?: unknown; origin?: string; lastEventId?: string }) {
    super(type);
    this.data = init?.data;
    this.origin = init?.origin ?? "";
    this.lastEventId = init?.lastEventId ?? "";
  }
}

export class QBCloseEvent extends QBEvent {
  readonly code: number;
  readonly reason: string;
  readonly wasClean: boolean;

  constructor(type: string, init?: { code?: number; reason?: string; wasClean?: boolean }) {
    super(type);
    this.code = init?.code ?? 0;
    this.reason = init?.reason ?? "";
    this.wasClean = init?.wasClean ?? false;
  }
}

export class QBErrorEvent extends QBEvent {
  readonly message: string;
  readonly error: unknown;

  constructor(type: string, init?: { message?: string; error?: unknown }) {
    super(type);
    this.message = init?.message ?? "";
    this.error = init?.error;
  }
}

interface QBListenerEntry {
  callback: QBEventListenerOrObject;
  once: boolean;
  signal?: QBAbortSignal;
  _removed?: boolean;
}

export class QBEventTarget {
  #listeners = new Map<string, QBListenerEntry[]>();

  addEventListener(
    type: string,
    callback: QBEventListenerOrObject | null,
    options?: QBAddEventListenerOptions | boolean,
  ): void {
    if (callback === null) return;

    const once = typeof options === "object" ? (options.once ?? false) : false;
    const signal = typeof options === "object" ? options.signal : undefined;

    const list = this.#listeners.get(type);
    if (list) {
      for (const entry of list) {
        if (entry.callback === callback) return;
      }
    }

    const entry: QBListenerEntry = { callback, once, signal };

    if (signal?.aborted) return;
    signal?.addEventListener("abort", () => {
      this.removeEventListener(type, callback);
    });

    if (list) {
      list.push(entry);
    } else {
      this.#listeners.set(type, [entry]);
    }
  }

  removeEventListener(type: string, callback: QBEventListenerOrObject | null): void {
    if (callback === null) return;
    const list = this.#listeners.get(type);
    if (!list) return;

    for (let i = 0; i < list.length; i++) {
      if (list[i].callback === callback) {
        list[i]._removed = true;
        list.splice(i, 1);
        break;
      }
    }
    if (list.length === 0) this.#listeners.delete(type);
  }

  dispatchEvent(event: QBEvent): boolean {
    const list = this.#listeners.get(event.type);
    if (!list) return !event.defaultPrevented;

    const snapshot = list.slice();
    for (const entry of snapshot) {
      if (entry._removed) continue;
      if (event[SYM_STOP_IMMEDIATE]) break;

      if (typeof entry.callback === "function") {
        entry.callback(event);
      } else {
        entry.callback.handleEvent(event);
      }

      if (entry.once) {
        this.removeEventListener(event.type, entry.callback);
      }
    }

    return !event.defaultPrevented;
  }
}

export class QBDOMException extends Error {
  readonly code: number;

  constructor(message = "", name = "Error") {
    super(message);
    this.name = name;
    this.code = 0;
  }
}

(globalThis as Record<string, unknown>).Event = QBEvent;
(globalThis as Record<string, unknown>).MessageEvent = QBMessageEvent;
(globalThis as Record<string, unknown>).CloseEvent = QBCloseEvent;
(globalThis as Record<string, unknown>).ErrorEvent = QBErrorEvent;
(globalThis as Record<string, unknown>).EventTarget = QBEventTarget;
(globalThis as Record<string, unknown>).DOMException = QBDOMException;
