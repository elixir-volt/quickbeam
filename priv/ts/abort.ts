import { QBEventTarget, QBEvent, QBDOMException } from "./event-target";

const SYM_ABORT = Symbol("abort");

export class QBAbortSignal extends QBEventTarget {
  #aborted = false;
  #reason: unknown = undefined;

  onabort: ((ev: QBEvent) => void) | null = null;

  get aborted(): boolean {
    return this.#aborted;
  }

  get reason(): unknown {
    return this.#reason;
  }

  throwIfAborted(): void {
    if (this.#aborted) throw this.#reason;
  }

  [SYM_ABORT](reason?: unknown): void {
    if (this.#aborted) return;
    this.#aborted = true;
    this.#reason = reason ?? new QBDOMException("The operation was aborted.", "AbortError");
    const event = new QBEvent("abort");
    this.onabort?.(event);
    this.dispatchEvent(event);
  }

  static timeout(ms: number): QBAbortSignal {
    const controller = new QBAbortController();
    setTimeout(
      () => controller.abort(new QBDOMException("The operation timed out.", "TimeoutError")),
      ms,
    );
    return controller.signal;
  }

  static abort(reason?: unknown): QBAbortSignal {
    const s = new QBAbortSignal();
    s[SYM_ABORT](reason);
    return s;
  }

  static any(signals: QBAbortSignal[]): QBAbortSignal {
    const controller = new QBAbortController();
    for (const s of signals) {
      if (s.aborted) {
        controller.abort(s.reason);
        return controller.signal;
      }
      s.addEventListener("abort", () => controller.abort(s.reason), { once: true });
    }
    return controller.signal;
  }
}

export class QBAbortController {
  #signal = new QBAbortSignal();

  get signal(): QBAbortSignal {
    return this.#signal;
  }

  abort(reason?: unknown): void {
    this.#signal[SYM_ABORT](reason);
  }
}

(globalThis as Record<string, unknown>).AbortSignal = QBAbortSignal;
(globalThis as Record<string, unknown>).AbortController = QBAbortController;
