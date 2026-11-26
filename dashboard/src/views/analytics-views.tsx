import { FatigueList, Fill, GranularityToggle, MacroBreakdown, Panel, RankList, TargetChart, TrendChart } from '@/components/charts'
import { KpiRow, type KpiSpec } from '@/components/kpi'
import { SessionsTable } from '@/components/sessions-table'
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'
import { useI18n } from '@/i18n'
import { RANGES, avg, muscleTargets, pctChange, select, series, sum, trailing, type RangeKey, type SplitFilter } from '@/lib/analytics'
import type { Granularity } from '@/lib/dates'
import { fmt1, fmt2, fmtInt } from '@/lib/format'
import type { ViewKey } from '@/nav'
import type { HexplateDataset, Macros, MuscleDetail, MuscleSlug, NutritionDay, Session } from '@/types/hexplate'
import { MUSCLES, MUSCLE_NAMES } from '@/types/hexplate'

const SPLIT_LABEL: Record<Session['split'], string> = {
  push: 'Push',
  pull: 'Pull',
  legs: 'Legs',
  upper: 'Upper',
  lower: 'Lower',
}

const avgMacros = (days: NutritionDay[]): Macros => ({
  kcal: avg(days.map((d) => d.totals.kcal)),
  protein: avg(days.map((d) => d.totals.protein)),
  carbs: avg(days.map((d) => d.totals.carbs)),
  fat: avg(days.map((d) => d.totals.fat)),
})

export function AnalyticsViews({
  view,
  data,
  range,
  split,
  granularity,
  onGranularity,
  onNavigate,
  onOpenWorkout,
  onSwitchSample,
}: {
  view: 'overview' | 'volume' | 'muscle-targets' | 'recovery' | 'nutrition' | 'sessions'
  data: HexplateDataset
  range: RangeKey
  split: SplitFilter
  granularity: Granularity
  onGranularity: (g: Granularity) => void
  onNavigate: (v: ViewKey) => void
  onOpenWorkout: (id: string) => void
  onSwitchSample?: () => void
}) {
  const { lang, t } = useI18n()
  const unitLabel = data.unit || 'kg'
  const fmtWeight = (v: number) => `${v >= 1000 ? `${fmt1(v / 1000)}k` : fmtInt(v)} ${unitLabel}`

  const sel = select(data, range, split)
  const { win } = sel
  const compareLabel = RANGES.find((r) => r.key === range)!.label
  const span = range === '7d' ? 1 : 7
  const spark = <T extends { d: string }>(rows: T[], f: (r: T) => number, agg: 'sum' | 'avg') => trailing(rows, f, win, agg, span)
  const kpi = (label: string, now: number, before: number, value: string, sparkline: (number | null)[], deltaText?: string): KpiSpec => ({
    label,
    value,
    delta: pctChange(now, before),
    deltaText,
    compareLabel,
    spark: sparkline,
  })

  const S = sel.sessions
  const P = sel.prevSessions
  const vol = sum(S.map((s) => s.vol))
  const prevVol = sum(P.map((s) => s.vol))
  const sets = sum(S.map((s) => s.workSets))
  const prevSets = sum(P.map((s) => s.workSets))
  const prs = sum(S.map((s) => s.prs))
  const hasReadiness = sel.readiness.length > 0
  const readiness = avg(sel.readiness.map((r) => r.score))
  const prevReadiness = avg(sel.prevReadiness.map((r) => r.score))
  const splitLabelText = split === 'all' ? t('All splits') : t(SPLIT_LABEL[split])
  const splitNote = split === 'all' ? t('All splits') : t('{split} sessions only', { split: splitLabelText })
  const splitScope = split === 'all' ? t('across all splits') : t('in {split} sessions only', { split: splitLabelText })

  const volumeKpi = kpi(t('Training volume'), vol, prevVol, fmtWeight(vol), spark([...P, ...S], (s) => s.vol, 'sum'))
  const sessionsKpi = kpi(t('Sessions'), S.length, P.length, fmtInt(S.length), spark([...P, ...S], () => 1, 'sum'))
  const setsKpi = kpi(t('Work sets'), sets, prevSets, fmtInt(sets), spark([...P, ...S], (s) => s.workSets, 'sum'))
  const readinessKpi = hasReadiness
    ? kpi(t('Avg readiness'), readiness, prevReadiness, fmtInt(readiness), spark([...sel.prevReadiness, ...sel.readiness], (r) => r.score, 'avg'))
    : kpi(
        t('Current streak'),
        data.weeklyProgress?.streak.current ?? 0,
        data.weeklyProgress?.streak.best ?? 0,
        t('{n} wk', { n: fmtInt(data.weeklyProgress?.streak.current ?? 0) }),
        spark([...P, ...S], (s) => s.workSets, 'sum'),
        data.weeklyProgress?.streak.best ? `${t('best {n}', { n: data.weeklyProgress.streak.best })}` : undefined,
      )

  const volumeChart = (
    <Panel
      title={t('Training volume')}
      description={t('Total {unit} lifted {scope}', { unit: unitLabel, scope: splitScope })}
      className="xl:col-span-1"
      action={<GranularityToggle value={granularity} onChange={onGranularity} />}
    >
      <Fill>
        <TrendChart points={series(S, (s) => s.vol, win, granularity, 'sum', lang)} kind="bar" unit={unitLabel} valueLabel={t('Volume')} height="100%" />
      </Fill>
    </Panel>
  )

  const targets = (
    <Panel title={t('Weekly sets vs target')} description={t('Average working sets per week for each muscle {scope}', { scope: splitScope })}>
      <TargetChart rows={muscleTargets(S, win.days)} />
    </Panel>
  )

  const nutritionAvg = avgMacros(sel.nutrition)
  const kcalDelta = nutritionAvg.kcal - data.goals.kcal
  const onGoalDays = sel.nutrition.filter((d) => data.goals.kcal > 0 && Math.abs(d.totals.kcal - data.goals.kcal) <= data.goals.kcal * 0.1).length
  const macroSummary = [
    { label: t('Protein per kg'), value: `${fmt1(data.bodyweightKg > 0 ? nutritionAvg.protein / data.bodyweightKg : 0)} g` },
    { label: t('Kcal vs goal'), value: `${kcalDelta >= 0 ? '+' : '\u2212'}${fmtInt(Math.abs(kcalDelta))} kcal` },
    { label: t('Days on goal'), value: `${fmtInt(sel.nutrition.length ? (onGoalDays / sel.nutrition.length) * 100 : 0)}%` },
  ]
  const macros = (
    <Panel title={t('Macros')} description={t('Daily average against your goals. A day is on goal within 10% of the calorie target.')}>
      {sel.nutrition.length > 0 ? (
        <MacroBreakdown avg={nutritionAvg} goals={data.goals} summary={macroSummary} />
      ) : (
        <p className="py-6 text-[13px] text-muted-foreground">{t('No meals logged in this period.')}</p>
      )}
    </Panel>
  )

  const fatigue = (limit?: number) => (
    <Panel title={t('Muscle fatigue')} description={t('Right now, highest first')}>
      <FatigueList muscles={data.recovery.muscles} limit={limit} />
    </Panel>
  )

  const primaryRow = (main: React.ReactNode, side: React.ReactNode) => (
    <div className="grid grid-cols-1 gap-4 xl:grid-cols-[minmax(0,1fr)_300px]">
      {main}
      {side}
    </div>
  )

  const emptyLocalBanner =
    data.source === 'local' && data.sessions.length === 0 ? (
      <Card className="flex flex-col gap-3 rounded-2xl px-5 py-4 shadow-none sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p className="text-[14px] font-medium">{t('No synced workouts yet')}</p>
          <p className="mt-0.5 text-[13px] text-muted-foreground">
            {t('Pair your iPhone in Sync & Backup to see your real data, or preview with sample data.')}
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2">
          <Button size="sm" onClick={() => onNavigate('sync-data')}>
            {t('Sync & Backup')}
          </Button>
          {onSwitchSample && (
            <Button size="sm" variant="outline" onClick={onSwitchSample}>
              {t('Switch to Sample data')}
            </Button>
          )}
        </div>
      </Card>
    ) : null

  switch (view) {
    case 'overview':
      return (
        <>
          {emptyLocalBanner}
          <KpiRow items={[volumeKpi, sessionsKpi, setsKpi, readinessKpi]} />
          {primaryRow(volumeChart, fatigue(5))}
          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            {targets}
            {macros}
          </div>
          <Panel title={t('Recent sessions')} description={splitNote}>
            <SessionsTable
              sessions={S}
              unitLabel={unitLabel}
              limit={8}
              onShowAll={() => onNavigate('sessions')}
              onSelectSession={onOpenWorkout}
            />
          </Panel>
        </>
      )

    case 'volume': {
      const perSession = S.length ? vol / S.length : 0
      const prevPerSession = P.length ? prevVol / P.length : 0
      const bySplit = (Object.keys(SPLIT_LABEL) as Session['split'][])
        .map((k) => ({ label: t(SPLIT_LABEL[k]), value: sum(S.filter((s) => s.split === k).map((s) => s.vol)) }))
        .filter((r) => r.value > 0)
        .sort((a, b) => b.value - a.value)
        .map((r) => ({ ...r, display: fmtWeight(r.value) }))
      return (
        <>
          {emptyLocalBanner}
          <KpiRow
            items={[
              volumeKpi,
              kpi(t('Volume per session'), perSession, prevPerSession, fmtWeight(perSession), spark([...P, ...S], (s) => s.vol, 'avg')),
              setsKpi,
              kpi(t('Personal records'), prs, sum(P.map((s) => s.prs)), fmtInt(prs), spark([...P, ...S], (s) => s.prs, 'sum')),
            ]}
          />
          {primaryRow(
            volumeChart,
            <Panel title={t('Volume by split')} description={t("Share of the period's work")}>
              {bySplit.length ? <RankList rows={bySplit} /> : <p className="text-[13px] text-muted-foreground">{t('No sessions in this period.')}</p>}
            </Panel>,
          )}
          {targets}
        </>
      )
    }

    case 'muscle-targets': {
      const rows = muscleTargets(S, win.days)
      const inRange = rows.filter((r) => r.status === 'in').length
      const below = rows.filter((r) => r.status === 'below').length
      const above = rows.filter((r) => r.status === 'above').length
      return (
        <>
          {emptyLocalBanner}
          <KpiRow
            items={[
              kpi(t('In range'), inRange, inRange, `${inRange} / ${rows.length}`, spark([...P, ...S], (s) => s.workSets, 'sum'), `${Math.round((inRange / rows.length) * 100)}%`),
              kpi(t('Below target'), below, below, fmtInt(below), spark([...P, ...S], (s) => s.workSets, 'sum'), `${below}`),
              kpi(t('Above target'), above, above, fmtInt(above), spark([...P, ...S], (s) => s.workSets, 'sum'), `${above}`),
              setsKpi,
            ]}
          />
          {primaryRow(targets, fatigue())}
        </>
      )
    }

    case 'recovery': {
      const sleep = avg(sel.readiness.map((r) => r.sleepHours))
      const hrv = avg(sel.readiness.map((r) => r.hrvMs))
      const ratio = data.recovery.global.ratio ?? avg(sel.loadRatio.map((r) => r.ratio))
      const prevRatio = avg(sel.prevLoadRatio.map((r) => r.ratio))
      const ratioDelta = ratio - prevRatio
      // Matches FatigueList predicate (`hoursToRecovered > 0`) on the exact same `data.recovery.muscles`.
      const recovering = (Object.entries(data.recovery.muscles) as [MuscleSlug, MuscleDetail][])
        .filter(([, m]) => m.hoursToRecovered > 0)
        .sort((a, b) => b[1].fatigue - a[1].fatigue)
      const topRecovering = recovering[0]
      const recoveringDetail = topRecovering
        ? `${t(MUSCLE_NAMES[topRecovering[0]])} ${fmtInt(topRecovering[1].fatigue * 100)}%`
        : t('All muscles recovered')
      return (
        <>
          {emptyLocalBanner}
          <KpiRow
            items={[
              hasReadiness
                ? readinessKpi
                : kpi(
                    t('Recovering muscles'),
                    recovering.length,
                    recovering.length,
                    `${recovering.length} / ${MUSCLES.length}`,
                    spark([...P, ...S], (s) => s.workSets, 'sum'),
                    recoveringDetail,
                  ),
              hasReadiness
                ? kpi(t('Avg sleep'), sleep, avg(sel.prevReadiness.map((r) => r.sleepHours)), `${fmt1(sleep)} h`, spark([...sel.prevReadiness, ...sel.readiness], (r) => r.sleepHours, 'avg'))
                : kpi(t('Work sets'), sets, prevSets, fmtInt(sets), spark([...P, ...S], (s) => s.workSets, 'sum')),
              hasReadiness
                ? kpi(t('Avg HRV'), hrv, avg(sel.prevReadiness.map((r) => r.hrvMs)), `${fmtInt(hrv)} ms`, spark([...sel.prevReadiness, ...sel.readiness], (r) => r.hrvMs, 'avg'))
                : kpi(t('Sessions'), S.length, P.length, fmtInt(S.length), spark([...P, ...S], () => 1, 'sum')),
              kpi(
                t('Acute : chronic load'),
                ratio,
                prevRatio,
                fmt2(ratio),
                spark([...sel.prevLoadRatio, ...sel.loadRatio], (r) => r.ratio, 'avg'),
                `${ratioDelta >= 0 ? '+' : '\u2212'}${fmt2(Math.abs(ratioDelta))}`,
              ),
            ]}
          />
          {primaryRow(
            <div className="flex flex-col gap-4 md:gap-5">
              <Panel
                title={t('Readiness')}
                description={t('Average morning score; the dashed line at 70 means ready to train. Not affected by the split filter.')}
                action={hasReadiness ? <GranularityToggle value={granularity} onChange={onGranularity} /> : undefined}
              >
                {hasReadiness ? (
                  <TrendChart points={series(sel.readiness, (r) => r.score, win, granularity, 'avg', lang)} kind="line" unit="" valueLabel={t('Readiness')} goal={70} yDomain={[0, 100]} />
                ) : (
                  <p className="py-6 text-[13px] text-muted-foreground">
                    {t('Readiness metrics come from Apple Health on your iPhone and are not stored in the server database.')}
                  </p>
                )}
              </Panel>
              <Panel
                title={t('Training load balance')}
                description={t('7-day load against the 28-day weekly average. The shaded zone, 0.8 to 1.3, is where most progress happens safely.')}
                className="flex-1"
                action={<GranularityToggle value={granularity} onChange={onGranularity} />}
              >
                <Fill>
                  <TrendChart points={series(sel.loadRatio, (r) => r.ratio, win, granularity, 'avg', lang)} kind="line" unit="" valueLabel={t('Load ratio')} band={[0.8, 1.3]} yDomain={[0.4, 1.8]} height="100%" />
                </Fill>
              </Panel>
            </div>,
            fatigue(),
          )}
        </>
      )
    }

    case 'nutrition': {
      const prevAvg = avgMacros(sel.prevNutrition)
      const hit = (days: NutritionDay[]) => (days.length && data.goals.protein > 0 ? (days.filter((d) => d.totals.protein >= data.goals.protein).length / days.length) * 100 : 0)
      const hitNow = hit(sel.nutrition)
      const hitDelta = hitNow - hit(sel.prevNutrition)
      const meals = avg(sel.nutrition.map((d) => d.meals))
      return (
        <>
          <KpiRow
            items={[
              kpi(t('Avg calories'), nutritionAvg.kcal, prevAvg.kcal, `${fmtInt(nutritionAvg.kcal)} kcal`, spark([...sel.prevNutrition, ...sel.nutrition], (d) => d.totals.kcal, 'avg')),
              kpi(t('Avg protein'), nutritionAvg.protein, prevAvg.protein, `${fmtInt(nutritionAvg.protein)} g`, spark([...sel.prevNutrition, ...sel.nutrition], (d) => d.totals.protein, 'avg')),
              kpi(
                t('Protein goal met'),
                hitNow,
                hit(sel.prevNutrition),
                `${fmtInt(hitNow)}%`,
                spark([...sel.prevNutrition, ...sel.nutrition], (d) => (d.totals.protein >= data.goals.protein ? 100 : 0), 'avg'),
                `${hitDelta >= 0 ? '+' : '\u2212'}${fmtInt(Math.abs(hitDelta))} pts`,
              ),
              kpi(t('Meals per day'), meals, avg(sel.prevNutrition.map((d) => d.meals)), fmt1(meals), spark([...sel.prevNutrition, ...sel.nutrition], (d) => d.meals, 'avg')),
            ]}
          />
          {primaryRow(
            <Panel
              title={t('Calories')}
              description={t('Daily average; the dashed line is your {kcal} kcal goal. Not affected by the split filter.', { kcal: fmtInt(data.goals.kcal) })}
              action={<GranularityToggle value={granularity} onChange={onGranularity} />}
            >
              <Fill>
                <TrendChart points={series(sel.nutrition, (d) => d.totals.kcal, win, granularity, 'avg', lang)} kind="line" unit="kcal" valueLabel={t('Calories')} goal={data.goals.kcal} height="100%" />
              </Fill>
            </Panel>,
            macros,
          )}
          <Panel title={t('Protein')} description={t('Daily average; the dashed line is your {g} g goal.', { g: fmtInt(data.goals.protein) })}>
            <TrendChart points={series(sel.nutrition, (d) => d.totals.protein, win, granularity, 'avg', lang)} kind="line" unit="g" valueLabel={t('Protein')} goal={data.goals.protein} height={220} />
          </Panel>
        </>
      )
    }

    case 'sessions': {
      const minutes = avg(S.map((s) => s.minutes))
      const setsPer = S.length ? sets / S.length : 0
      return (
        <>
          {emptyLocalBanner}
          <KpiRow
            items={[
              sessionsKpi,
              kpi(t('Avg duration'), minutes, avg(P.map((s) => s.minutes)), t('{n} min', { n: fmtInt(minutes) }), spark([...P, ...S], (s) => s.minutes, 'avg')),
              kpi(t('Sets per session'), setsPer, P.length ? prevSets / P.length : 0, fmt1(setsPer), spark([...P, ...S], (s) => s.workSets, 'avg')),
              kpi(t('Personal records'), prs, sum(P.map((s) => s.prs)), fmtInt(prs), spark([...P, ...S], (s) => s.prs, 'sum')),
            ]}
          />
          <Panel title={t('All sessions')} description={splitNote}>
            <SessionsTable sessions={S} unitLabel={unitLabel} onSelectSession={onOpenWorkout} />
          </Panel>
        </>
      )
    }
  }
}
