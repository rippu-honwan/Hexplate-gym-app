import { useEffect, useState } from 'react'
import { ArrowLeft, ChevronRight } from 'lucide-react'
import {
  CartesianGrid,
  Line,
  LineChart,
  ReferenceLine,
  Scatter,
  ScatterChart,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import { Panel, TooltipBox } from '@/components/charts'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { useI18n } from '@/i18n'
import { api } from '@/lib/api'
import { weekdayDate } from '@/lib/dates'
import { fmt2, fmtCompact, fmtInt } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { HexplateDataset, MotionDetail } from '@/types/hexplate'

const AXIS = { fontSize: 11, fill: 'var(--muted-foreground)' }

function Tile({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <Card className="gap-1 rounded-2xl px-5 py-4 shadow-none">
      <p className="text-[12.5px] text-muted-foreground">{label}</p>
      <p className="text-[24px] leading-tight font-medium">{value}</p>
      {sub && <p className="text-[12px] text-muted-foreground">{sub}</p>}
    </Card>
  )
}

export function RepCounterView({ data }: { data: HexplateDataset }) {
  const { lang, t } = useI18n()
  const locale = lang === 'zh' ? 'zh-Hant' : 'en-US'
  const reps = data.reps
  if (!reps || reps.setsRecorded === 0) {
    return (
      <Panel title={t('Rep Counter')} description={t('How well the watch counts your reps')}>
        <p className="text-[13px] text-muted-foreground">{t('No motion files yet.')}</p>
      </Panel>
    )
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
        <Tile label={t('Sets recorded')} value={fmtInt(reps.setsRecorded)} sub={t('{n} exercises', { n: reps.exercisesCount })} />
        <Tile label={t('Confirmed')} value={fmtInt(reps.confirmed)} sub={t('counts checked on the watch')} />
        <Tile
          label={t('Exact')}
          value={reps.exactPct !== null ? `${reps.exactPct}%` : '—'}
          sub={t('{a} of {b} counted right', { a: reps.exact, b: reps.confirmed })}
        />
        <Tile label={t('Mean error')} value={reps.mae !== null ? `${fmt2(reps.mae)} ${t('reps')}` : '—'} sub={t('live count vs confirmed')} />
      </div>

      <Panel title={t('By exercise')}>
        <Table>
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              <TableHead className="text-[12px]">{t('Exercise')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Sets')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Checked')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Exact')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Error')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {reps.byExercise.map((r) => (
              <TableRow key={r.id}>
                <TableCell className="text-[13px] font-medium">{r.name}</TableCell>
                <TableCell className="text-right text-[13px]">{r.sets}</TableCell>
                <TableCell className="text-right text-[13px]">{r.checked}</TableCell>
                <TableCell className="text-right text-[13px]">{r.checked ? `${r.exact}/${r.checked}` : '—'}</TableCell>
                <TableCell className="text-right text-[13px]">{r.mae !== null ? fmt2(r.mae) : '—'}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </Panel>

      <Panel title={t('Latest sets')}>
        <Table>
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              <TableHead className="text-[12px]">{t('When')}</TableHead>
              <TableHead className="text-[12px]">{t('Exercise')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Weight')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Live')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Final')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Off')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {reps.latest.map((r, idx) => (
              <TableRow key={`${r.atMs}-${idx}`}>
                <TableCell className="whitespace-nowrap text-[13px] text-muted-foreground">
                  {new Date(r.atMs).toLocaleString(locale)}
                </TableCell>
                <TableCell className="text-[13px] font-medium">{r.exercise}</TableCell>
                <TableCell className="text-right text-[13px]">{r.weight !== null ? `${r.weight} kg` : '—'}</TableCell>
                <TableCell className="text-right text-[13px]">{r.auto ?? '—'}</TableCell>
                <TableCell className="text-right text-[13px]">{r.final ?? '—'}</TableCell>
                <TableCell className={cn('text-right text-[13px] font-medium', r.off !== null && r.off !== 0 && 'text-destructive')}>
                  {r.off === null ? '—' : r.off === 0 ? '0' : `${r.off > 0 ? '+' : ''}${r.off}`}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </Panel>
    </div>
  )
}

export function MotionListView({
  data,
  onOpenMotion,
}: {
  data: HexplateDataset
  onOpenMotion: (wid: string) => void
}) {
  const { lang, t } = useI18n()
  const motion = data.motion
  const rows = motion?.workouts ?? []

  return (
    <Panel title={t('Motion Data')} description={t('What the watch recorded in each workout')}>
      {rows.length === 0 ? (
        <p className="text-[13px] text-muted-foreground">{t('No motion data recorded yet.')}</p>
      ) : (
        <Table>
          <TableHeader>
            <TableRow className="hover:bg-transparent">
              <TableHead className="text-[12px]">{t('Date')}</TableHead>
              <TableHead className="text-[12px]">{t('Workout')}</TableHead>
              <TableHead className="text-right text-[12px]">{t('Sets')}</TableHead>
              <TableHead className="w-8" />
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((w) => (
              <TableRow key={w.id} className="cursor-pointer" onClick={() => onOpenMotion(w.id)}>
                <TableCell className="whitespace-nowrap text-[13px]">{weekdayDate(w.date, lang)}</TableCell>
                <TableCell className="text-[13px]">
                  <span className="font-medium">{w.name}</span>
                  <span className="block text-[12px] text-muted-foreground">{w.exercisesSummary}</span>
                </TableCell>
                <TableCell className="text-right text-[13px]">{t('{n} sets', { n: w.fileCount })}</TableCell>
                <TableCell className="text-right text-muted-foreground">
                  <ChevronRight className="inline size-4" aria-hidden />
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
      {motion && motion.unlinkedCount > 0 && (
        <p className="text-[12px] text-muted-foreground">
          {t('{n} set files belong to no saved workout.', { n: motion.unlinkedCount })}
        </p>
      )}
    </Panel>
  )
}

function SetMetricChart({
  title,
  points,
  refY,
  unit,
}: {
  title: string
  points: { label: string; exercise: string; value: number; flagged: boolean }[]
  refY: number
  unit: string
}) {
  return (
    <Panel title={title}>
      <LineChart responsive style={{ width: '100%', height: 210 }} data={points} margin={{ top: 8, right: 8, bottom: 0, left: 0 }}>
        <CartesianGrid vertical={false} stroke="var(--border)" />
        <XAxis dataKey="label" tick={AXIS} tickLine={false} axisLine={false} />
        <YAxis tick={AXIS} tickLine={false} axisLine={false} width={44} />
        <ReferenceLine y={refY} stroke="var(--chart-2)" strokeDasharray="4 4" ifOverflow="extendDomain" />
        <Tooltip
          isAnimationActive={false}
          wrapperStyle={{ outline: 'none' }}
          cursor={{ stroke: 'var(--muted-foreground)', strokeWidth: 1, strokeOpacity: 0.6 }}
          content={({ active, payload }) => {
            const pt = payload?.[0]?.payload as { label: string; exercise: string; value: number } | undefined
            if (!active || !payload?.length || !pt || typeof pt.value !== 'number') return null
            return (
              <TooltipBox
                title={`${pt.label} · ${pt.exercise}`}
                rows={[[title, `${pt.value}${unit ? ` ${unit}` : ''}`]]}
              />
            )
          }}
        />
        <Line type="monotone" dataKey="value" stroke="var(--chart-1)" strokeWidth={1.8} dot={{ r: 3.5 }} isAnimationActive={false} />
      </LineChart>
    </Panel>
  )
}

export function MotionDetailView({
  workoutId,
  readOnlySample,
  onBack,
  onOpenWorkout,
}: {
  workoutId: string
  readOnlySample: boolean
  onBack: () => void
  onOpenWorkout: (wid: string) => void
}) {
  const { t } = useI18n()
  const [detail, setDetail] = useState<MotionDetail | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (readOnlySample) return
    let active = true
    api
      .motionDetail(workoutId)
      .then((d) => active && setDetail(d))
      .catch((e: Error) => active && setError(e.message))
    return () => {
      active = false
    }
  }, [workoutId, readOnlySample])

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="ghost" size="sm" onClick={onBack}>
          <ArrowLeft className="mr-1 size-4" aria-hidden />
          {t('Back to Motion Data')}
        </Button>
        {detail && (
          <Button variant="outline" size="sm" className="ml-auto" onClick={() => onOpenWorkout(detail.id)}>
            {t('Workout detail')}
          </Button>
        )}
      </div>
      {error && <Panel title={t('Not found')}><p className="text-[13px] text-muted-foreground">{error}</p></Panel>}
      {detail && (
        <>
          <div className="grid grid-cols-2 gap-4 xl:grid-cols-4">
            <Tile label={t('Sets recorded')} value={fmtInt(detail.summary.setsRecorded)} sub={t('{n} exercises', { n: detail.summary.exercisesCount })} />
            <Tile label={t('Clean sets')} value={fmtInt(detail.summary.cleanSets)} sub={t('no quality flag')} />
            <Tile label={t('Total duration')} value={t('{n} min', { n: Math.max(1, Math.round(detail.summary.durationSec / 60)) })} sub={t('of motion at 50 Hz')} />
            <Tile label={t('Total samples')} value={fmtCompact(detail.summary.totalRows)} sub={t('samples')} />
          </div>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Panel title={t('Overview & Quality Flags')}>
              <Table>
                <TableHeader>
                  <TableRow className="hover:bg-transparent">
                    <TableHead className="text-[12px]">{t('Exercise')}</TableHead>
                    <TableHead className="text-right text-[12px]">{t('Sets')}</TableHead>
                    <TableHead className="text-right text-[12px]">{t('Clean')}</TableHead>
                    <TableHead className="text-[12px]">{t('Flags')}</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {detail.exercises.map((e) => (
                    <TableRow key={e.exId}>
                      <TableCell className="text-[13px] font-medium">{e.index}. {e.name}</TableCell>
                      <TableCell className="text-right text-[13px]">{e.sets}</TableCell>
                      <TableCell className="text-right text-[13px]">{e.clean}</TableCell>
                      <TableCell className="text-[12px] text-muted-foreground">{e.flags.join(', ') || '—'}</TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            </Panel>

            <Panel title={t('Flags')}>
              {detail.flags.length === 0 ? (
                <p className="text-[13px] text-muted-foreground">{t('Every set is clean.')}</p>
              ) : (
                <div className="flex flex-wrap gap-2">
                  {detail.flags.map((f) => (
                    <Badge key={f.flag} variant="outline" className="rounded-full px-3 py-1">
                      {f.flag} · {f.count}
                    </Badge>
                  ))}
                </div>
              )}
            </Panel>
          </div>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <SetMetricChart title={t('Sample rate (Hz)')} points={detail.hzPoints} refY={50} unit="Hz" />
            <SetMetricChart title={t('Largest gap')} points={detail.gapPoints} refY={0.1} unit="s" />
          </div>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <SetMetricChart title={t('Head: first second')} points={detail.headPoints} refY={0.6} unit="" />
            <SetMetricChart title={t('Tail: last second')} points={detail.tailPoints} refY={0.6} unit="" />
          </div>

          <Panel title={t('3-Axis Acceleration Traces')} description={t('User acceleration (g) and its smoothed magnitude; ticks: reps the watch counted live.')}>
            <div className="flex flex-col gap-5">
              {detail.traces.map((tr) => (
                <div key={tr.exId} className="rounded-xl border border-border p-4">
                  <p className="mb-3 text-[13.5px] font-medium">
                    {t('{name}: {reps} reps logged, {auto} counted live', {
                      name: tr.name,
                      reps: tr.reps ?? '—',
                      auto: tr.auto ?? '—',
                    })}
                  </p>
                  <LineChart responsive style={{ width: '100%', height: 200 }} data={tr.points} margin={{ top: 6, right: 8, bottom: 0, left: 0 }}>
                    <CartesianGrid vertical={false} stroke="var(--border)" />
                    <XAxis dataKey="t" tick={AXIS} tickLine={false} axisLine={false} unit="s" />
                    <YAxis tick={AXIS} tickLine={false} axisLine={false} width={38} />
                    {tr.ticks.map((tick, idx) => (
                      <ReferenceLine key={idx} x={tick} stroke="var(--chart-2)" strokeDasharray="3 3" />
                    ))}
                    <Tooltip
                      isAnimationActive={false}
                      wrapperStyle={{ outline: 'none' }}
                      cursor={{ stroke: 'var(--muted-foreground)', strokeWidth: 1, strokeOpacity: 0.6 }}
                      content={({ active, payload }) => {
                        const pt = payload?.[0]?.payload as { t: number; ax: number; ay: number; az: number; mag: number } | undefined
                        if (!active || !payload?.length || !pt) return null
                        return (
                          <TooltipBox
                            title={`${t('Time')}: ${fmt2(pt.t)} s`}
                            rows={[
                              [t('magnitude'), `${fmt2(pt.mag)} g`],
                              ['ax', `${fmt2(pt.ax)} g`],
                              ['ay', `${fmt2(pt.ay)} g`],
                              ['az', `${fmt2(pt.az)} g`],
                            ]}
                          />
                        )
                      }}
                    />
                    <Line type="monotone" dataKey="ax" stroke="#3b82f6" strokeWidth={1} dot={false} isAnimationActive={false} />
                    <Line type="monotone" dataKey="ay" stroke="#10b981" strokeWidth={1} dot={false} isAnimationActive={false} />
                    <Line type="monotone" dataKey="az" stroke="#f59e0b" strokeWidth={1} dot={false} isAnimationActive={false} />
                    <Line type="monotone" dataKey="mag" stroke="var(--chart-1)" strokeWidth={2} dot={false} isAnimationActive={false} />
                  </LineChart>
                </div>
              ))}
            </div>
          </Panel>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Panel title={t('Live Count vs Logged Reps')}>
              {detail.liveAccuracy.length === 0 ? (
                <p className="text-[13px] text-muted-foreground">{t('No clean sets with a live count.')}</p>
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow className="hover:bg-transparent">
                      <TableHead className="text-[12px]">{t('Exercise')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Sets')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Error')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Exact')}</TableHead>
                      <TableHead className="text-right text-[12px]">{t('Bias')}</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {detail.liveAccuracy.map((r) => (
                      <TableRow key={r.exId}>
                        <TableCell className="text-[13px] font-medium">{r.name}</TableCell>
                        <TableCell className="text-right text-[13px]">{r.sets}</TableCell>
                        <TableCell className="text-right text-[13px]">{fmt2(r.mae)}</TableCell>
                        <TableCell className="text-right text-[13px]">{r.exactPct}%</TableCell>
                        <TableCell className="text-right text-[13px]">{r.bias >= 0 ? `+${fmt2(r.bias)}` : fmt2(r.bias)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </Panel>

            <Panel title={t('Live count vs logged')}>
              {detail.scatter.length === 0 ? (
                <p className="text-[13px] text-muted-foreground">{t('No clean sets with a live count.')}</p>
              ) : (
                <ScatterChart responsive style={{ width: '100%', height: 220 }} margin={{ top: 8, right: 12, bottom: 0, left: 0 }}>
                  <CartesianGrid stroke="var(--border)" />
                  <XAxis type="number" dataKey="logged" name={t('logged reps')} tick={AXIS} tickLine={false} axisLine={false} />
                  <YAxis type="number" dataKey="live" name={t('live count')} tick={AXIS} tickLine={false} axisLine={false} width={36} />
                  <Tooltip
                    isAnimationActive={false}
                    wrapperStyle={{ outline: 'none' }}
                    cursor={{ strokeDasharray: '3 3', stroke: 'var(--muted-foreground)' }}
                    content={({ active, payload }) => {
                      const pt = payload?.[0]?.payload as { label: string; exercise: string; logged: number; live: number } | undefined
                      if (!active || !payload?.length || !pt) return null
                      return (
                        <TooltipBox
                          title={`${pt.label} · ${pt.exercise}`}
                          rows={[
                            [t('logged reps'), String(pt.logged)],
                            [t('live count'), String(pt.live)],
                          ]}
                        />
                      )
                    }}
                  />
                  <Scatter data={detail.scatter} fill="var(--chart-1)" isAnimationActive={false} />
                </ScatterChart>
              )}
            </Panel>
          </div>

          <Panel title={t('Diagnostic Findings')}>
            <ul className="list-disc space-y-1.5 pl-5 text-[13.5px]">
              {detail.findings.map((line, i) => (
                <li key={i}>{line}</li>
              ))}
            </ul>
          </Panel>
        </>
      )}
    </div>
  )
}
