const perf = globalThis.performance as Record<string, unknown>

const timeOrigin = Date.now() - perf.now!()

class PerformanceEntry {
  readonly name: string
  readonly entryType: string
  readonly startTime: number
  readonly duration: number

  constructor(name: string, entryType: string, startTime: number, duration: number) {
    this.name = name
    this.entryType = entryType
    this.startTime = startTime
    this.duration = duration
  }

  toJSON() {
    return {
      name: this.name,
      entryType: this.entryType,
      startTime: this.startTime,
      duration: this.duration,
    }
  }
}

class PerformanceMark extends PerformanceEntry {
  readonly detail: unknown

  constructor(name: string, options?: { startTime?: number; detail?: unknown }) {
    const startTime = options?.startTime ?? (perf.now as () => number)()
    super(name, 'mark', startTime, 0)
    this.detail = options?.detail ?? null
  }

  toJSON() {
    return { ...super.toJSON(), detail: this.detail }
  }
}

class PerformanceMeasure extends PerformanceEntry {
  readonly detail: unknown

  constructor(name: string, startTime: number, duration: number, detail?: unknown) {
    super(name, 'measure', startTime, duration)
    this.detail = detail ?? null
  }

  toJSON() {
    return { ...super.toJSON(), detail: this.detail }
  }
}

const entries: PerformanceEntry[] = []

function findMark(name: string): PerformanceMark {
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i]
    if (e.entryType === 'mark' && e.name === name) return e as PerformanceMark
  }
  throw new DOMException(
    `Failed to execute 'measure' on 'Performance': The mark '${name}' does not exist.`,
    'SyntaxError'
  )
}

perf.timeOrigin = timeOrigin

perf.mark = function mark(name: string, options?: { startTime?: number; detail?: unknown }) {
  const mark = new PerformanceMark(name, options)
  entries.push(mark)
  return mark
}

perf.measure = function measure(
  name: string,
  startOrOptions?: string | { start?: string | number; end?: string | number; duration?: number; detail?: unknown },
  endMark?: string
) {
  let startTime: number
  let duration: number
  let detail: unknown

  if (startOrOptions != null && typeof startOrOptions === 'object') {
    const opts = startOrOptions
    detail = opts.detail

    const resolveTime = (v: string | number | undefined): number | undefined => {
      if (v === undefined) return undefined
      if (typeof v === 'number') return v
      return findMark(v).startTime
    }

    const start = resolveTime(opts.start)
    const end = resolveTime(opts.end)
    const dur = opts.duration

    if (start !== undefined && end !== undefined) {
      startTime = start
      duration = end - start
    } else if (start !== undefined && dur !== undefined) {
      startTime = start
      duration = dur
    } else if (end !== undefined && dur !== undefined) {
      startTime = end - dur
      duration = dur
    } else if (start !== undefined) {
      startTime = start
      duration = (perf.now as () => number)() - startTime
    } else if (end !== undefined) {
      startTime = 0
      duration = end
    } else {
      startTime = 0
      duration = (perf.now as () => number)()
    }
  } else if (typeof startOrOptions === 'string') {
    startTime = findMark(startOrOptions).startTime
    if (endMark !== undefined) {
      duration = findMark(endMark).startTime - startTime
    } else {
      duration = (perf.now as () => number)() - startTime
    }
  } else {
    startTime = 0
    duration = (perf.now as () => number)()
  }

  const measure = new PerformanceMeasure(name, startTime, duration, detail)
  entries.push(measure)
  return measure
}

perf.getEntries = function getEntries() {
  return entries.slice()
}

perf.getEntriesByType = function getEntriesByType(type: string) {
  return entries.filter(e => e.entryType === type)
}

perf.getEntriesByName = function getEntriesByName(name: string, type?: string) {
  return entries.filter(e => e.name === name && (type === undefined || e.entryType === type))
}

perf.clearMarks = function clearMarks(name?: string) {
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i].entryType === 'mark' && (name === undefined || entries[i].name === name)) {
      entries.splice(i, 1)
    }
  }
}

perf.clearMeasures = function clearMeasures(name?: string) {
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i].entryType === 'measure' && (name === undefined || entries[i].name === name)) {
      entries.splice(i, 1)
    }
  }
}

perf.toJSON = function toJSON() {
  return { timeOrigin }
}

Object.assign(globalThis, { PerformanceEntry, PerformanceMark, PerformanceMeasure })
