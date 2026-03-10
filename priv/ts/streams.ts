export interface QBUnderlyingSource<R = unknown> {
  start?: (controller: QBReadableStreamController<R>) => void | Promise<void>;
  pull?: (controller: QBReadableStreamController<R>) => void | Promise<void>;
  cancel?: (reason?: unknown) => void | Promise<void>;
}

export interface QBReadableStreamController<R = unknown> {
  readonly desiredSize: number | null;
  enqueue(chunk: R): void;
  close(): void;
  error(e?: unknown): void;
}

export interface QBReadableStreamReadResult<R> {
  value: R;
  done: boolean;
}

type ReadableStreamState = "readable" | "closed" | "errored";

const SYM_READ = Symbol("read");
const SYM_RELEASE = Symbol("releaseLock");
const SYM_CANCEL = Symbol("cancel");

export class QBReadableStream<R = unknown> {
  #queue: R[] = [];
  #state: ReadableStreamState = "readable";
  #storedError: unknown = undefined;
  #source: QBUnderlyingSource<R> | undefined;
  #controller!: QBReadableStreamController<R>;
  #pulling = false;
  #waitingReaders: Array<{
    resolve: (result: QBReadableStreamReadResult<R>) => void;
    reject: (reason: unknown) => void;
  }> = [];
  #locked = false;

  constructor(source?: QBUnderlyingSource<R>) {
    this.#source = source;

    const controller: QBReadableStreamController<R> = {
      desiredSize: 1,
      enqueue: (chunk: R) => {
        if (this.#state !== "readable") return;

        if (this.#waitingReaders.length > 0) {
          const reader = this.#waitingReaders.shift();
          if (reader) reader.resolve({ value: chunk, done: false });
          return;
        }

        this.#queue.push(chunk);
      },
      close: () => {
        if (this.#state !== "readable") return;
        this.#state = "closed";

        for (const reader of this.#waitingReaders) {
          reader.resolve({ value: undefined as R, done: true });
        }
        this.#waitingReaders = [];
      },
      error: (e?: unknown) => {
        if (this.#state !== "readable") return;
        this.#state = "errored";
        this.#storedError = e;

        for (const reader of this.#waitingReaders) {
          reader.reject(e);
        }
        this.#waitingReaders = [];
        this.#queue = [];
      },
    };

    this.#controller = controller;

    try {
      const result = source?.start?.(controller);
      if (result instanceof Promise) {
        void result.catch((e: unknown) => controller.error(e));
      }
    } catch (e) {
      controller.error(e);
    }
  }

  get locked(): boolean {
    return this.#locked;
  }

  getReader(): QBReadableStreamDefaultReader<R> {
    if (this.#locked) throw new TypeError("ReadableStream is already locked");
    this.#locked = true;
    return new QBReadableStreamDefaultReader(this);
  }

  async cancel(reason?: unknown): Promise<void> {
    if (this.#locked) throw new TypeError("Cannot cancel a locked stream");
    await this.#source?.cancel?.(reason);
    this.#state = "closed";
    this.#queue = [];
  }

  [SYM_READ](): Promise<QBReadableStreamReadResult<R>> {
    if (this.#state === "errored") {
      return Promise.reject(this.#storedError);
    }

    if (this.#queue.length > 0) {
      const value = this.#queue.shift() as R;
      this.#callPull();
      return Promise.resolve({ value, done: false });
    }

    if (this.#state === "closed") {
      return Promise.resolve({ value: undefined as R, done: true });
    }

    this.#callPull();
    return new Promise<QBReadableStreamReadResult<R>>((resolve, reject) => {
      this.#waitingReaders.push({ resolve, reject });
    });
  }

  [SYM_RELEASE](): void {
    this.#locked = false;
  }

  [SYM_CANCEL](reason?: unknown): Promise<void> {
    const result = this.#source?.cancel?.(reason);
    return result instanceof Promise ? result : Promise.resolve();
  }

  #callPull(): void {
    if (this.#pulling || this.#state !== "readable" || !this.#source?.pull) return;
    this.#pulling = true;
    try {
      const result = this.#source.pull(this.#controller);
      if (result instanceof Promise) {
        void result
          .then(() => {
            this.#pulling = false;
          })
          .catch((e: unknown) => {
            this.#pulling = false;
            this.#controller.error(e);
          });
      } else {
        this.#pulling = false;
      }
    } catch (e) {
      this.#pulling = false;
      this.#controller.error(e);
    }
  }

  async *[Symbol.asyncIterator](): AsyncIterableIterator<R> {
    const reader = this.getReader();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        yield value;
      }
    } finally {
      reader.releaseLock();
    }
  }

  tee(): [QBReadableStream<R>, QBReadableStream<R>] {
    const reader = this.getReader();
    let cancelled1 = false;
    let cancelled2 = false;

    let ctrl2!: QBReadableStreamController<R>;

    const stream1 = new QBReadableStream<R>({
      pull(controller) {
        return reader.read().then(({ value, done }) => {
          if (done) {
            if (!cancelled1) controller.close();
            if (!cancelled2) ctrl2.close();
            return;
          }
          if (!cancelled1) controller.enqueue(value);
          if (!cancelled2) ctrl2.enqueue(value);
        });
      },
      cancel() {
        cancelled1 = true;
      },
    });

    const stream2 = new QBReadableStream<R>({
      start(controller) {
        ctrl2 = controller;
      },
      cancel() {
        cancelled2 = true;
      },
    });

    return [stream1, stream2];
  }

  static from<T>(iterable: Iterable<T> | AsyncIterable<T>): QBReadableStream<T> {
    return new QBReadableStream<T>({
      async start(controller) {
        for await (const chunk of iterable as AsyncIterable<T>) {
          controller.enqueue(chunk);
        }
        controller.close();
      },
    });
  }
}

export class QBReadableStreamDefaultReader<R = unknown> {
  #stream: QBReadableStream<R>;
  #closed: Promise<void>;
  #closedResolve!: () => void;

  constructor(stream: QBReadableStream<R>) {
    this.#stream = stream;
    this.#closed = new Promise<void>((resolve) => {
      this.#closedResolve = resolve;
    });
  }

  get closed(): Promise<void> {
    return this.#closed;
  }

  read(): Promise<QBReadableStreamReadResult<R>> {
    return this.#stream[SYM_READ]();
  }

  releaseLock(): void {
    this.#stream[SYM_RELEASE]();
    this.#closedResolve();
  }

  async cancel(reason?: unknown): Promise<void> {
    await this.#stream[SYM_CANCEL](reason);
    this.releaseLock();
  }
}

(globalThis as Record<string, unknown>).ReadableStream = QBReadableStream;
(globalThis as Record<string, unknown>).ReadableStreamDefaultReader = QBReadableStreamDefaultReader;
