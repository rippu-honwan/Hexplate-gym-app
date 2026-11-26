import { ArrowDownRight, ArrowUpRight, Minus } from 'lucide-react'
import { Line, LineChart, YAxis } from 'recharts'
import { Card } from '@/components/ui/card'
import { useI18n } from '@/i18n'
import { fmtDelta } from '@/lib/format'

export interface KpiSpec {
  label: string
  value: string
  /** Percent change vs the previous period, or null. */
  delta: number | null
  /** Overrides the delta text (e.g. an absolute change). */
  deltaText?: string
  compareLabel: string
  spark: (number | null)[]
}

export function KpiCard({ label, value, delta, deltaText, compareLabel, spark }: KpiSpec) {
  const { t } = useI18n()
  const Arrow = delta === null || Math.abs(delta) < 0.05 ? Minus : delta > 0 ? ArrowUpRight : ArrowDownRight
  const data = spark.map((v, i) => ({ i, v }))
  // Pad the y-range so a one-session change (4 -> 5 a week) reads as a gentle swell, not a full-height step.
  const vals = spark.filter((v): v is number => v !== null)
  const lo = vals.length ? Math.min(...vals) : 0, hi = vals.length ? Math.max(...vals) : 1
  const pad = (hi - lo || Math.abs(hi) || 1) * 0.6
  return (
    <Card className="gap-0 rounded-2xl px-5 py-4 shadow-none">
      <p className="text-[13px] text-muted-foreground">{label}</p>
      <div className="mt-2 flex items-end justify-between gap-3">
        <p className="text-[28px] leading-none font-medium">{value}</p>
        <div className="h-9 w-[84px] shrink-0" aria-hidden>
          <LineChart responsive style={{ width: '100%', height: '100%' }} data={data} margin={{ top: 4, right: 2, bottom: 4, left: 2 }} accessibilityLayer={false}>
            <YAxis hide domain={[lo - pad, hi + pad]} />
            <Line type="basis" dataKey="v" stroke="var(--chart-1)" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round" dot={false} isAnimationActive={false} connectNulls />
          </LineChart>
        </div>
      </div>
      <p className="mt-3 flex items-center gap-1 text-[12px] text-muted-foreground">
        <Arrow className="size-3.5 text-foreground" aria-hidden />
        <span className="font-medium text-foreground">{deltaText ?? fmtDelta(delta)}</span>
        <span>{t('vs previous {range}', { range: compareLabel })}</span>
      </p>
    </Card>
  )
}

export function KpiRow({ items }: { items: KpiSpec[] }) {
  return (
    <section aria-label="Key metrics" className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {items.map((k) => <KpiCard key={k.label} {...k} />)}
    </section>
  )
}
