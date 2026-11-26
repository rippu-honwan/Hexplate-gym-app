import { useCallback, useEffect, useState } from 'react'
import { ArrowRight, Bot, Check, Lock, RotateCcw, Send, Settings, Sparkles } from 'lucide-react'
import { Panel } from '@/components/charts'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'
import { useI18n } from '@/i18n'
import { api } from '@/lib/api'
import { shortDate, weekdayOfIso, weekdayShort } from '@/lib/dates'
import { fmtInt } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { AiConfigMasked, CoachContextSummary, CoachProposal, CoachUndoStatus } from '@/types/hexplate'
import { MUSCLE_NAMES, type MuscleSlug } from '@/types/hexplate'

const QUICK_PROMPTS = [
  'How is my weekly muscle balance and fatigue looking?',
  "Move tomorrow's workout to the day after tomorrow.",
  'Reduce sets by 1 on my most fatigued muscle next session.',
  'Suggest a lighter recovery tweak for my next training day.',
]

export function CoachView({
  readOnly,
  ai,
  initialUndo,
  onOpenAiSettings,
  onPlanMutated,
}: {
  readOnly: boolean
  ai: AiConfigMasked | null
  initialUndo: CoachUndoStatus | null
  onOpenAiSettings: () => void
  onPlanMutated: () => Promise<void>
}) {
  const { lang, t } = useI18n()
  const [summary, setSummary] = useState<CoachContextSummary | null>(null)
  const [rev, setRev] = useState<number | null>(null)
  const [undo, setUndo] = useState<CoachUndoStatus | null>(initialUndo)
  const [message, setMessage] = useState('')
  const [proposal, setProposal] = useState<CoachProposal | null>(null)
  const [asking, setAsking] = useState(false)
  const [applying, setApplying] = useState(false)
  const [undoing, setUndoing] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    setUndo(initialUndo)
  }, [initialUndo])

  const loadContext = useCallback(async () => {
    if (readOnly) return
    try {
      const ctx = await api.coachContext()
      setSummary(ctx.summary)
      setRev(ctx.rev)
      setUndo(ctx.undo)
      setError(null)
    } catch (e) {
      setError((e as Error).message)
    }
  }, [readOnly])

  useEffect(() => {
    void loadContext()
  }, [loadContext])

  const ask = async (promptText?: string) => {
    const q = (promptText ?? message).trim()
    if (!q || readOnly) return
    setAsking(true)
    setError(null)
    setNotice(null)
    try {
      const res = await api.coachPropose({ message: q, lang })
      setProposal(res)
      setSummary(res.summary)
      setRev(res.baseRev)
      if (!promptText) setMessage('')
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setAsking(false)
    }
  }

  const applyProposal = async () => {
    if (!proposal || !proposal.hasChanges || readOnly) return
    setApplying(true)
    setError(null)
    setNotice(null)
    try {
      const res = await api.coachApply({
        ops: proposal.changes,
        baseRev: proposal.baseRev,
        baseWid: proposal.baseWid,
        expectedDigests: proposal.expectedDigests,
        lang,
      })
      setProposal(null)
      setUndo(res.undo)
      setRev(res.rev)
      setNotice(t('Plan updated (rev {rev}). Your iPhone will merge these changes on its next sync.', { rev: res.rev }))
      await onPlanMutated()
      await loadContext()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setApplying(false)
    }
  }

  const doUndo = async () => {
    if (!undo || undo.status !== 'available' || readOnly) return
    setUndoing(true)
    setError(null)
    setNotice(null)
    try {
      const res = await api.coachUndo({ tokenId: undo.tokenId })
      setUndo(null)
      setRev(res.rev)
      setNotice(t('AI plan change undone (rev {rev}).', { rev: res.rev }))
      await onPlanMutated()
      await loadContext()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setUndoing(false)
    }
  }

  const muscleLabel = (slug: string) => t(MUSCLE_NAMES[slug as MuscleSlug] ?? slug)

  return (
    <div className="flex flex-col gap-5">
      {!readOnly && !ai?.configured && (
        <Card className="flex flex-col gap-3 rounded-2xl border-primary/30 bg-primary/[0.04] px-5 py-4 shadow-none sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-start gap-3">
            <Bot className="mt-0.5 size-5 shrink-0 text-primary" aria-hidden />
            <div>
              <p className="text-[14px] font-semibold">{t('AI Provider Not Configured')}</p>
              <p className="mt-0.5 text-[13px] text-muted-foreground">
                {t('Paste your AI API Base URL, Model, and API Key in Settings to activate your personal AI Coach.')}
              </p>
            </div>
          </div>
          <Button size="sm" onClick={onOpenAiSettings} className="shrink-0">
            <Settings className="mr-1.5 size-4" aria-hidden />
            {t('Open AI Settings')}
          </Button>
        </Card>
      )}

      {undo && (
        <Card className="flex flex-col gap-3 rounded-2xl px-5 py-3.5 shadow-none sm:flex-row sm:items-center sm:justify-between">
          <div>
            <p className="text-[13.5px] font-medium">{t('Last AI Plan Change')}</p>
            <p className="text-[12.5px] text-muted-foreground">
              {undo.status === 'available'
                ? undo.touchedDates.map((d) => shortDate(d)).join(', ')
                : t('Undo unavailable because a touched day is today or already has a logged workout.')}
            </p>
          </div>
          <Button size="sm" variant="outline" disabled={readOnly || undoing || undo.status !== 'available'} onClick={() => void doUndo()}>
            <RotateCcw className="mr-1.5 size-3.5" aria-hidden />
            {undoing ? t('Undoing…') : t('Undo Last Change')}
          </Button>
        </Card>
      )}

      {notice && <div className="rounded-xl border border-primary/35 bg-primary/[0.06] px-4 py-3 text-[13px]">{notice}</div>}
      {error && <div className="rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">{error}</div>}

      <Panel
        title={t('Personal AI Fitness Coach')}
        description={t('Direct read of your synced workouts, recovery fatigue, body weight, nutrition and 15-day plan — with safe Preview, Approve & Undo plan edits.')}
        action={
          rev !== null && !readOnly ? (
            <Badge variant="outline" className="rounded-full">
              {t('Live Context Loaded')} · {t('Rev')} {rev}
            </Badge>
          ) : undefined
        }
      >
        <div className="flex flex-col gap-4">
          <p className="flex items-start gap-2 rounded-xl bg-muted/60 px-3.5 py-2.5 text-[12.5px] text-muted-foreground">
            <Lock className="mt-0.5 size-3.5 shrink-0" aria-hidden />
            <span>
              {t("Today's plan is locked on the web to protect active iPhone sessions. The AI Coach can review all history and edit upcoming days (tomorrow through +14 days).")}
            </span>
          </p>

          <form
            onSubmit={(e) => {
              e.preventDefault()
              void ask()
            }}
            className="flex flex-col gap-3"
          >
            <textarea
              rows={3}
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder={t('Ask your AI coach anything — or request a plan change…')}
              disabled={readOnly || asking || !ai?.configured}
              className="w-full resize-none rounded-xl border border-input bg-background px-3.5 py-2.5 text-[14px] outline-none placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50"
            />
            <div className="flex flex-wrap items-center justify-between gap-2">
              <div className="flex flex-wrap items-center gap-1.5">
                <span className="mr-1 text-[12px] text-muted-foreground">{t('Quick prompts')}:</span>
                {QUICK_PROMPTS.map((qp) => (
                  <button
                    key={qp}
                    type="button"
                    disabled={readOnly || asking || !ai?.configured}
                    onClick={() => setMessage(t(qp))}
                    className="rounded-full border border-border px-2.5 py-1 text-[12px] text-muted-foreground transition-colors hover:bg-foreground/[0.04] hover:text-foreground disabled:opacity-40"
                  >
                    {t(qp)}
                  </button>
                ))}
              </div>
              <Button type="submit" size="sm" disabled={readOnly || asking || !ai?.configured || !message.trim()}>
                {asking ? <Sparkles className="mr-1.5 size-4 animate-pulse" aria-hidden /> : <Send className="mr-1.5 size-4" aria-hidden />}
                {asking ? t('Thinking…') : t('Ask Coach')}
              </Button>
            </div>
          </form>
        </div>
      </Panel>

      {proposal && (
        <Panel
          title={t('AI Coach')}
          description={
            proposal.hasChanges
              ? t('Review the Before and After diff below. Nothing is saved until you click Approve & Apply.')
              : proposal.note === 'no_valid_plan_change'
                ? t('The AI Coach suggested an adjustment that could not be safely validated against your current plan, so only advice is shown.')
                : t('AI Coach answered your question. No plan changes were needed.')
          }
        >
          <div className="flex flex-col gap-4">
            <div className="whitespace-pre-wrap rounded-xl bg-muted/40 px-4 py-3.5 text-[14px] leading-relaxed">
              {proposal.answer}
            </div>

            {proposal.hasChanges && (
              <div className="flex flex-col gap-3">
                <p className="text-[13.5px] font-semibold">{t('Proposed Plan Changes')}</p>
                <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
                  {proposal.dayDiffs.map((diff) => (
                    <div key={diff.date} className="flex flex-col gap-2.5 rounded-xl border border-primary/35 bg-primary/[0.03] p-4">
                      <div className="flex items-center justify-between gap-2">
                        <span className="text-[13.5px] font-semibold">{shortDate(diff.date, lang)} ({diff.date})</span>
                        {diff.after.isAIClone && (
                          <Badge className="rounded-full bg-primary/15 text-primary hover:bg-primary/15">{t('AI adjusted')}</Badge>
                        )}
                      </div>
                      <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-2 text-[13px]">
                        <div className="rounded-lg border border-border bg-background px-2.5 py-2">
                          <p className="text-[11px] text-muted-foreground">{t('Before')}</p>
                          <p className="font-medium">{diff.before.isRest ? t('Rest day') : diff.before.routineName || '—'}</p>
                        </div>
                        <ArrowRight className="size-4 text-muted-foreground" aria-hidden />
                        <div className="rounded-lg border border-primary/40 bg-background px-2.5 py-2">
                          <p className="text-[11px] text-primary">{t('After')}</p>
                          <p className="font-medium">{diff.after.isRest ? t('Rest day') : diff.after.routineName || '—'}</p>
                        </div>
                      </div>
                      {diff.slotChanges.length > 0 && (
                        <ul className="space-y-1 text-[12.5px] text-muted-foreground">
                          {diff.slotChanges.map((sc, i) => (
                            <li key={i}>
                              {sc.kind === 'swapped' && `${t('Swap')}: ${sc.fromName} → ${sc.toName} (${sc.sets}${sc.reps ? ` × ${sc.reps}` : ''})`}
                              {sc.kind === 'setsChanged' && `${sc.name}: ${sc.beforeSets} → ${sc.afterSets} ${t('Sets')}${sc.afterReps ? ` × ${sc.afterReps}` : ''}`}
                              {sc.kind === 'added' && `${t('Added')}: ${sc.name} (${sc.sets}${sc.reps ? ` × ${sc.reps}` : ''})`}
                            </li>
                          ))}
                        </ul>
                      )}
                      {diff.reasons.length > 0 && (
                        <p className="text-[12px] text-muted-foreground">{diff.reasons.join(' · ')}</p>
                      )}
                    </div>
                  ))}
                </div>
                <div className="flex flex-wrap gap-2 pt-1">
                  <Button size="sm" disabled={readOnly || applying} onClick={() => void applyProposal()}>
                    <Check className="mr-1.5 size-4" aria-hidden />
                    {applying ? t('Applying…') : t('Approve & Apply to Plan')}
                  </Button>
                  <Button size="sm" variant="ghost" disabled={applying} onClick={() => setProposal(null)}>
                    {t('Discard Proposal')}
                  </Button>
                </div>
              </div>
            )}
          </div>
        </Panel>
      )}

      {summary && (
        <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <Panel title={t('Upcoming 7 Days')} className="lg:col-span-2">
            <div className="grid grid-cols-1 gap-2 sm:grid-cols-2 lg:grid-cols-7">
              {summary.plannedNext7d.map((d) => (
                <div
                  key={d.date}
                  className={cn(
                    'flex flex-col gap-1 rounded-xl border border-border p-2.5 text-[12.5px]',
                    d.locked && 'bg-muted/40',
                  )}
                >
                  <div className="flex items-center justify-between text-[11px] text-muted-foreground">
                    <span>{weekdayShort(weekdayOfIso(d.date), lang)}</span>
                    <span>{shortDate(d.date, lang)}</span>
                  </div>
                  <p className={cn('font-medium', d.isRest && 'font-normal text-muted-foreground')}>
                    {d.isRest ? t('Rest day') : d.routineName || '—'}
                  </p>
                  {(d.isAIClone || d.locked) && (
                    <div className="mt-auto flex flex-wrap items-center gap-1 pt-1">
                      {d.isAIClone && (
                        <Badge className="h-5 rounded-full bg-primary/15 px-2 text-[10.5px] text-primary hover:bg-primary/15">
                          {t('AI adjusted')}
                        </Badge>
                      )}
                      {d.locked && (
                        <span className="inline-flex items-center gap-1 text-[10.5px] text-muted-foreground">
                          <Lock className="size-3" aria-hidden />
                          {d.date === summary.today ? t('Locked (iPhone)') : t('Locked')}
                        </span>
                      )}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </Panel>

          <Panel title={t('Top Fatigued Muscles')} description={`${t('Recent Workouts (14d)')}: ${summary.recentWorkoutsCount}`}>
            {summary.topFatigued.length === 0 ? (
              <p className="text-[13px] text-muted-foreground">{t('All muscles recovered')}</p>
            ) : (
              <ul className="space-y-2 text-[13px]">
                {summary.topFatigued.map((m) => (
                  <li key={m.slug} className="flex items-center justify-between">
                    <span>{muscleLabel(m.slug)}</span>
                    <span className="font-medium">{fmtInt(m.fatigue * 100)}%</span>
                  </li>
                ))}
              </ul>
            )}
            <div className="mt-3 border-t border-border pt-3 text-[12.5px] text-muted-foreground">
              <p className="font-medium text-foreground">{t("Today's Nutrition")}</p>
              {summary.todayNutrition.total.kcal > 0 ? (
                <p className="mt-0.5">
                  {fmtInt(summary.todayNutrition.total.kcal)} kcal · P {fmtInt(summary.todayNutrition.total.protein)}g · C {fmtInt(summary.todayNutrition.total.carbs)}g · F {fmtInt(summary.todayNutrition.total.fat)}g
                </p>
              ) : (
                <p className="mt-0.5">{t('No meals logged today')}</p>
              )}
            </div>
          </Panel>
        </div>
      )}
    </div>
  )
}
