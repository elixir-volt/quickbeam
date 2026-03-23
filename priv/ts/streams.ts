import { AbortController } from './abort'

import type { AbortSignal } from './abort'

export interface UnderlyingSource<R = unknown> {
  start?: (controller: ReadableStreamController<R>) => void | Promise<void>
  pull?: (controller: ReadableStreamController<R>) => void | Promise<void>
  cancel?: (reason?: unknown) => void | Promise<void>
}

function handleControllerStart<C>(
  start: ((controller: C) => void | Promise<void>) | undefined,
  controller: C,
  onError: (error: unknown) => void,
): void {
  try {
    const result = start?.(controller)
    if (result instanceof Promise) {
      void result.catch((error: unknown) => onError(error))
    }
  } catch (error) {
    onError(error)
  }
}

export interface ReadableStreamController<R = unknown> {
  readonly desiredSize: number | null
  enqueue(chunk: R): void
  close(): void
  error(e?: unknown): void
}

export interface ReadableStreamReadResult<R> {
  value: R
  done: boolean
}

type ReadableStreamState = 'readable' | 'closed' | 'errored'

const SYM_READ = Symbol('read')
const SYM_RELEASE = Symbol('releaseLock')
const SYM_CANCEL = Symbol('cancel')

export class ReadableStream<R = unknown> {
  #queue: R[] = []
  #state: ReadableStreamState = 'readable'
  #storedError: unknown = undefined
  #source: UnderlyingSource<R> | undefined
  #controller!: ReadableStreamController<R>
  #pulling = false
  #waitingReaders: Array<{
    resolve: (result: ReadableStreamReadResult<R>) => void
    reject: (reason: unknown) => void
  }> = []
  #locked = false

  constructor(source?: UnderlyingSource<R>) {
    this.#source = source

    const controller: ReadableStreamController<R> = {
      desiredSize: 1,
      enqueue: (chunk: R) => {
        if (this.#state !== 'readable') return
        if (this.#waitingReaders.length > 0) {
          const reader = this.#waitingReaders.shift()
          if (reader) reader.resolve({ value: chunk, done: false })
          return
        }
        this.#queue.push(chunk)
      },
      close: () => {
        if (this.#state !== 'readable') return
        this.#state = 'closed'
        for (const reader of this.#waitingReaders) {
          reader.resolve({ value: undefined as R, done: true })
        }
        this.#waitingReaders = []
      },
      error: (e?: unknown) => {
        if (this.#state !== 'readable') return
        this.#state = 'errored'
        this.#storedError = e
        for (const reader of this.#waitingReaders) {
          reader.reject(e)
        }
        this.#waitingReaders = []
        this.#queue = []
      }
    }

    this.#controller = controller

    handleControllerStart(source?.start, controller, (error) => controller.error(error))
  }

  get locked(): boolean {
    return this.#locked
  }

  getReader(): ReadableStreamDefaultReader<R> {
    if (this.#locked) throw new TypeError('ReadableStream is already locked')
    this.#locked = true
    return new ReadableStreamDefaultReader(this)
  }

  async cancel(reason?: unknown): Promise<void> {
    if (this.#locked) throw new TypeError('Cannot cancel a locked stream')
    await this.#source?.cancel?.(reason)
    this.#state = 'closed'
    this.#queue = []
  }

  pipeThrough<T>(transform: {
    writable: WritableStream
    readable: ReadableStream<T>
  }): ReadableStream<T> {
    void this.pipeTo(transform.writable)
    return transform.readable
  }

  async pipeTo(dest: WritableStream): Promise<void> {
    const reader = this.getReader()
    const writer = dest.getWriter()
    try {
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        await writer.write(value)
      }
      await writer.close()
    } catch (e) {
      await writer.abort(e)
    } finally {
      reader.releaseLock()
    }
  }

  tee(): [ReadableStream<R>, ReadableStream<R>] {
    const reader = this.getReader()
    let cancelled1 = false
    let cancelled2 = false
    let ctrl2!: ReadableStreamController<R>

    const stream1 = new ReadableStream<R>({
      pull(controller) {
        return reader.read().then(({ value, done }) => {
          if (done) {
            if (!cancelled1) controller.close()
            if (!cancelled2) ctrl2.close()
            return
          }
          if (!cancelled1) controller.enqueue(value)
          if (!cancelled2) ctrl2.enqueue(value)
        })
      },
      cancel() {
        cancelled1 = true
      }
    })

    const stream2 = new ReadableStream<R>({
      start(controller) {
        ctrl2 = controller
      },
      cancel() {
        cancelled2 = true
      }
    })

    return [stream1, stream2]
  }

  static from<T>(iterable: Iterable<T> | AsyncIterable<T>): ReadableStream<T> {
    return new ReadableStream<T>({
      async start(controller) {
        for await (const chunk of iterable as AsyncIterable<T>) {
          controller.enqueue(chunk)
        }
        controller.close()
      }
    })
  }

  [SYM_READ](): Promise<ReadableStreamReadResult<R>> {
    if (this.#state === 'errored') return Promise.reject(this.#storedError)
    if (this.#queue.length > 0) {
      const value = this.#queue.shift() as R
      this.#callPull()
      return Promise.resolve({ value, done: false })
    }
    if (this.#state === 'closed') {
      return Promise.resolve({ value: undefined as R, done: true })
    }
    this.#callPull()
    return new Promise<ReadableStreamReadResult<R>>((resolve, reject) => {
      this.#waitingReaders.push({ resolve, reject })
    })
  }

  [SYM_RELEASE](): void {
    this.#locked = false
  }

  [SYM_CANCEL](reason?: unknown): Promise<void> {
    const result = this.#source?.cancel?.(reason)
    return result instanceof Promise ? result : Promise.resolve()
  }

  #callPull(): void {
    if (this.#pulling || this.#state !== 'readable' || !this.#source?.pull) return
    this.#pulling = true
    try {
      const result = this.#source.pull(this.#controller)
      if (result instanceof Promise) {
        void result
          .then(() => {
            this.#pulling = false
          })
          .catch((e: unknown) => {
            this.#pulling = false
            this.#controller.error(e)
          })
      } else {
        this.#pulling = false
      }
    } catch (e) {
      this.#pulling = false
      this.#controller.error(e)
    }
  }

  async *[Symbol.asyncIterator](): AsyncIterableIterator<R> {
    const reader = this.getReader()
    try {
      for (;;) {
        const { value, done } = await reader.read()
        if (done) break
        yield value
      }
    } finally {
      reader.releaseLock()
    }
  }
}

export class ReadableStreamDefaultReader<R = unknown> {
  #stream: ReadableStream<R>
  #closed: Promise<void>
  #closedResolve!: () => void

  constructor(stream: ReadableStream<R>) {
    this.#stream = stream
    this.#closed = new Promise<void>((resolve) => {
      this.#closedResolve = resolve
    })
  }

  get closed(): Promise<void> {
    return this.#closed
  }

  read(): Promise<ReadableStreamReadResult<R>> {
    return this.#stream[SYM_READ]()
  }

  releaseLock(): void {
    this.#stream[SYM_RELEASE]()
    this.#closedResolve()
  }

  async cancel(reason?: unknown): Promise<void> {
    await this.#stream[SYM_CANCEL](reason)
    this.releaseLock()
  }
}

// ──────────────────── WritableStream ────────────────────

interface UnderlyingSink<W = unknown> {
  start?: (controller: WritableStreamDefaultController) => void | Promise<void>
  write?: (chunk: W, controller: WritableStreamDefaultController) => void | Promise<void>
  close?: () => void | Promise<void>
  abort?: (reason?: unknown) => void | Promise<void>
}

interface WritableStreamDefaultController {
  readonly signal: AbortSignal
  error(e?: unknown): void
}

type WritableStreamState = 'writable' | 'erroring' | 'closed' | 'errored'

export class WritableStream<W = unknown> {
  #sink: UnderlyingSink<W> | undefined
  #state: WritableStreamState = 'writable'
  #storedError: unknown = undefined
  #locked = false
  #controller!: WritableStreamDefaultController
  #closeResolve?: () => void
  #closeReject?: (reason: unknown) => void
  #abortController = new AbortController()

  constructor(sink?: UnderlyingSink<W>) {
    this.#sink = sink

    const ac = this.#abortController
    const controller: WritableStreamDefaultController = {
      get signal() {
        return ac.signal
      },
      error: (e?: unknown) => {
        if (this.#state !== 'writable') return
        this.#state = 'errored'
        this.#storedError = e
        this.#closeReject?.(e)
      }
    }
    this.#controller = controller

    handleControllerStart(sink?.start, controller, (error) => controller.error(error))
  }

  get locked(): boolean {
    return this.#locked
  }

  async abort(reason?: unknown): Promise<void> {
    if (this.#locked) throw new TypeError('Cannot abort a locked stream')
    this.#abortController.abort(reason)
    await this.#sink?.abort?.(reason)
    this.#state = 'errored'
    this.#storedError = reason
  }

  async close(): Promise<void> {
    if (this.#locked) throw new TypeError('Cannot close a locked stream')
    if (this.#state !== 'writable') throw new TypeError('Stream is not writable')
    await this.#sink?.close?.()
    this.#state = 'closed'
  }

  getWriter(): WritableStreamDefaultWriter<W> {
    if (this.#locked) throw new TypeError('WritableStream is already locked')
    this.#locked = true
    return new WritableStreamDefaultWriter(this)
  }

  _write(chunk: W): Promise<void> {
    if (this.#state !== 'writable') {
      return Promise.reject(this.#storedError ?? new TypeError('Stream is not writable'))
    }
    const r = this.#sink?.write?.(chunk, this.#controller)
    return r instanceof Promise ? r : Promise.resolve()
  }

  async _close(): Promise<void> {
    if (this.#state !== 'writable') return
    await this.#sink?.close?.()
    this.#state = 'closed'
    this.#closeResolve?.()
  }

  async _abort(reason?: unknown): Promise<void> {
    this.#abortController.abort(reason)
    await this.#sink?.abort?.(reason)
    this.#state = 'errored'
    this.#storedError = reason
    this.#closeReject?.(reason)
  }

  _releaseLock(): void {
    this.#locked = false
  }

  _closed(): Promise<void> {
    if (this.#state === 'closed') return Promise.resolve()
    if (this.#state === 'errored') return Promise.reject(this.#storedError)
    return new Promise<void>((resolve, reject) => {
      this.#closeResolve = resolve
      this.#closeReject = reject
    })
  }

  _desiredSize(): number | null {
    return this.#state === 'writable' ? 1 : 0
  }

  _ready(): Promise<void> {
    return this.#state === 'writable' ? Promise.resolve() : Promise.reject(this.#storedError)
  }
}

export class WritableStreamDefaultWriter<W = unknown> {
  #stream: WritableStream<W>
  #closedPromise: Promise<void>

  constructor(stream: WritableStream<W>) {
    this.#stream = stream
    this.#closedPromise = stream._closed()
  }

  get closed(): Promise<void> {
    return this.#closedPromise
  }
  get desiredSize(): number | null {
    return this.#stream._desiredSize()
  }
  get ready(): Promise<void> {
    return this.#stream._ready()
  }

  async write(chunk: W): Promise<void> {
    await this.#stream._write(chunk)
  }

  async close(): Promise<void> {
    await this.#stream._close()
    this.releaseLock()
  }

  async abort(reason?: unknown): Promise<void> {
    await this.#stream._abort(reason)
    this.releaseLock()
  }

  releaseLock(): void {
    this.#stream._releaseLock()
  }
}

// ──────────────────── TransformStream ────────────────────

interface Transformer<I = unknown, O = unknown> {
  start?: (controller: TransformStreamDefaultController<O>) => void | Promise<void>
  transform?: (chunk: I, controller: TransformStreamDefaultController<O>) => void | Promise<void>
  flush?: (controller: TransformStreamDefaultController<O>) => void | Promise<void>
}

interface TransformStreamDefaultController<O = unknown> {
  enqueue(chunk: O): void
  error(reason?: unknown): void
  terminate(): void
  readonly desiredSize: number | null
}

export class TransformStream<I = unknown, O = unknown> {
  readonly readable: ReadableStream<O>
  readonly writable: WritableStream<I>

  constructor(transformer?: Transformer<I, O>) {
    let readableController!: ReadableStreamController<O>

    this.readable = new ReadableStream<O>({
      start(controller) {
        readableController = controller
      }
    })

    const ctrl: TransformStreamDefaultController<O> = {
      enqueue(chunk: O) {
        readableController.enqueue(chunk)
      },
      error(reason?: unknown) {
        readableController.error(reason)
      },
      terminate() {
        readableController.close()
      },
      get desiredSize() {
        return readableController.desiredSize
      }
    }

    try {
      const startResult = transformer?.start?.(ctrl)
      if (startResult instanceof Promise) {
        void startResult.catch((e: unknown) => readableController.error(e))
      }
    } catch (e) {
      readableController.error(e)
    }

    this.writable = new WritableStream<I>({
      async write(chunk: I) {
        if (transformer?.transform) {
          await transformer.transform(chunk, ctrl)
        } else {
          ctrl.enqueue(chunk as unknown as O)
        }
      },
      async close() {
        if (transformer?.flush) await transformer.flush(ctrl)
        ctrl.terminate()
      },
      abort(reason?: unknown) {
        ctrl.error(reason)
      }
    })
  }
}
