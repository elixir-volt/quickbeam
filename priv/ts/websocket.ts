import {
  QBEventTarget,
  QBEvent,
  QBMessageEvent,
  QBCloseEvent,
  QBDOMException,
} from "./event-target";
import { QBBlob, SYM_BYTES } from "./blob";

const SYM_HANDLE_EVENT = Symbol("handleEvent");

class QBWebSocket extends QBEventTarget {
  static readonly CONNECTING = 0;
  static readonly OPEN = 1;
  static readonly CLOSING = 2;
  static readonly CLOSED = 3;

  readonly CONNECTING = 0;
  readonly OPEN = 1;
  readonly CLOSING = 2;
  readonly CLOSED = 3;

  readonly url: string;
  readonly extensions = "";
  #readyState = QBWebSocket.CONNECTING;
  #protocol = "";
  #binaryType: BinaryType = "blob";
  #bufferedAmount = 0;
  #id: string;

  onopen: ((ev: QBEvent) => void) | null = null;
  onmessage: ((ev: QBMessageEvent) => void) | null = null;
  onclose: ((ev: QBCloseEvent) => void) | null = null;
  onerror: ((ev: QBEvent) => void) | null = null;

  constructor(url: string, protocols?: string | string[]) {
    super();
    this.url = url;

    const protoArray =
      protocols === undefined ? [] : (typeof protocols === "string" ? [protocols] : protocols);
    this.#id = beam.callSync("__ws_connect", url, protoArray) as string;
  }

  get readyState(): number {
    return this.#readyState;
  }

  get protocol(): string {
    return this.#protocol;
  }

  get binaryType(): BinaryType {
    return this.#binaryType;
  }

  set binaryType(value: BinaryType) {
    this.#binaryType = value;
  }

  get bufferedAmount(): number {
    return this.#bufferedAmount;
  }

  send(data: string | ArrayBuffer | Uint8Array | QBBlob): void {
    if (this.#readyState === QBWebSocket.CONNECTING) {
      throw new QBDOMException(
        "WebSocket is not open: readyState 0 (CONNECTING)",
        "InvalidStateError",
      );
    }
    if (this.#readyState !== QBWebSocket.OPEN) return;

    let payload: string | Uint8Array;
    if (typeof data === "string") {
      payload = data;
    } else if (data instanceof Uint8Array) {
      payload = data;
    } else if (data instanceof ArrayBuffer) {
      payload = new Uint8Array(data);
    } else if (data instanceof QBBlob) {
      payload = data[SYM_BYTES]();
    } else {
      payload = JSON.stringify(data);
    }

    void beam.call("__ws_send", this.#id, payload);
  }

  close(code?: number, reason?: string): void {
    if (this.#readyState === QBWebSocket.CLOSING || this.#readyState === QBWebSocket.CLOSED) return;

    if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) {
      throw new QBDOMException(
        `The code must be either 1000, or between 3000 and 4999. ${code} is neither.`,
        "InvalidAccessError",
      );
    }

    this.#readyState = QBWebSocket.CLOSING;
    void beam.call("__ws_close", this.#id, code ?? 1000, reason ?? "");
  }

  [SYM_HANDLE_EVENT](
    type: string,
    detail?: {
      data?: unknown;
      code?: number;
      reason?: string;
      protocol?: string;
      wasClean?: boolean;
    },
  ): void {
    switch (type) {
      case "open":
        this.#readyState = QBWebSocket.OPEN;
        this.#protocol = detail?.protocol ?? "";
        {
          const ev = new QBEvent("open");
          this.onopen?.(ev);
          this.dispatchEvent(ev);
        }
        break;

      case "message": {
        let messageData: unknown = detail?.data;
        if (this.#binaryType === "arraybuffer" && messageData instanceof Uint8Array) {
          messageData = messageData.buffer;
        }
        const ev = new QBMessageEvent("message", { data: messageData });
        this.onmessage?.(ev);
        this.dispatchEvent(ev);
        break;
      }

      case "close": {
        this.#readyState = QBWebSocket.CLOSED;
        const ev = new QBCloseEvent("close", {
          code: detail?.code ?? 1006,
          reason: detail?.reason ?? "",
          wasClean: detail?.wasClean ?? false,
        });
        this.onclose?.(ev);
        this.dispatchEvent(ev);
        break;
      }

      case "error": {
        const ev = new QBEvent("error");
        this.onerror?.(ev);
        this.dispatchEvent(ev);
        break;
      }
    }
  }
}

(globalThis as Record<string, unknown>).WebSocket = QBWebSocket;
