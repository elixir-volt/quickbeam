interface URLComponents {
  href: string;
  origin: string;
  protocol: string;
  username: string;
  password: string;
  hostname: string;
  port: string;
  pathname: string;
  search: string;
  hash: string;
}

interface URLParseResult {
  ok: boolean;
  components: URLComponents;
}

const ORIGIN_SCHEMES = ["http:", "https:", "ftp:", "ws:", "wss:"];

function encodeComponent(s: string): string {
  return encodeURIComponent(s)
    .replace(/%20/g, "+")
    .replace(/!/g, "%21")
    .replace(/'/g, "%27")
    .replace(/\(/g, "%28")
    .replace(/\)/g, "%29")
    .replace(/~/g, "%7E");
}

class QBURLSearchParams {
  #entries: [string, string][] = [];
  _url: QBURL | null = null;

  constructor(init?: string | string[][] | Record<string, string>) {
    if (typeof init === "string") {
      const s = init.startsWith("?") ? init.slice(1) : init;
      for (const pair of s.split("&")) {
        if (pair === "") continue;
        const eq = pair.indexOf("=");
        if (eq === -1) {
          this.#entries.push([decodeURIComponent(pair.replace(/\+/g, " ")), ""]);
        } else {
          this.#entries.push([
            decodeURIComponent(pair.slice(0, eq).replace(/\+/g, " ")),
            decodeURIComponent(pair.slice(eq + 1).replace(/\+/g, " ")),
          ]);
        }
      }
    } else if (Array.isArray(init)) {
      for (const pair of init) {
        if (pair.length !== 2) {
          throw new TypeError("Each pair must be an iterable with exactly two elements");
        }
        this.#entries.push([String(pair[0]), String(pair[1])]);
      }
    } else if (init !== undefined) {
      for (const key of Object.keys(init)) {
        this.#entries.push([key, String(init[key])]);
      }
    }
  }

  append(name: string, value: string): void {
    this.#entries.push([String(name), String(value)]);
    this.#update();
  }

  delete(name: string, value?: string): void {
    if (value !== undefined) {
      const v = String(value);
      this.#entries = this.#entries.filter((e) => !(e[0] === name && e[1] === v));
    } else {
      this.#entries = this.#entries.filter((e) => e[0] !== name);
    }
    this.#update();
  }

  get(name: string): string | null {
    const entry = this.#entries.find((e) => e[0] === name);
    return entry ? entry[1] : null;
  }

  getAll(name: string): string[] {
    return this.#entries.filter((e) => e[0] === name).map((e) => e[1]);
  }

  has(name: string, value?: string): boolean {
    if (value !== undefined) {
      const v = String(value);
      return this.#entries.some((e) => e[0] === name && e[1] === v);
    }
    return this.#entries.some((e) => e[0] === name);
  }

  set(name: string, value: string): void {
    const n = String(name);
    const v = String(value);
    const idx = this.#entries.findIndex((e) => e[0] === n);
    if (idx === -1) {
      this.#entries.push([n, v]);
    } else {
      this.#entries[idx][1] = v;
      this.#entries = this.#entries.filter((e, i) => e[0] !== n || i === idx);
    }
    this.#update();
  }

  sort(): void {
    this.#entries.sort((a, b) => a[0].localeCompare(b[0]));
    this.#update();
  }

  toString(): string {
    return this.#entries.map(([k, v]) => encodeComponent(k) + "=" + encodeComponent(v)).join("&");
  }

  forEach(
    callback: (value: string, name: string, parent: QBURLSearchParams) => void,
    thisArg?: unknown,
  ): void {
    for (const [name, value] of this.#entries) {
      callback.call(thisArg, value, name, this);
    }
  }

  *entries(): IterableIterator<[string, string]> {
    for (const e of this.#entries) yield [...e] as [string, string];
  }
  *keys(): IterableIterator<string> {
    for (const e of this.#entries) yield e[0];
  }
  *values(): IterableIterator<string> {
    for (const e of this.#entries) yield e[1];
  }
  [Symbol.iterator](): IterableIterator<[string, string]> {
    return this.entries();
  }

  get size(): number {
    return this.#entries.length;
  }

  #update(): void {
    if (this._url) this._url._updateSearch(this.toString());
  }
}

class QBURL {
  #components: URLComponents;
  #searchParams: QBURLSearchParams;

  constructor(url: string, base?: string) {
    const args = base !== undefined ? [String(url), String(base)] : [String(url)];
    const result = beam.callSync("__url_parse", ...args) as URLParseResult;
    if (!result.ok) throw new TypeError(`Invalid URL: '${url}'`);
    this.#components = result.components;
    this.#searchParams = new QBURLSearchParams(this.#components.search);
    this.#searchParams._url = this;
  }

  get href(): string {
    return this.#components.href;
  }
  set href(v: string) {
    const result = beam.callSync("__url_parse", String(v)) as URLParseResult;
    if (!result.ok) throw new TypeError(`Invalid URL: '${v}'`);
    this.#components = result.components;
    this.#searchParams = new QBURLSearchParams(this.#components.search);
    this.#searchParams._url = this;
  }

  get origin(): string {
    return this.#components.origin;
  }
  get protocol(): string {
    return this.#components.protocol;
  }
  set protocol(v: string) {
    this.#components.protocol = String(v).endsWith(":") ? String(v) : String(v) + ":";
    this.#recompose();
  }

  get username(): string {
    return this.#components.username;
  }
  set username(v: string) {
    this.#components.username = String(v);
    this.#recompose();
  }

  get password(): string {
    return this.#components.password;
  }
  set password(v: string) {
    this.#components.password = String(v);
    this.#recompose();
  }

  get host(): string {
    const port = this.#components.port;
    return port ? this.#components.hostname + ":" + port : this.#components.hostname;
  }
  set host(v: string) {
    const s = String(v);
    const ci = s.lastIndexOf(":");
    if (ci > 0 && !s.includes("]", ci)) {
      this.#components.hostname = s.slice(0, ci);
      this.#components.port = s.slice(ci + 1);
    } else {
      this.#components.hostname = s;
      this.#components.port = "";
    }
    this.#recompose();
  }

  get hostname(): string {
    return this.#components.hostname;
  }
  set hostname(v: string) {
    this.#components.hostname = String(v);
    this.#recompose();
  }

  get port(): string {
    return this.#components.port;
  }
  set port(v: string | undefined) {
    this.#components.port = v === "" || v === undefined ? "" : String(parseInt(v, 10));
    this.#recompose();
  }

  get pathname(): string {
    return this.#components.pathname;
  }
  set pathname(v: string) {
    this.#components.pathname = String(v);
    this.#recompose();
  }

  get search(): string {
    return this.#components.search;
  }
  set search(v: string) {
    const s = String(v);
    this.#components.search = s === "" ? "" : (s.startsWith("?") ? s : "?" + s);
    this.#searchParams = new QBURLSearchParams(this.#components.search);
    this.#searchParams._url = this;
    this.#recompose();
  }

  get hash(): string {
    return this.#components.hash;
  }
  set hash(v: string) {
    const s = String(v);
    this.#components.hash = s === "" ? "" : (s.startsWith("#") ? s : "#" + s);
    this.#recompose();
  }

  get searchParams(): QBURLSearchParams {
    return this.#searchParams;
  }

  toString(): string {
    return this.href;
  }
  toJSON(): string {
    return this.href;
  }

  _updateSearch(qs: string): void {
    this.#components.search = qs ? "?" + qs : "";
    this.#recompose();
  }

  #recompose(): void {
    const href = beam.callSync("__url_recompose", this.#components) as string;
    this.#components.href = href;
    this.#components.origin = this.#buildOrigin();
  }

  #buildOrigin(): string {
    const p = this.#components.protocol;
    if (ORIGIN_SCHEMES.includes(p)) {
      let o = p + "//" + this.#components.hostname;
      if (this.#components.port) o += ":" + this.#components.port;
      return o;
    }
    return "null";
  }

  static canParse(url: string, base?: string): boolean {
    try {
      new QBURL(url, base);
      return true;
    } catch {
      return false;
    }
  }
}

(globalThis as Record<string, unknown>).URL = QBURL;
(globalThis as Record<string, unknown>).URLSearchParams = QBURLSearchParams;
