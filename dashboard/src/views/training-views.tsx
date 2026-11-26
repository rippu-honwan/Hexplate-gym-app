import { useEffect, useMemo, useRef, useState } from 'react'
import { ArrowLeft, ChevronRight, Cpu, Printer, Search } from 'lucide-react'
import { Bar, BarChart, CartesianGrid, Line, LineChart, ReferenceLine, Tooltip, XAxis, YAxis } from 'recharts'
import { Panel, RankList, TargetChart, TooltipBox } from '@/components/charts'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { useI18n } from '@/i18n'
import { muscleTargets } from '@/lib/analytics'
import { api } from '@/lib/api'
import { shortDate, weekdayDate, weekdayShort } from '@/lib/dates'
import { fmt1, fmtCompact, fmtInt } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { ExerciseDetail, HexplateDataset, ReportData, WorkoutDetail } from '@/types/hexplate'

const AXIS = { fontSize: 11, fill: 'var(--muted-foreground)' }

function StatTile({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <Card className="gap-1 rounded-2xl px-5 py-4 shadow-none">
      <p className="text-[12.5px] text-muted-foreground">{label}</p>
      <p className="text-[24px] leading-tight font-medium">{value}</p>
      {sub && <p className="text-[12px] text-muted-foreground">{sub}</p>}
    </Card>
  )
}

export function WorkoutDetailView({
  workoutId,
  readOnlySample,
  onBack,
  onOpenExercise,
  onOpenMotion,
}: {
  workoutId: string
  readOnlySample: boolean
  onBack: () => void
  onOpenExercise: (exId: string) => void
  onOpenMotion: (wid: string) => void
}) {
  const { lang, t } = useI18n()
  const [detail, setDetail] = useState<WorkoutDetail | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (readOnlySample) return
    let active = true
    setDetail(null)
    setError(null)
    api
      .workoutDetail(workoutId)
      .then((d) => active && setDetail(d))
      .catch((e: Error) => active && setError(e.message))
    return () => {
      active = false
    }
  }, [workoutId, readOnlySample])

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="ghost" size="sm" onClick={onBack}>
          <ArrowLeft className="mr-1 size-4" aria-hidden />
          {t('Back to Sessions')}
        </Button>
        {detail?.hasMotion && (
          <Button variant="outline" size="sm" className="ml-auto" onClick={() => onOpenMotion(detail.id)}>
            <Cpu className="mr-1.5 size-4" aria-hidden />
            {t('Inspect Motion Data')}
          </Button>
        )}
      </div>

      {readOnlySample && (
        <Panel title={t('Workout detail')}>
          <p className="text-[13px] text-muted-foreground">{t('Switch to Local data')} — {t('Standalone preview — connect to the Hexplate server for live data and write actions.')}</p>
        </Panel>
      )}
      {error && (
        <Panel title={t('Not found')}>
          <p className="text-[13px] text-muted-foreground">{error}</p>
        </Panel>
      )}
      {detail && (
        <>
          <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
            <StatTile label={t('Date')} value={weekdayDate(detail.date, lang)} sub={detail.name} />
            <StatTile label={t('Volume')} value={`${fmtInt(detail.volume)} ${detail.unit}`} sub={t('{n} sets', { n: detail.workSets })} />
            <StatTile label={t('Duration')} value={detail.minutes ? t('{n} min', { n: detail.minutes }) : '—'} />
            <StatTile
              label={t('Body weight')}
              value={detail.bodyweight !== null ? `${fmt1(detail.bodyweight)} ${detail.unit}` : '—'}
              sub={detail.prsCount > 0 ? t('{n} PR', { n: detail.prsCount }) : undefined}
            />
          </div>

          {detail.note && (
            <Panel title={t('Note')}>
              <p className="whitespace-pre-wrap text-[13.5px]">{detail.note}</p>
            </Panel>
          )}

          <div className="flex flex-col gap-4">
            {detail.entries.map((entry) => (
              <Panel
                key={`${entry.id}-${entry.name}`}
                title={entry.name}
                description={
                  entry.best
                    ? t('best {w} × {r} · e1RM {e}', { w: `${entry.best.weight} ${detail.unit}`, r: entry.best.reps, e: `${fmt1(entry.best.e1rm)} ${detail.unit}` })
                    : undefined
                }
                action={
                  <div className="flex items-center gap-2">
                    {entry.isPr && <Badge className="rounded-full bg-primary/15 text-primary hover:bg-primary/15">{t('PR')}</Badge>}
                    <Button variant="ghost" size="sm" onClick={() => onOpenExercise(entry.id)}>
                      {t('Estimated 1RM')}
                      <ChevronRight className="ml-1 size-3.5" aria-hidden />
                    </Button>
                  </div>
                }
              >
                <Table>
                  <TableHeader>
                    <TableRow className="hover:bg-transparent">
                      <TableHead className="w-20 text-[12px]">{t('Set')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Weight')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Reps')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('RIR')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Heart rate')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {entry.sets.map((s, idx) => (
                      <TableRow key={idx} className={cn(s.warmup && 'text-muted-foreground', !s.done && 'line-through opacity-60')}>
                        <TableCell className="text-[13px]">
                          {s.warmup ? (
                            <span className="inline-flex items-center gap-1.5">
                              <span className="inline-grid size-5 place-items-center rounded bg-muted text-[11px] font-semibold">W</span>
                              <span>{t('Warm-up')}</span>
                            </span>
                          ) : (
                            `#${s.index ?? idx + 1}`
                          )}
                          {s.side ? ` (${s.side === 'L' ? t('Left') : t('Right')})` : ''}
                        </TableCell>
                        <TableCell className="text-right text-[13px]">{s.weight !== null ? `${s.weight} ${detail.unit}` : '—'}</TableCell>
                        <TableCell className="text-right text-[13px]">
                          {s.reps !== null ? s.reps : s.sec !== null ? `${s.sec}s` : s.min !== null ? `${s.min}m` : '—'}
                        </TableCell>
                        <TableCell className="text-right text-[13px]">{s.rir !== null ? s.rir : '—'}</TableCell>
                        <TableCell className="text-right text-[13px]">{s.hrAvg !== null ? `${fmtInt(s.hrAvg)} bpm` : '—'}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              </Panel>
            ))}
          </div>
        </>
      )}
    </div>
  )
}

export function PlanView({ data }: { data: HexplateDataset }) {
  const { lang, t } = useI18n()
  const plan = data.plan
  const unit = data.unit || 'kg'

  if (!plan) {
    return (
      <Panel title={t('Plan & Routines')}>
        <p className="text-[13px] text-muted-foreground">{t('No routines yet. Make one on the phone.')}</p>
      </Panel>
    )
  }

  return (
    <div className="flex flex-col gap-5">
      <Panel
        title={t('Weekly schedule')}
        description={plan.mode === 'rotation' ? t('rotation') : t('weekly plan')}
        action={
          <Badge variant="outline" className="rounded-full">
            {plan.mode === 'rotation' ? t('rotation') : t('weekly plan')}
          </Badge>
        }
      >
        <div className="grid grid-cols-1 gap-2.5 sm:grid-cols-2 lg:grid-cols-7">
          {plan.weekDays.map((day) => (
            <div
              key={day.date}
              className={cn(
                'flex flex-col gap-1.5 rounded-xl border border-border p-3',
                day.isToday && 'border-primary/60 bg-primary/[0.04]',
              )}
            >
              <div className="flex items-center justify-between text-[12px]">
                <span className={cn('font-medium', day.isToday ? 'text-primary' : 'text-muted-foreground')}>
                  {weekdayShort(day.weekday, lang)}
                </span>
                <span className="text-muted-foreground">{shortDate(day.date, lang)}</span>
              </div>
              <p className={cn('text-[13.5px] font-medium leading-snug', day.isRest && 'font-normal text-muted-foreground')}>
                {day.isRest ? t('Rest day') : day.routineNames.join(' + ')}
              </p>
              <div className="mt-auto flex flex-wrap gap-1 pt-1">
                {day.isToday && (
                  <Badge variant="secondary" className="h-5 rounded-full px-2 text-[10.5px]">
                    {t('Today')}
                  </Badge>
                )}
                {day.isAIClone && (
                  <Badge className="h-5 rounded-full bg-primary/15 px-2 text-[10.5px] text-primary hover:bg-primary/15">
                    {t('AI adjusted')}
                  </Badge>
                )}
              </div>
            </div>
          ))}
        </div>
      </Panel>

      {plan.rotation && plan.rotation.sequence.length > 0 && (
        <Panel title={t('Rotation')} description={t('The loop the rotation works through, in order.')}>
          <div className="flex flex-wrap gap-2">
            {plan.rotation.sequence.map((step, idx) => {
              const isDone = plan.rotation!.doneIds.includes(step.id)
              return (
                <Badge
                  key={`${step.id}-${idx}`}
                  variant={isDone ? 'default' : 'outline'}
                  className="rounded-full px-3 py-1 text-[12.5px] font-normal"
                >
                  {idx + 1}. {step.isRest ? t('Rest') : step.name}
                </Badge>
              )
            })}
          </div>
        </Panel>
      )}

      <Panel title={t('Routines')} description={t('{n} routines', { n: plan.routines.length })}>
        {plan.routines.length === 0 ? (
          <p className="text-[13px] text-muted-foreground">{t('No routines yet. Make one on the phone.')}</p>
        ) : (
          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            {plan.routines.map((r) => (
              <Card key={r.id} className="gap-3 rounded-xl px-4 py-4 shadow-none">
                <div className="flex items-baseline justify-between gap-2">
                  <h3 className="text-[14.5px] font-semibold">{r.name}</h3>
                  <span className="text-[12px] text-muted-foreground">
                    {t('{n} exercises · {s} sets', { n: r.exerciseCount, s: r.totalSets })}
                  </span>
                </div>
                <ul className="divide-y divide-border text-[13px]">
                  {r.exercises.map((ex, i) => {
                    const repPart =
                      ex.mode === 'time' && ex.sec
                        ? `${ex.sec}s`
                        : ex.mode === 'cardio' && ex.min
                          ? `${ex.min}m`
                          : ex.repsMin && ex.repsMax
                            ? `${ex.repsMin}–${ex.repsMax}`
                            : ex.reps ?? '—'
                    return (
                      <li key={`${ex.id}-${i}`} className="flex items-baseline justify-between gap-3 py-2 first:pt-0 last:pb-0">
                        <div className="min-w-0">
                          <p className="truncate font-medium">{ex.name}</p>
                          {ex.note && <p className="truncate text-[12px] text-muted-foreground">{ex.note}</p>}
                        </div>
                        <span className="shrink-0 text-[12.5px] text-muted-foreground">
                          {ex.sets} × {repPart}
                          {ex.weight ? ` · ${ex.weight} ${unit}` : ''}
                        </span>
                      </li>
                    )
                  })}
                </ul>
              </Card>
            ))}
          </div>
        )}
      </Panel>
    </div>
  )
}

export function ExercisesView({
  data,
  onOpenExercise,
}: {
  data: HexplateDataset
  onOpenExercise: (exId: string) => void
}) {
  const { lang, t } = useI18n()
  const [query, setQuery] = useState('')
  const unit = data.unit || 'kg'
  const list = useMemo(() => {
    const src = data.exercises ?? []
    const q = query.trim().toLowerCase()
    return q ? src.filter((e) => e.name.toLowerCase().includes(q) || e.id.toLowerCase().includes(q)) : src
  }, [data.exercises, query])

  return (
    <Panel title={t('Exercises & 1RM')} description={t('{n} trained, most recent first', { n: list.length })}>
      <div className="relative max-w-xs">
        <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
        <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder={t('Find an exercise')} className="h-8 pl-8" />
      </div>
      <Table>
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            <TableHead className="text-[12px]">{t('Exercise')}</TableHead>
            <TableHead className="text-right text-[12px]">{t('Sessions')}</TableHead>
            <TableHead className="text-right text-[12px]">{t('Best set')}</TableHead>
            <TableHead className="text-right text-[12px]">{t('Best e1RM')}</TableHead>
            <TableHead className="text-right text-[12px]">{t('Last time')}</TableHead>
            <TableHead className="w-8" />
          </TableRow>
        </TableHeader>
        <TableBody>
          {list.map((ex) => (
            <TableRow key={ex.id} className="cursor-pointer" onClick={() => onOpenExercise(ex.id)}>
              <TableCell className="text-[13px] font-medium">{ex.name}</TableCell>
              <TableCell className="text-right text-[13px]">{ex.sessions}</TableCell>
              <TableCell className="text-right text-[13px]">
                {ex.bestWeight !== null && ex.bestReps !== null ? `${ex.bestWeight} ${unit} × ${ex.bestReps}` : '—'}
              </TableCell>
              <TableCell className="text-right text-[13px] font-medium">{ex.bestE1rm !== null ? `${fmt1(ex.bestE1rm)} ${unit}` : '—'}</TableCell>
              <TableCell className="text-right text-[13px] text-muted-foreground">{shortDate(ex.lastDate, lang)}</TableCell>
              <TableCell className="text-right text-muted-foreground">
                <ChevronRight className="inline size-4" aria-hidden />
              </TableCell>
            </TableRow>
          ))}
          {list.length === 0 && (
            <TableRow>
              <TableCell colSpan={6} className="py-10 text-center text-[13px] text-muted-foreground">
                {t('No exercise matches.')}
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>
    </Panel>
  )
}

export function ExerciseDetailView({
  exerciseId,
  readOnlySample,
  onBack,
  onOpenWorkout,
}: {
  exerciseId: string
  readOnlySample: boolean
  onBack: () => void
  onOpenWorkout: (wid: string) => void
}) {
  const { lang, t } = useI18n()
  const [detail, setDetail] = useState<ExerciseDetail | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (readOnlySample) return
    let active = true
    api
      .exerciseDetail(exerciseId)
      .then((d) => active && setDetail(d))
      .catch((e: Error) => active && setError(e.message))
    return () => {
      active = false
    }
  }, [exerciseId, readOnlySample])

  const series = useMemo(
    () => (detail?.sessions ?? []).filter((s) => s.e1rm !== null).map((s) => ({ label: shortDate(s.d, lang), e1rm: s.e1rm! })),
    [detail, lang],
  )

  return (
    <div className="flex flex-col gap-4">
      <div>
        <Button variant="ghost" size="sm" onClick={onBack}>
          <ArrowLeft className="mr-1 size-4" aria-hidden />
          {t('Back to Exercises')}
        </Button>
      </div>
      {error && <Panel title={t('Not found')}><p className="text-[13px] text-muted-foreground">{error}</p></Panel>}
      {detail && (
        <>
          <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
            <StatTile label={t('Best e1RM')} value={detail.bestE1rm ? `${fmt1(detail.bestE1rm.est)} ${detail.unit}` : '—'} sub={detail.bestE1rm ? shortDate(detail.bestE1rm.d, lang) : undefined} />
            <StatTile label={t('Heaviest set')} value={detail.heaviest ? `${detail.heaviest.w} ${detail.unit} × ${detail.heaviest.r}` : '—'} sub={detail.heaviest ? shortDate(detail.heaviest.d, lang) : undefined} />
            <StatTile label={t('Sessions')} value={fmtInt(detail.sessionsCount)} sub={t('since {d}', { d: shortDate(detail.firstDate, lang) })} />
            <StatTile label={t('Last time')} value={shortDate(detail.lastDate, lang)} sub={detail.name} />
          </div>

          {series.length >= 2 && (
            <Panel title={t('Estimated 1RM per session')} description={t('Estimated 1RM uses the Epley formula, weight × (1 + reps / 30), on ticked working sets.')}>
              <LineChart responsive style={{ width: '100%', height: 240 }} data={series} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
                <CartesianGrid vertical={false} stroke="var(--border)" />
                <XAxis dataKey="label" tick={AXIS} tickLine={false} axisLine={false} minTickGap={24} />
                <YAxis tick={AXIS} tickLine={false} axisLine={false} width={44} domain={['auto', 'auto']} />
                <Tooltip
                  isAnimationActive={false}
                  wrapperStyle={{ outline: 'none' }}
                  cursor={{ stroke: 'var(--muted-foreground)', strokeWidth: 1, strokeOpacity: 0.6 }}
                  content={({ active, payload, label }) => {
                    const val = payload?.[0]?.value
                    if (!active || !payload?.length || typeof val !== 'number') return null
                    return <TooltipBox title={String(label ?? '')} rows={[[t('e1RM'), `${fmt1(val)} ${detail.unit}`]]} />
                  }}
                />
                <Line type="monotone" dataKey="e1rm" stroke="var(--chart-1)" strokeWidth={2} dot={{ r: 3 }} isAnimationActive={false} />
              </LineChart>
            </Panel>
          )}

          <Panel title={detail.name}>
            <Table>
              <TableHeader>
                <TableRow className="hover:bg-transparent">
                  <TableHead className="text-[12px]">{t('Date')}</TableHead>
                  <TableHead className="text-right text-[12px]">{t('Best set')}</TableHead>
                  <TableHead className="text-right text-[12px]">{t('e1RM')}</TableHead>
                  <TableHead className="text-right text-[12px]">{t('Sets')}</TableHead>
                  <TableHead className="text-right text-[12px]">{t('Volume')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {[...detail.sessions].reverse().map((s) => (
                  <TableRow key={`${s.workoutId}-${s.d}`} className="cursor-pointer" onClick={() => onOpenWorkout(s.workoutId)}>
                    <TableCell className="text-[13px]">
                      {weekdayDate(s.d, lang)}
                      {s.pr && <Badge className="ml-2 rounded-full bg-primary/15 text-primary hover:bg-primary/15">{t('PR')}</Badge>}
                    </TableCell>
                    <TableCell className="text-right text-[13px]">{s.weight !== null ? `${s.weight} ${detail.unit} × ${s.reps}` : '—'}</TableCell>
                    <TableCell className="text-right text-[13px] font-medium">{s.e1rm !== null ? `${fmt1(s.e1rm)} ${detail.unit}` : '—'}</TableCell>
                    <TableCell className="text-right text-[13px]">{s.sets}</TableCell>
                    <TableCell className="text-right text-[13px]">{fmtInt(s.volume)} {detail.unit}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </Panel>
        </>
      )}
    </div>
  )
}

export function BodyView({ data }: { data: HexplateDataset }) {
  const { lang, t } = useI18n()
  const [bwRange, setBwRange] = useState<'3m' | '1y' | 'all'>('3m')
  const body = data.body
  const unit = body?.unit || data.unit || 'kg'

  const filtered = useMemo(() => {
    const rows = body?.weighIns ?? []
    if (bwRange === 'all' || rows.length === 0) return rows
    const days = bwRange === '3m' ? 92 : 365
    const end = new Date(data.today + 'T12:00:00Z')
    end.setUTCDate(end.getUTCDate() - days)
    const cutoff = end.toISOString().slice(0, 10)
    return rows.filter((r) => r.d >= cutoff)
  }, [body, bwRange, data.today])

  if (!body || (body.weighIns.length === 0 && body.measurements.length === 0)) {
    return (
      <Panel title={t('Body & Measurements')}>
        <p className="text-[13px] text-muted-foreground">{t('No weigh-ins or measurements yet. Log them on the phone.')}</p>
      </Panel>
    )
  }

  const fmtSign = (v: number | null) => (v === null ? '—' : `${v >= 0 ? '+' : '\u2212'}${fmt1(Math.abs(v))} ${unit}`)

  return (
    <div className="flex flex-col gap-5">
      <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
        <StatTile label={t('Current weight')} value={body.latest ? `${fmt1(body.latest.w)} ${unit}` : '—'} sub={body.latest ? shortDate(body.latest.d, lang) : undefined} />
        <StatTile label={t('30d change')} value={fmtSign(body.delta30)} />
        <StatTile label={t('90d change')} value={fmtSign(body.delta90)} />
        <StatTile
          label={t('Goal weight')}
          value={body.goal !== null ? `${fmt1(body.goal)} ${unit}` : '—'}
          sub={body.goal !== null && body.latest ? t('{v} to go', { v: `${fmt1(Math.abs(body.latest.w - body.goal))} ${unit}` }) : undefined}
        />
      </div>

      <Panel
        title={t('Bodyweight trend')}
        description={t('{n} weigh-ins in this range.', { n: filtered.length })}
        action={
          <ToggleGroup type="single" value={bwRange} onValueChange={(v) => v && setBwRange(v as '3m' | '1y' | 'all')} variant="outline" size="sm" spacing={0}>
            <ToggleGroupItem value="3m" className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">{t('3 months')}</ToggleGroupItem>
            <ToggleGroupItem value="1y" className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">{t('1 year')}</ToggleGroupItem>
            <ToggleGroupItem value="all" className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">{t('All')}</ToggleGroupItem>
          </ToggleGroup>
        }
      >
        {filtered.length >= 2 ? (
          <LineChart responsive style={{ width: '100%', height: 240 }} data={filtered.map((r) => ({ label: shortDate(r.d, lang), w: r.w }))} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
            <CartesianGrid vertical={false} stroke="var(--border)" />
            <XAxis dataKey="label" tick={AXIS} tickLine={false} axisLine={false} minTickGap={24} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={44} domain={['auto', 'auto']} />
            {body.goal !== null && <ReferenceLine y={body.goal} stroke="var(--chart-2)" strokeDasharray="4 4" ifOverflow="extendDomain" />}
            <Tooltip
              isAnimationActive={false}
              wrapperStyle={{ outline: 'none' }}
              cursor={{ stroke: 'var(--muted-foreground)', strokeWidth: 1, strokeOpacity: 0.6 }}
              content={({ active, payload, label }) => {
                const val = payload?.[0]?.value
                if (!active || !payload?.length || typeof val !== 'number') return null
                return <TooltipBox title={String(label ?? '')} rows={[[t('Body weight'), `${fmt1(val)} ${unit}`]]} />
              }}
            />
            <Line type="monotone" dataKey="w" stroke="var(--chart-1)" strokeWidth={2} dot={false} isAnimationActive={false} />
          </LineChart>
        ) : (
          <p className="py-6 text-[13px] text-muted-foreground">{t('No weigh-ins yet.')}</p>
        )}
      </Panel>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Panel title={t('Measurements')}>
          {body.measurements.length === 0 ? (
            <p className="text-[13px] text-muted-foreground">{t('No body measurements recorded yet.')}</p>
          ) : (
            <Table>
              <TableHeader>
                <TableRow className="hover:bg-transparent">
                  <TableHead className="text-[12px]">{t('Measure')}</TableHead>
                  <TableHead className="text-right text-[12px]">{t('Latest')}</TableHead>
                  <TableHead className="text-right text-[12px]">{t('Since first')}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {body.measurements.map((m) => (
                  <TableRow key={m.key}>
                    <TableCell className="text-[13px] font-medium">{m.name}</TableCell>
                    <TableCell className="text-right text-[13px]">{m.latest} {m.unit}</TableCell>
                    <TableCell className="text-right text-[13px] text-muted-foreground">
                      {m.delta === null ? '—' : `${m.delta >= 0 ? '+' : '\u2212'}${fmt1(Math.abs(m.delta))} ${m.unit}`}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </Panel>

        <Panel title={t('Weigh-ins')} description={t('latest 20')}>
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead className="text-[12px]">{t('Date')}</TableHead>
                <TableHead className="text-right text-[12px]">{t('Weight')}</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {[...body.weighIns].reverse().slice(0, 20).map((r) => (
                <TableRow key={r.d}>
                  <TableCell className="text-[13px]">{weekdayDate(r.d, lang)}</TableCell>
                  <TableCell className="text-right text-[13px] font-medium">{fmt1(r.w)} {unit}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </Panel>
      </div>
    </div>
  )
}

export function StatsView({
  data,
  onOpenExercise,
}: {
  data: HexplateDataset
  onOpenExercise: (exId: string) => void
}) {
  const { lang, t } = useI18n()
  const heatmapRef = useRef<HTMLDivElement>(null)
  const unit = data.unit || 'kg'
  const stats = data.stats
  const heatmap = useMemo(() => {
    if (stats?.heatmap?.length) return stats.heatmap
    const byDay = new Map<string, { vol: number; count: number }>()
    for (const s of data.sessions) {
      const cur = byDay.get(s.d) ?? { vol: 0, count: 0 }
      cur.vol += s.vol
      cur.count += 1
      byDay.set(s.d, cur)
    }
    const out: { d: string; vol: number; count: number }[] = []
    const end = new Date(data.today + 'T12:00:00Z')
    for (let i = 370; i >= 0; i--) {
      const d = new Date(end)
      d.setUTCDate(end.getUTCDate() - i)
      const iso = d.toISOString().slice(0, 10)
      const hit = byDay.get(iso)
      out.push({ d: iso, vol: hit?.vol ?? 0, count: hit?.count ?? 0 })
    }
    return out
  }, [stats, data.sessions, data.today])

  const maxVol = Math.max(1, ...heatmap.map((h) => h.vol))
  const activeDays = heatmap.filter((h) => h.count > 0).length
  const totalVol = data.sessions.reduce((a, s) => a + s.vol, 0)
  const totalMins = data.sessions.reduce((a, s) => a + s.minutes, 0)
  const weeklyRows = stats?.weeklyVolume ?? []
  const topEx = stats?.topExercises ?? []
  const streak = data.weeklyProgress?.streak

  useEffect(() => {
    const el = heatmapRef.current
    if (el) el.scrollLeft = el.scrollWidth
  }, [heatmap.length])

  return (
    <div className="flex flex-col gap-5">
      <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
        <StatTile label={t('Active days')} value={fmtInt(activeDays)} sub={t('last 12 months')} />
        <StatTile label={t('Current streak')} value={t('{n} wk', { n: streak?.current ?? 0 })} sub={streak?.best ? t('best {n}', { n: streak.best }) : undefined} />
        <StatTile label={t('Training volume')} value={`${fmtCompact(totalVol)} ${unit}`} sub={t('{n} sessions', { n: data.sessions.length })} />
        <StatTile label={t('Time trained')} value={`${fmt1(totalMins / 60)} ${t('h')}`} />
      </div>

      <Panel title={t('Consistency')} description={t('{n} training days in the last year; darker days moved more weight.', { n: activeDays })}>
        <div ref={heatmapRef} className="overflow-x-auto pb-1">
          <div className="grid w-max grid-flow-col grid-rows-7 gap-1">
            {heatmap.map((cell) => {
              const lvl = cell.count === 0 ? 0 : Math.min(4, Math.ceil((cell.vol / maxVol) * 4))
              const bg =
                lvl === 0
                  ? 'bg-muted'
                  : lvl === 1
                    ? 'bg-primary/25'
                    : lvl === 2
                      ? 'bg-primary/50'
                      : lvl === 3
                        ? 'bg-primary/75'
                        : 'bg-primary'
              return (
                <div
                  key={cell.d}
                  title={`${cell.d}: ${cell.count ? `${fmtInt(cell.vol)} ${unit}` : t('Rest')}`}
                  className={cn('size-3 rounded-[3px]', bg)}
                />
              )
            })}
          </div>
        </div>
      </Panel>

      {weeklyRows.length > 0 && (
        <Panel title={t('Weekly volume')} description={t('last {n} weeks', { n: weeklyRows.length })}>
          <BarChart responsive style={{ width: '100%', height: 220 }} data={weeklyRows.map((w) => ({ label: shortDate(w.week, lang), vol: w.vol }))} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
            <CartesianGrid vertical={false} stroke="var(--border)" />
            <XAxis dataKey="label" tick={AXIS} tickLine={false} axisLine={false} minTickGap={20} />
            <YAxis tick={AXIS} tickLine={false} axisLine={false} width={44} tickFormatter={(v: number) => fmtCompact(v)} />
            <Tooltip
              isAnimationActive={false}
              wrapperStyle={{ outline: 'none' }}
              cursor={{ fill: 'var(--foreground)', fillOpacity: 0.05 }}
              content={({ active, payload, label }) => {
                const val = payload?.[0]?.value
                if (!active || !payload?.length || typeof val !== 'number') return null
                return <TooltipBox title={String(label ?? '')} rows={[[t('Volume'), `${fmtInt(val)} ${unit}`]]} />
              }}
            />
            <Bar dataKey="vol" fill="var(--chart-1)" radius={[3, 3, 0, 0]} maxBarSize={26} isAnimationActive={false} />
          </BarChart>
        </Panel>
      )}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Panel title={t('Muscle balance')} description={t('average sets a week')}>
          <TargetChart rows={muscleTargets(data.sessions.slice(-30), 28)} />
        </Panel>
        <Panel title={t('Most trained')} description={t('by working sets')}>
          {topEx.length > 0 ? (
            <div className="flex flex-col gap-3">
              <RankList rows={topEx.slice(0, 8).map((e) => ({ label: e.name, value: e.sets, display: t('{n} sets', { n: e.sets }) }))} />
              <div className="flex flex-wrap gap-1.5 pt-2">
                {topEx.slice(0, 6).map((e) => (
                  <Button key={e.id} variant="outline" size="sm" className="h-7 text-[12px]" onClick={() => onOpenExercise(e.id)}>
                    {e.name}
                  </Button>
                ))}
              </div>
            </div>
          ) : (
            <p className="text-[13px] text-muted-foreground">{t('No sets in this range.')}</p>
          )}
        </Panel>
      </div>
    </div>
  )
}

export function ReportView({
  readOnlySample,
  onOpenWorkout,
}: {
  readOnlySample: boolean
  onOpenWorkout: (wid: string) => void
}) {
  const { lang, t } = useI18n()
  const [range, setRange] = useState<'7d' | '4w' | '3m'>('4w')
  const [report, setReport] = useState<ReportData | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (readOnlySample) return
    let active = true
    setError(null)
    api
      .report(range)
      .then((d) => active && setReport(d))
      .catch((e: Error) => active && setError(e.message))
    return () => {
      active = false
    }
  }, [range, readOnlySample])

  const deltaLabel = (now: number, prev: number) => {
    if (!prev) return undefined
    const diff = now - prev
    const pct = Math.round((Math.abs(diff) / prev) * 100)
    return `${diff >= 0 ? '+' : '\u2212'}${pct}% ${t('vs before')}`
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="no-print flex flex-wrap items-center justify-between gap-3">
        <ToggleGroup type="single" value={range} onValueChange={(v) => v && setRange(v as '7d' | '4w' | '3m')} variant="outline" size="sm" spacing={0}>
          <ToggleGroupItem value="7d" className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">{t('7 days')}</ToggleGroupItem>
          <ToggleGroupItem value="4w" className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">{t('4 weeks')}</ToggleGroupItem>
          <ToggleGroupItem value="3m" className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">{t('3 months')}</ToggleGroupItem>
        </ToggleGroup>
        <Button size="sm" variant="outline" onClick={() => window.print()}>
          <Printer className="mr-1.5 size-4" aria-hidden />
          {t('Print / Save PDF')}
        </Button>
      </div>

      {readOnlySample && (
        <Panel title={t('Training Report')}>
          <p className="text-[13px] text-muted-foreground">{t('Standalone preview — connect to the Hexplate server for live data and write actions.')}</p>
        </Panel>
      )}
      {error && <Panel title={t('Training Report')}><p className="text-[13px] text-destructive">{error}</p></Panel>}
      {report && (
        <>
          <p className="text-[13px] text-muted-foreground">
            {t('{a} – {b} · {n} days, compared with the {n} days before', { a: shortDate(report.from, lang), b: shortDate(report.to, lang), n: report.days })}
          </p>
          <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
            <StatTile label={t('Workouts')} value={fmtInt(report.current.workouts)} sub={deltaLabel(report.current.workouts, report.previous.workouts)} />
            <StatTile label={t('Volume')} value={`${fmtInt(report.current.volume)} ${report.unit}`} sub={deltaLabel(report.current.volume, report.previous.volume)} />
            <StatTile label={t('Working sets')} value={fmtInt(report.current.sets)} sub={deltaLabel(report.current.sets, report.previous.sets)} />
            <StatTile label={t('Time trained')} value={t('{n} min', { n: report.current.minutes })} sub={deltaLabel(report.current.minutes, report.previous.minutes)} />
          </div>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Panel title={t('Records')} description={t('{n} new', { n: report.records.length })}>
              {report.records.length === 0 ? (
                <p className="text-[13px] text-muted-foreground">{t('No records in this range.')}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow className="hover:bg-transparent">
                      <TableHead className="text-[12px]">{t('Exercise')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Set')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('e1RM')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {report.records.map((r, i) => (
                      <TableRow key={`${r.workoutId}-${r.exerciseId}-${i}`}>
                        <TableCell className="text-[13px] font-medium">{r.exercise}</TableCell>
                        <TableCell className="text-right text-[13px]">{r.weight !== null ? `${r.weight} ${report.unit} × ${r.reps}` : '—'}</TableCell>
                        <TableCell className="text-right text-[13px]">{r.e1rm !== null ? `${fmt1(r.e1rm)} ${report.unit}` : '—'}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </Panel>

            <Panel title={t('Muscles worked')} description={t('effective working sets')}>
              {report.muscles.length === 0 ? (
                <p className="text-[13px] text-muted-foreground">{t('No working sets.')}</p>
              ) : (
                <RankList rows={report.muscles.map((m) => ({ label: m.name, value: m.sets, display: `${fmt1(m.sets)}` }))} />
              )}
            </Panel>
          </div>

          <Panel title={t('Every workout')}>
            {report.workouts.length === 0 ? (
              <p className="text-[13px] text-muted-foreground">{t('No workouts in this range.')}</p>
            ) : (
              <Table>
                <TableHeader>
                  <TableRow className="hover:bg-transparent">
                    <TableHead className="text-[12px]">{t('Date')}</TableHead>
                    <TableHead className="text-[12px]">{t('Workout')}</TableHead>
                    <TableHead className="text-right text-[12px]">{t('Time')}</TableHead>
                    <TableHead className="text-right text-[12px]">{t('Sets')}</TableHead>
                    <TableHead className="text-right text-[12px]">{t('Volume')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {report.workouts.map((w) => (
                    <TableRow key={w.id} className="cursor-pointer" onClick={() => onOpenWorkout(w.id)}>
                      <TableCell className="whitespace-nowrap text-[13px]">{weekdayDate(w.date, lang)}</TableCell>
                      <TableCell className="text-[13px]">
                        <span className="font-medium">{w.name}</span>
                        <span className="block text-[12px] text-muted-foreground">{w.exercises.join(', ')}</span>
                      </TableCell>
                      <TableCell className="text-right text-[13px]">{w.minutes ? t('{n} min', { n: w.minutes }) : '—'}</TableCell>
                      <TableCell className="text-right text-[13px]">{w.sets}</TableCell>
                      <TableCell className="text-right text-[13px]">{fmtInt(w.volume)} {report.unit}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </Panel>
        </>
      )}
    </div>
  )
}
