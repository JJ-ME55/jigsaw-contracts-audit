// Keeper price check (Jj, 18 Oct; GPT review #6): a fresh quote faithfully accepts a price someone has just pushed, so
// before any keeper trade the pool's spot price is compared with the median of our own readings over the last hours.
// More than KEEPER_PRICE_MAX_DEV (default 10%) off, or too little history, and the trade waits. Readings come from the
// keeper's own 5-minute passes (pool state read straight from the PoolManager), never from the trade's own quote.
export const GUARD = {
  maxDev: Number(process.env.KEEPER_PRICE_MAX_DEV ?? 0.10),
  windowMs: 12 * 3600_000,      // readings kept
  minGapMs: 4 * 60_000,         // at most one reading per pass
  minSamples: Number(process.env.KEEPER_PRICE_MIN_SAMPLES ?? 6),
  minSpanMs: Number(process.env.KEEPER_PRICE_MIN_SPAN_H ?? 1) * 3600_000,
};

/** Add a reading (t ms, p > 0) to a history [[t, p], ...]; returns the trimmed history. */
export function record(hist = [], t, p, g = GUARD) {
  const h = hist.filter(([ts]) => t - ts <= g.windowMs);
  if (!(p > 0) || !Number.isFinite(p)) return h;
  if (!h.length || t - h[h.length - 1][0] >= g.minGapMs) h.push([t, p]);
  return h.slice(-400);
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };

/** May a trade go ahead at spot price p? { ok, why, median, dev } */
export function check(hist = [], p, now, g = GUARD) {
  const h = hist.filter(([ts]) => now - ts <= g.windowMs);
  if (h.length < g.minSamples || now - h[0][0] < g.minSpanMs) return { ok: false, why: `price history too short (${h.length} readings over ${((now - (h[0]?.[0] ?? now)) / 3600_000).toFixed(1)} h; need ${g.minSamples} over ${g.minSpanMs / 3600_000} h)` };
  const m = median(h.map(([, x]) => x)); const dev = Math.abs(p / m - 1);
  if (dev > g.maxDev) return { ok: false, why: `price ${(dev * 100).toFixed(1)}% off its ${((now - h[0][0]) / 3600_000).toFixed(1)} h median: waiting`, median: m, dev };
  return { ok: true, median: m, dev };
}
