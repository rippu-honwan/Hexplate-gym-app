import type { ReactNode } from 'react'
import {
  Bar, BarChart, CartesianGrid, Line, LineChart, Rectangle, ReferenceArea, ReferenceLine, Tooltip, XAxis, YAxis,
  type BarShapeProps,
} from 'recharts'
import { Card } from '@/components/ui/card'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { useI18n } from '@/i18n'
import { cn } from '@/lib/utils'
import type { MuscleTargetRow, Point } from '@/lib/analytics'
import type { Granularity } from '@/lib/dates'
import { fmt1, fmtCompact, fmtInt } from '@/lib/format'
import type { Macros, MuscleDetail, MuscleSlug } from '@/types/hexplate'
import { MUSCLE_NAMES } from '@/types/hexplate'

const AXIS = { fontSize: 11, fill: 'var(--muted-foreground)' }

export function Panel({ title, description, action, children, className }: {
  title: string; description?: string; action?: ReactNode; children: ReactNode; className?: string
}) {
  return (
    <Card className={cn('gap-4 rounded-2xl px-5 py-5 shadow-none', className)}>
      <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
        <div className="min-w-0">
          <h2 className="text-[15px] font-semibold">{title}</h2>
          {description && <p className="mt-0.5 text-[13px] text-muted-foreground">{description}</p>}
        </div>
        {action}
      </div>
      {children}
    </Card>
  )
}

export function TooltipBox({ title, rows }: { title: string; rows: [string, string][] }) {
  return (
    <div className="pointer-events-none min-w-40 rounded-lg border border-border bg-popover px-3 py-2 text-[12px] leading-4 text-popover-foreground shadow-[0_8px_24px_rgb(0_0_0/0.08)] dark:shadow-none">
      <p className="mb-1.5 font-medium">{title}</p>
      <dl className="grid grid-cols-[1fr_auto] gap-x-4 gap-y-1">
        {rows.map(([k, v]) => (
          <div key={k} className="contents">
            <dt className="text-muted-foreground">{k}</dt>
            <dd className="text-right font-medium">{v}</dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

const GRANULARITIES: { key: Granularity; label: string }[] = [
  { key: 'daily', label: 'Daily' },
  { key: 'weekly', label: 'Weekly' },
  { key: 'monthly', label: 'Monthly' },
]

export function GranularityToggle({ value, onChange }: { value: Granularity; onChange: (g: Granularity) => void }) {
  const { t } = useI18n()
  return (
    <ToggleGroup type="single" value={value} onValueChange={(v) => v && onChange(v as Granularity)} variant="outline" size="sm" spacing={0} aria-label={t('Granularity')}>
      {GRANULARITIES.map((g) => (
        <ToggleGroupItem key={g.key} value={g.key} className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">
          {t(g.label)}
        </ToggleGroupItem>
      ))}
    </ToggleGroup>
  )
}

/**
 * Lets a chart fill whatever height its panel has left (min 260 px). The absolute inner box keeps the
 * chart's own size out of the grid row's height, so a 100% chart can't grow the row it sits in.
 */
export function Fill({ children }: { children: ReactNode }) {
  return (
    <div className="relative min-h-[260px] flex-1">
      <div className="absolute inset-0">{children}</div>
    </div>
  )
}

/** The primary time series: bars for totals, a line for averages, with an optional goal or band. */
export function TrendChart({ points, kind, unit, valueLabel, goal, band, yDomain, height = 260 }: {
  points: Point[]
  kind: 'bar' | 'line'
  unit: string
  valueLabel: string
  goal?: number
  band?: [number, number]
  yDomain?: [number, number]
  height?: number | '100%'
}) {
  const fmtValue = (v: number) => `${unit === 'kg' ? fmtInt(v) : Number.isInteger(v) ? fmtInt(v) : fmt1(v)}${unit ? ` ${unit}` : ''}`
  const common = (
    <>
      <CartesianGrid vertical={false} stroke="var(--border)" />
      <XAxis dataKey="label" tick={AXIS} tickLine={false} axisLine={false} tickMargin={6} minTickGap={24} interval="preserveStartEnd" />
      <YAxis tick={AXIS} tickLine={false} axisLine={false} width={44} tickFormatter={(v: number) => fmtCompact(v)} domain={yDomain ?? (kind === 'line' ? ['auto', 'auto'] : [0, 'auto'])} />
      {band && <ReferenceArea y1={band[0]} y2={band[1]} fill="var(--chart-3)" fillOpacity={0.6} ifOverflow="extendDomain" />}
      {goal !== undefined && <ReferenceLine y={goal} stroke="var(--chart-2)" strokeDasharray="4 4" ifOverflow="extendDomain" />}
      <Tooltip
        isAnimationActive={false}
        wrapperStyle={{ outline: 'none' }}
        cursor={kind === 'bar' ? { fill: 'var(--foreground)', fillOpacity: 0.05 } : { stroke: 'var(--muted-foreground)', strokeWidth: 1, strokeOpacity: 0.6 }}
        content={({ active, payload, label }) => {
          const v = payload?.[0]?.value
          if (!active || typeof v !== 'number') return null
          return <TooltipBox title={String(label)} rows={[[valueLabel, fmtValue(v)]]} />
        }}
      />
    </>
  )
  const style = { width: '100%', height }
  const margin = { top: 8, right: 4, bottom: 0, left: 0 }
  return kind === 'bar' ? (
    <BarChart responsive style={style} data={points} margin={margin} title={valueLabel}>
      {common}
      <Bar dataKey="value" fill="var(--chart-1)" radius={[3, 3, 0, 0]} maxBarSize={28} isAnimationActive={false}
        activeBar={{ fill: 'var(--chart-1)', fillOpacity: 0.82 }} />
    </BarChart>
  ) : (
    <LineChart responsive style={style} data={points} margin={margin} title={valueLabel}>
      {common}
      <Line type="monotone" dataKey="value" stroke="var(--chart-1)" strokeWidth={2} dot={false} connectNulls isAnimationActive={false}
        activeDot={{ r: 4, strokeWidth: 2, stroke: 'var(--card)', fill: 'var(--chart-1)' }} />
    </LineChart>
  )
}

/**
 * Weekly working sets per muscle against its target range: the shaded band is the range, the thin
 * bar is what you did. In range reads in the accent; below or above in grey (and says so in the tooltip).
 */
export function TargetChart({ rows }: { rows: MuscleTargetRow[] }) {
  const { t } = useI18n()
  const localizedRows = rows.map((r) => ({ ...r, displayName: t(r.name) }))
  const max = Math.max(22, ...rows.map((r) => Math.ceil(r.sets + 2)))
  const STATUS = { below: t('Below target'), in: t('In range'), above: t('Above target') }
  const SetsBar = (p: BarShapeProps) => (
    <Rectangle {...p} fill={(p.payload as MuscleTargetRow).status === 'in' ? 'var(--chart-1)' : 'var(--chart-2)'} />
  )
  return (
    <div>
      <BarChart responsive style={{ width: '100%', height: rows.length * 30 + 28 }} data={localizedRows} layout="vertical" margin={{ top: 0, right: 8, bottom: 0, left: 0 }} title={t('Weekly sets vs target')}>
        <CartesianGrid horizontal={false} stroke="var(--border)" />
        <XAxis type="number" domain={[0, max]} tick={AXIS} tickLine={false} axisLine={false} allowDecimals={false} />
        <YAxis yAxisId="band" type="category" dataKey="displayName" tick={{ ...AXIS, fill: 'var(--foreground)', fontSize: 12 }} tickLine={false} axisLine={false} width={96} />
        <YAxis yAxisId="sets" type="category" dataKey="displayName" hide />
        <Tooltip
          isAnimationActive={false}
          wrapperStyle={{ outline: 'none' }}
          cursor={{ fill: 'var(--foreground)', fillOpacity: 0.04 }}
          content={({ active, payload }) => {
            const r = payload?.[0]?.payload as (MuscleTargetRow & { displayName: string }) | undefined
            if (!active || !r) return null
            return <TooltipBox title={r.displayName} rows={[[t('Sets / week'), fmt1(r.sets)], [t('Target'), `${r.lo}–${r.hi}`], [t('Status'), STATUS[r.status]]]} />
          }}
        />
        <Bar yAxisId="band" dataKey={(r: MuscleTargetRow) => [r.lo, r.hi]} fill="var(--chart-3)" barSize={16} radius={4} isAnimationActive={false} />
        <Bar yAxisId="sets" dataKey="sets" barSize={6} radius={3} shape={SetsBar} isAnimationActive={false} />
      </BarChart>
      <div className="mt-3 flex flex-wrap gap-x-5 gap-y-1 text-[12px] text-muted-foreground">
        <span className="flex items-center gap-1.5"><span className="h-2.5 w-4 rounded-sm bg-chart-3 ring-1 ring-border" aria-hidden />{t('Target range')}</span>
        <span className="flex items-center gap-1.5"><span className="h-1.5 w-4 rounded-full bg-chart-1" aria-hidden />{t('In range')}</span>
        <span className="flex items-center gap-1.5"><span className="h-1.5 w-4 rounded-full bg-chart-2" aria-hidden />{t('Outside range')}</span>
      </div>
    </div>
  )
}

/** Hairline meter rows: a label, a thin bar and a right-aligned figure. */
export function MeterRow({ label, value, fraction, detail }: { label: string; value: string; fraction: number; detail?: string }) {
  const pct = Math.max(0, Math.min(1, fraction)) * 100
  return (
    <li className="grid grid-cols-[1fr_auto] items-baseline gap-x-3 gap-y-2">
      <span className="truncate text-[13px]">{label}</span>
      <span className="text-right text-[13px] font-medium">{value}</span>
      <span className="col-span-2 h-1.5 overflow-hidden rounded-full bg-muted" aria-hidden>
        <span className="block h-full rounded-full bg-chart-1" style={{ width: `${pct}%` }} />
      </span>
      {detail && <span className="col-span-2 text-[12px] text-muted-foreground">{detail}</span>}
    </li>
  )
}

export function FatigueList({ muscles, limit }: { muscles: Record<MuscleSlug, MuscleDetail>; limit?: number }) {
  const { t } = useI18n()
  const rows = (Object.entries(muscles) as [MuscleSlug, MuscleDetail][])
    .sort((a, b) => b[1].fatigue - a[1].fatigue)
    .slice(0, limit)
  return (
    <ul className="flex flex-col gap-4">
      {rows.map(([slug, m]) => (
        <MeterRow
          key={slug}
          label={t(MUSCLE_NAMES[slug])}
          value={`${fmtInt(m.fatigue * 100)}%`}
          fraction={m.fatigue}
          detail={m.hoursToRecovered > 0 ? t('Recovered in about {h} h', { h: fmtInt(m.hoursToRecovered) }) : t('Recovered')}
        />
      ))}
    </ul>
  )
}

export function MacroBreakdown({ avg, goals, summary }: { avg: Macros; goals: Macros; summary?: { label: string; value: string }[] }) {
  const { t } = useI18n()
  const kcalFrom = { protein: avg.protein * 4, carbs: avg.carbs * 4, fat: avg.fat * 9 }
  const total = kcalFrom.protein + kcalFrom.carbs + kcalFrom.fat || 1
  const parts = [
    { key: 'protein', label: t('Protein'), cls: 'bg-chart-1' },
    { key: 'carbs', label: t('Carbs'), cls: 'bg-chart-2' },
    { key: 'fat', label: t('Fat'), cls: 'bg-chart-4' },
  ] as const
  return (
    <div className="flex flex-1 flex-col gap-5">
      <div>
        <p className="mb-2 text-[12px] text-muted-foreground">{t('Share of calories')}</p>
        <div className="flex h-2.5 gap-0.5 overflow-hidden rounded-full" role="img"
          aria-label={parts.map((p) => `${p.label} ${fmtInt((kcalFrom[p.key] / total) * 100)}%`).join(', ')}>
          {parts.map((p) => <span key={p.key} className={p.cls} style={{ width: `${(kcalFrom[p.key] / total) * 100}%` }} />)}
        </div>
        <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[12px] text-muted-foreground">
          {parts.map((p) => (
            <span key={p.key} className="flex items-center gap-1.5">
              <span className={cn('size-2 rounded-full', p.cls)} aria-hidden />
              {p.label} <span className="text-foreground">{fmtInt((kcalFrom[p.key] / total) * 100)}%</span>
            </span>
          ))}
        </div>
      </div>
      <ul className="flex flex-col gap-4">
        <MeterRow label={t('Calories')} value={`${fmtInt(avg.kcal)} / ${fmtInt(goals.kcal)} kcal`} fraction={goals.kcal ? avg.kcal / goals.kcal : 0} />
        {parts.map((p) => (
          <MeterRow key={p.key} label={p.label} value={`${fmtInt(avg[p.key])} / ${fmtInt(goals[p.key])} g`} fraction={goals[p.key] ? avg[p.key] / goals[p.key] : 0} />
        ))}
      </ul>
      {summary && (
        <dl className="mt-auto grid grid-cols-3 border-t border-border pt-4">
          {summary.map((s, i) => (
            <div
              key={s.label}
              className={cn(
                'flex min-w-0 flex-col justify-between px-2.5',
                i === 0 ? 'pl-0' : 'border-l border-border',
                i === summary.length - 1 && 'pr-0',
              )}
            >
              <dt className="text-[11.5px] leading-snug text-muted-foreground">{s.label}</dt>
              <dd className="mt-1.5 text-[15px] font-medium whitespace-nowrap">{s.value}</dd>
            </div>
          ))}
        </dl>
      )}
    </div>
  )
}

/** A compact ranked list (the Figma side column): label, thin bar, value. */
export function RankList({ rows }: { rows: { label: string; value: number; display: string }[] }) {
  const max = Math.max(1, ...rows.map((r) => r.value))
  return (
    <ul className="flex flex-col gap-4">
      {rows.map((r) => <MeterRow key={r.label} label={r.label} value={r.display} fraction={r.value / max} />)}
    </ul>
  )
}
