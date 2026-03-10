import { QBEventTarget, QBMessageEvent, QBDOMException } from "./event-target";

const SYM_RECEIVE = Symbol("receive");

const channelRegistry = new Map<string, Set<QBBroadcastChannel>>();

function registerChannel(ch: QBBroadcastChannel): void {
  let set = channelRegistry.get(ch.name);
  if (!set) {
    set = new Set();
    channelRegistry.set(ch.name, set);
  }
  set.add(ch);
}

function unregisterChannel(ch: QBBroadcastChannel): void {
  const set = channelRegistry.get(ch.name);
  if (set) {
    set.delete(ch);
    if (set.size === 0) channelRegistry.delete(ch.name);
  }
}

class QBBroadcastChannel extends QBEventTarget {
  readonly name: string;
  #closed = false;

  onmessage: ((ev: QBMessageEvent) => void) | null = null;
  onmessageerror: ((ev: QBMessageEvent) => void) | null = null;

  constructor(name: string) {
    super();
    this.name = name;
    registerChannel(this);
    beam.callSync("__broadcast_join", name);
  }

  postMessage(message: unknown): void {
    if (this.#closed) throw new QBDOMException("BroadcastChannel is closed", "InvalidStateError");
    void beam.call("__broadcast_post", this.name, structuredClone(message));
  }

  close(): void {
    if (this.#closed) return;
    this.#closed = true;
    unregisterChannel(this);
    beam.callSync("__broadcast_leave", this.name);
  }

  [SYM_RECEIVE](data: unknown): void {
    if (this.#closed) return;
    const event = new QBMessageEvent("message", { data });
    this.onmessage?.(event);
    this.dispatchEvent(event);
  }
}

(globalThis as Record<string, unknown>).BroadcastChannel = QBBroadcastChannel;
(globalThis as Record<string, unknown>).__qb_broadcast_dispatch = (
  channel: string,
  data: unknown,
) => {
  const set = channelRegistry.get(channel);
  if (!set) return;
  for (const ch of set) ch[SYM_RECEIVE](data);
};
