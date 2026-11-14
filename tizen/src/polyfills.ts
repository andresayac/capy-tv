// What Chromium 69 (Tizen 5.5) lacks and the libraries use: esbuild lowers syntax, not missing
// functions. Imported before anything else.
/* eslint-disable @typescript-eslint/no-explicit-any */
const g: any = typeof globalThis !== 'undefined' ? globalThis : typeof self !== 'undefined' ? self : window;
if (typeof globalThis === 'undefined') (window as any).globalThis = g;

const O: any = Object;
if (!O.hasOwn) O.hasOwn = (o: object, k: PropertyKey) => Object.prototype.hasOwnProperty.call(o, k);
if (!O.fromEntries) {
  O.fromEntries = (entries: Iterable<[PropertyKey, unknown]>) => {
    const out: any = {};
    for (const [k, v] of entries) out[k as any] = v;
    return out;
  };
}

function at(this: ArrayLike<unknown>, i: number) {
  const n = Math.trunc(i) || 0;
  const k = n < 0 ? this.length + n : n;
  return k < 0 || k >= this.length ? undefined : this[k];
}
const typed = [Array, Int8Array, Uint8Array, Uint8ClampedArray, Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
for (const C of typed) {
  if (!(C.prototype as any).at) Object.defineProperty(C.prototype, 'at', { value: at, writable: true, configurable: true });
}
if (!(String.prototype as any).at) Object.defineProperty(String.prototype, 'at', { value: at, writable: true, configurable: true });

if (!(String.prototype as any).replaceAll) {
  Object.defineProperty(String.prototype, 'replaceAll', {
    value(this: string, search: string | RegExp, replacement: string) {
      return typeof search === 'string' ? this.split(search).join(replacement) : this.replace(search, replacement);
    },
    writable: true,
    configurable: true,
  });
}

const P: any = Promise;
if (!P.allSettled) {
  P.allSettled = (list: Promise<unknown>[]) =>
    Promise.all(list.map((p) => Promise.resolve(p).then((value) => ({ status: 'fulfilled', value }), (reason) => ({ status: 'rejected', reason }))));
}

export {};
