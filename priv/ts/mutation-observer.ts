class MutationObserver {
  #callback: MutationCallback;

  constructor(callback: MutationCallback) {
    this.#callback = callback;
  }

  observe(_target: any, _options?: MutationObserverInit): void {}
  disconnect(): void {}
  takeRecords(): MutationRecord[] { return []; }
}

Object.assign(globalThis, { MutationObserver });
