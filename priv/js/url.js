(() => {
  class URLSearchParams {
    #entries = [];

    constructor(init) {
      if (typeof init === 'string') {
        if (init.startsWith('?')) init = init.slice(1);
        for (const pair of init.split('&')) {
          if (pair === '') continue;
          const eq = pair.indexOf('=');
          if (eq === -1) {
            this.#entries.push([decodeURIComponent(pair.replace(/\+/g, ' ')), '']);
          } else {
            this.#entries.push([
              decodeURIComponent(pair.slice(0, eq).replace(/\+/g, ' ')),
              decodeURIComponent(pair.slice(eq + 1).replace(/\+/g, ' '))
            ]);
          }
        }
      } else if (Array.isArray(init)) {
        for (const pair of init) {
          if (!Array.isArray(pair) || pair.length !== 2)
            throw new TypeError('Each pair must be an iterable with exactly two elements');
          this.#entries.push([String(pair[0]), String(pair[1])]);
        }
      } else if (init && typeof init === 'object') {
        for (const key of Object.keys(init)) {
          this.#entries.push([key, String(init[key])]);
        }
      }
    }

    append(name, value) {
      this.#entries.push([String(name), String(value)]);
      this.#update();
    }

    delete(name, value) {
      if (arguments.length >= 2) {
        const v = String(value);
        this.#entries = this.#entries.filter(e => !(e[0] === name && e[1] === v));
      } else {
        this.#entries = this.#entries.filter(e => e[0] !== name);
      }
      this.#update();
    }

    get(name) {
      const entry = this.#entries.find(e => e[0] === name);
      return entry ? entry[1] : null;
    }

    getAll(name) {
      return this.#entries.filter(e => e[0] === name).map(e => e[1]);
    }

    has(name, value) {
      if (arguments.length >= 2) {
        const v = String(value);
        return this.#entries.some(e => e[0] === name && e[1] === v);
      }
      return this.#entries.some(e => e[0] === name);
    }

    set(name, value) {
      const n = String(name), v = String(value);
      let found = false;
      this.#entries = this.#entries.filter(e => {
        if (e[0] === n) {
          if (!found) { found = true; e[1] = v; return true; }
          return false;
        }
        return true;
      });
      if (!found) this.#entries.push([n, v]);
      this.#update();
    }

    sort() {
      this.#entries.sort((a, b) => a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0);
      this.#update();
    }

    toString() {
      return this.#entries.map(([k, v]) =>
        encodeComponent(k) + '=' + encodeComponent(v)
      ).join('&');
    }

    forEach(callback, thisArg) {
      for (const [name, value] of this.#entries) {
        callback.call(thisArg, value, name, this);
      }
    }

    *entries() { for (const e of this.#entries) yield [...e]; }
    *keys() { for (const e of this.#entries) yield e[0]; }
    *values() { for (const e of this.#entries) yield e[1]; }
    [Symbol.iterator]() { return this.entries(); }

    get size() { return this.#entries.length; }

    // Internal: link to URL object for update propagation
    _url = null;

    #update() {
      if (this._url) this._url._updateSearch(this.toString());
    }
  }

  function encodeComponent(s) {
    return encodeURIComponent(s)
      .replace(/%20/g, '+')
      .replace(/!/g, '%21')
      .replace(/'/g, '%27')
      .replace(/\(/g, '%28')
      .replace(/\)/g, '%29')
      .replace(/~/g, '%7E');
  }

  class URL {
    #components;
    #searchParams;

    constructor(url, base) {
      const args = base !== undefined ? [String(url), String(base)] : [String(url)];
      const result = beam.callSync('__url_parse', ...args);
      if (!result.ok) throw new TypeError(`Invalid URL: '${url}'`);
      this.#components = result.components;
      this.#searchParams = new URLSearchParams(this.#components.search);
      this.#searchParams._url = this;
    }

    get href() { return this.#components.href; }
    set href(v) {
      const result = beam.callSync('__url_parse', String(v));
      if (!result.ok) throw new TypeError(`Invalid URL: '${v}'`);
      this.#components = result.components;
      this.#searchParams = new URLSearchParams(this.#components.search);
      this.#searchParams._url = this;
    }

    get origin() { return this.#components.origin; }
    get protocol() { return this.#components.protocol; }
    set protocol(v) {
      this.#components.protocol = String(v).endsWith(':') ? String(v) : String(v) + ':';
      this.#recompose();
    }

    get username() { return this.#components.username; }
    set username(v) { this.#components.username = String(v); this.#recompose(); }

    get password() { return this.#components.password; }
    set password(v) { this.#components.password = String(v); this.#recompose(); }

    get host() {
      const port = this.#components.port;
      return port ? this.#components.hostname + ':' + port : this.#components.hostname;
    }
    set host(v) {
      const s = String(v);
      const ci = s.lastIndexOf(':');
      if (ci > 0 && !s.includes(']', ci)) {
        this.#components.hostname = s.slice(0, ci);
        this.#components.port = s.slice(ci + 1);
      } else {
        this.#components.hostname = s;
        this.#components.port = '';
      }
      this.#recompose();
    }

    get hostname() { return this.#components.hostname; }
    set hostname(v) { this.#components.hostname = String(v); this.#recompose(); }

    get port() { return this.#components.port; }
    set port(v) {
      this.#components.port = v === '' || v === undefined ? '' : String(parseInt(v, 10));
      this.#recompose();
    }

    get pathname() { return this.#components.pathname; }
    set pathname(v) { this.#components.pathname = String(v); this.#recompose(); }

    get search() { return this.#components.search; }
    set search(v) {
      const s = String(v);
      this.#components.search = s === '' ? '' : (s.startsWith('?') ? s : '?' + s);
      this.#searchParams = new URLSearchParams(this.#components.search);
      this.#searchParams._url = this;
      this.#recompose();
    }

    get hash() { return this.#components.hash; }
    set hash(v) {
      const s = String(v);
      this.#components.hash = s === '' ? '' : (s.startsWith('#') ? s : '#' + s);
      this.#recompose();
    }

    get searchParams() { return this.#searchParams; }

    toString() { return this.href; }
    toJSON() { return this.href; }

    _updateSearch(qs) {
      this.#components.search = qs ? '?' + qs : '';
      this.#recompose();
    }

    #recompose() {
      const href = beam.callSync('__url_recompose', this.#components);
      this.#components.href = href;
      this.#components.origin = this.#buildOrigin();
    }

    #buildOrigin() {
      const p = this.#components.protocol;
      if (['http:', 'https:', 'ftp:', 'ws:', 'wss:'].includes(p)) {
        let o = p + '//' + this.#components.hostname;
        if (this.#components.port) o += ':' + this.#components.port;
        return o;
      }
      return 'null';
    }

    static canParse(url, base) {
      try { new URL(url, base); return true; } catch { return false; }
    }
  }

  globalThis.URL = URL;
  globalThis.URLSearchParams = URLSearchParams;
})();
