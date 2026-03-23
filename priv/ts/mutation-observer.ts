class QBMutationObserver {
  constructor(_callback: MutationCallback) {
    void _callback
  }

  observe(_target: unknown, _options?: MutationObserverInit): void {
    void _target
    void _options
  }

  disconnect(): void {
    return
  }

  takeRecords(): MutationRecord[] {
    return []
  }
}

Object.assign(globalThis, { MutationObserver: QBMutationObserver });
