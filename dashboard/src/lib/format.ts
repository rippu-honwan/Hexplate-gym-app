const int = new Intl.NumberFormat('en-US', { maximumFractionDigits: 0 })
const one = new Intl.NumberFormat('en-US', { minimumFractionDigits: 1, maximumFractionDigits: 1 })
const two = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })
const compact = new Intl.NumberFormat('en-US', { notation: 'compact', maximumFractionDigits: 1 })

export const fmtInt = (n: number) => int.format(n)
export const fmt1 = (n: number) => one.format(n)
export const fmt2 = (n: number) => two.format(n)
export const fmtCompact = (n: number) => compact.format(n)
export const fmtKg = (n: number) => `${compact.format(n)} kg`

/** "+4.2%" / "−3.0%" with a true minus sign; "n/a" without a baseline. */
export function fmtDelta(pct: number | null): string {
  if (pct === null || !Number.isFinite(pct)) return 'n/a'
  const sign = pct > 0.05 ? '+' : pct < -0.05 ? '−' : ''
  return `${sign}${one.format(Math.abs(pct))}%`
}
