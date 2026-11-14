// How two copies changed at the same moment settle (app/lib/data/library.dart, keepsOver): the same
// rule on every device, so they all keep the same one.

const has = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);

/**
 * Whether [a] is kept over [b], two JSON objects with the same time. The fuller one wins, having
 * all the other has and more: a device on an older version sends back what it got without what
 * it does not know, and must not take that away from the others. Else, the one that sorts last.
 */
export function keepsOver(a: Record<string, unknown>, b?: Record<string, unknown> | null): boolean {
  if (!b) return true;
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length && (kb.every((k) => has(a, k)) || ka.every((k) => has(b, k)))) return ka.length > kb.length;
  return JSON.stringify(a) > JSON.stringify(b);
}
