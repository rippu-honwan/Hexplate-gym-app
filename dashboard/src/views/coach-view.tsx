import { useCallback, useEffect, useRef, useState } from 'react'
import {
  AlertTriangle,
  ArrowRight,
  Bot,
  Check,
  CheckCircle2,
  Clock,
  Info,
  Lock,
  MessageSquarePlus,
  RotateCcw,
  Send,
  Settings,
  Sparkles,
  X,
} from 'lucide-react'
import { Panel } from '@/components/charts'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'
import { useI18n } from '@/i18n'
import { ApiError, api } from '@/lib/api'
import { shortDate, weekdayOfIso, weekdayShort } from '@/lib/dates'
import { fmtInt } from '@/lib/format'
import { cn } from '@/lib/utils'
import type {
  AiConfigMasked,
  CoachChatTurn,
  CoachContextSummary,
  CoachProposal,
  CoachUndoStatus,
} from '@/types/hexplate'
import { MUSCLE_NAMES, type MuscleSlug } from '@/types/hexplate'

const MAX_CHAT_MESSAGES = 40
const MAX_HISTORY_TURNS = 10
const MAX_HISTORY_CODE_POINTS = 1200

const QUICK_PROMPTS = [
  'How is my weekly muscle balance and fatigue looking?',
  "Move tomorrow's workout to the day after tomorrow.",
  'Reduce sets by 1 on my most fatigued muscle next session.',
  'Suggest a lighter recovery tweak for my next training day.',
]

type ProposalStatus = 'pending' | 'applying' | 'applied' | 'dismissed' | 'superseded'

interface ChatMessage {
  id: string
  role: 'user' | 'assistant'
  content: string
  kind: 'text' | 'error'
  retryPrompt?: string
  note?: string | null
  proposal?: {
    data: CoachProposal
    status: ProposalStatus
    appliedRev?: number
    error?: string | null
  }
}

function makeMessageId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`
}

/** Code-point-safe history builder matching server/iOS caps (10 turns, 1,200 code points, no lone surrogates). */
function buildHistory(messages: ChatMessage[]): CoachChatTurn[] {
  const turns: CoachChatTurn[] = []
  for (const msg of messages) {
    if (msg.kind !== 'text') continue
    const trimmed = msg.content.trim()
    if (!trimmed) continue
    const capped = Array.from(trimmed).slice(0, MAX_HISTORY_CODE_POINTS).join('').trim()
    if (!capped) continue
    turns.push({ role: msg.role, content: capped })
  }
  return turns.slice(-MAX_HISTORY_TURNS)
}

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
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [draft, setDraft] = useState('')
  const [asking, setAsking] = useState(false)
  const [undoing, setUndoing] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const requestGenRef = useRef(0)
  const bottomRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    setUndo(initialUndo)
  }, [initialUndo])

  useEffect(() => {
    return () => {
      requestGenRef.current += 1
    }
  }, [])

  useEffect(() => {
    if (messages.length > 0 || asking) {
      bottomRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })
    }
  }, [messages.length, asking])

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

  const handleNewChat = () => {
    requestGenRef.current += 1
    setAsking(false)
    setMessages([])
    setNotice(null)
    setError(null)
  }

  const ask = async (promptText?: string) => {
    const q = (promptText ?? draft).trim()
    if (!q || readOnly || asking || !ai?.configured) return

    const history = buildHistory(messages)
    const gen = ++requestGenRef.current
    const userMsg: ChatMessage = {
      id: makeMessageId(),
      role: 'user',
      content: q,
      kind: 'text',
    }

    setMessages((prev) => [...prev, userMsg].slice(-MAX_CHAT_MESSAGES))
    if (!promptText) setDraft('')
    setAsking(true)
    setError(null)
    setNotice(null)

    try {
      const res = await api.coachPropose({
        message: q,
        history: history.length > 0 ? history : undefined,
        lang,
      })
      if (gen !== requestGenRef.current) return

      setSummary(res.summary)
      setRev(res.baseRev)

      const assistantMsg: ChatMessage = {
        id: makeMessageId(),
        role: 'assistant',
        content: res.answer,
        kind: 'text',
        note: res.note,
        proposal: res.hasChanges
          ? {
              data: res,
              status: 'pending',
              error: null,
            }
          : undefined,
      }
      setMessages((prev) => [...prev, assistantMsg].slice(-MAX_CHAT_MESSAGES))
    } catch (e) {
      if (gen !== requestGenRef.current) return
      const errMsg: ChatMessage = {
        id: makeMessageId(),
        role: 'assistant',
        content: (e as Error).message,
        kind: 'error',
        retryPrompt: q,
      }
      setMessages((prev) => [...prev, errMsg].slice(-MAX_CHAT_MESSAGES))
    } finally {
      if (gen === requestGenRef.current) {
        setAsking(false)
      }
    }
  }

  const applyProposal = async (msgId: string) => {
    if (readOnly) return
    const target = messages.find((m) => m.id === msgId)
    if (!target?.proposal || target.proposal.status !== 'pending') return
    if (rev !== null && target.proposal.data.baseRev !== rev) {
      setMessages((prev) =>
        prev.map((m) =>
          m.id === msgId && m.proposal
            ? { ...m, proposal: { ...m.proposal, status: 'superseded', error: null } }
            : m,
        ),
      )
      return
    }

    const prop = target.proposal.data
    setMessages((prev) =>
      prev.map((m) =>
        m.id === msgId && m.proposal
          ? { ...m, proposal: { ...m.proposal, status: 'applying', error: null } }
          : m,
      ),
    )
    setError(null)
    setNotice(null)

    try {
      const res = await api.coachApply({
        ops: prop.changes,
        baseRev: prop.baseRev,
        baseWid: prop.baseWid,
        expectedDigests: prop.expectedDigests,
        lang,
      })
      setUndo(res.undo)
      setRev(res.rev)
      setMessages((prev) =>
        prev.map((m) => {
          if (!m.proposal) return m
          if (m.id === msgId) {
            return {
              ...m,
              proposal: { ...m.proposal, status: 'applied', appliedRev: res.rev, error: null },
            }
          }
          if (m.proposal.status === 'pending') {
            return { ...m, proposal: { ...m.proposal, status: 'superseded', error: null } }
          }
          return m
        }),
      )
      setNotice(
        t('Plan updated (rev {rev}). Your iPhone will merge these changes on its next sync.', {
          rev: res.rev,
        }),
      )
      await onPlanMutated()
      await loadContext()
    } catch (e) {
      if (e instanceof ApiError && e.status === 409) {
        setMessages((prev) =>
          prev.map((m) =>
            m.id === msgId && m.proposal
              ? { ...m, proposal: { ...m.proposal, status: 'superseded', error: null } }
              : m,
          ),
        )
        await loadContext()
      } else {
        setMessages((prev) =>
          prev.map((m) =>
            m.id === msgId && m.proposal
              ? { ...m, proposal: { ...m.proposal, status: 'pending', error: (e as Error).message } }
              : m,
          ),
        )
      }
    }
  }

  const dismissProposal = (msgId: string) => {
    setMessages((prev) =>
      prev.map((m) =>
        m.id === msgId && m.proposal && m.proposal.status === 'pending'
          ? { ...m, proposal: { ...m.proposal, status: 'dismissed', error: null } }
          : m,
      ),
    )
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
      setMessages((prev) =>
        prev.map((m) =>
          m.proposal && m.proposal.status === 'pending'
            ? { ...m, proposal: { ...m.proposal, status: 'superseded', error: null } }
            : m,
        ),
      )
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
  const composerDisabled = readOnly || asking || !ai?.configured

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
                ? undo.touchedDates.map((d) => shortDate(d, lang)).join(', ')
                : t('Undo unavailable because a touched day is today or already has a logged workout.')}
            </p>
          </div>
          <Button
            size="sm"
            variant="outline"
            disabled={readOnly || undoing || undo.status !== 'available'}
            onClick={() => void doUndo()}
          >
            <RotateCcw className="mr-1.5 size-3.5" aria-hidden />
            {undoing ? t('Undoing…') : t('Undo Last Change')}
          </Button>
        </Card>
      )}

      {notice && (
        <div className="rounded-xl border border-primary/35 bg-primary/[0.06] px-4 py-3 text-[13px]">
          {notice}
        </div>
      )}
      {error && (
        <div className="rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">
          {error}
        </div>
      )}

      <Panel
        title={t('Personal AI Fitness Coach')}
        description={t('Direct read of your synced workouts, recovery fatigue, body weight, nutrition and 15-day plan — with safe Preview, Approve & Undo plan edits.')}
        action={
          <div className="flex flex-wrap items-center gap-2">
            {rev !== null && !readOnly && (
              <Badge variant="outline" className="rounded-full">
                {t('Live Context Loaded')} · {t('Rev')} {rev}
              </Badge>
            )}
            <Button
              type="button"
              size="sm"
              variant="outline"
              disabled={messages.length === 0 && !asking}
              onClick={handleNewChat}
            >
              <MessageSquarePlus className="mr-1.5 size-3.5" aria-hidden />
              {t('New Chat')}
            </Button>
          </div>
        }
      >
        <div className="flex flex-col gap-4">
          <p className="flex items-start gap-2 rounded-xl bg-muted/60 px-3.5 py-2.5 text-[12.5px] text-muted-foreground">
            <Lock className="mt-0.5 size-3.5 shrink-0" aria-hidden />
            <span>
              {t("Today's plan is locked on the web to protect active iPhone sessions. The AI Coach can review all history and edit upcoming days (tomorrow through +14 days).")}
            </span>
          </p>

          {/* Chatbox Message Thread */}
          <div className="flex min-h-[340px] max-h-[58vh] flex-col gap-3.5 overflow-y-auto rounded-2xl border border-border bg-muted/20 p-4">
            {messages.length === 0 && !asking && (
              <div className="flex flex-col gap-3">
                <div className="max-w-[85%] self-start rounded-2xl border border-border bg-card px-4 py-3 text-[13.5px] leading-relaxed">
                  <div className="mb-1 flex items-center gap-1.5 text-[11.5px] font-semibold text-primary">
                    <Sparkles className="size-3.5" aria-hidden />
                    <span>{t('AI Coach')}</span>
                  </div>
                  <p className="text-foreground">
                    {t('Ask about your recovery, muscle balance, or upcoming workouts. When the coach recommends a plan adjustment, you can review and confirm it right below the reply.')}
                  </p>
                </div>
                <div className="flex flex-wrap items-center gap-1.5 pt-1">
                  <span className="mr-1 text-[12px] text-muted-foreground">{t('Quick prompts')}:</span>
                  {QUICK_PROMPTS.map((qp) => (
                    <button
                      key={qp}
                      type="button"
                      disabled={composerDisabled}
                      onClick={() => void ask(t(qp))}
                      className="rounded-full border border-border bg-card px-3 py-1.5 text-[12px] text-muted-foreground transition-colors hover:bg-foreground/[0.04] hover:text-foreground disabled:opacity-40"
                    >
                      {t(qp)}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {messages.map((msg) => {
              if (msg.role === 'user') {
                return (
                  <div key={msg.id} className="flex justify-end">
                    <div className="max-w-[85%] rounded-2xl bg-primary px-4 py-2.5 text-[14px] leading-relaxed text-primary-foreground whitespace-pre-wrap break-words">
                      {msg.content}
                    </div>
                  </div>
                )
              }

              if (msg.kind === 'error') {
                return (
                  <div key={msg.id} className="flex justify-start">
                    <div className="flex max-w-[85%] flex-col gap-2 rounded-2xl border border-destructive/35 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">
                      <div className="flex items-start gap-2">
                        <AlertTriangle className="mt-0.5 size-4 shrink-0" aria-hidden />
                        <span className="whitespace-pre-wrap break-words">{msg.content}</span>
                      </div>
                      {msg.retryPrompt && (
                        <div>
                          <Button
                            type="button"
                            size="sm"
                            variant="outline"
                            disabled={composerDisabled}
                            onClick={() => void ask(msg.retryPrompt)}
                          >
                            <RotateCcw className="mr-1.5 size-3.5" aria-hidden />
                            {t('Retry')}
                          </Button>
                        </div>
                      )}
                    </div>
                  </div>
                )
              }

              const propState = msg.proposal
              const effectiveStatus: ProposalStatus | null = propState
                ? propState.status === 'pending' && rev !== null && propState.data.baseRev !== rev
                  ? 'superseded'
                  : propState.status
                : null

              return (
                <div key={msg.id} className="flex justify-start">
                  <div className="flex w-full max-w-[90%] flex-col gap-2.5">
                    <div className="rounded-2xl border border-border bg-card px-4 py-3 text-[14px] leading-relaxed">
                      <div className="mb-1 flex items-center gap-1.5 text-[11.5px] font-semibold text-primary">
                        <Sparkles className="size-3.5" aria-hidden />
                        <span>{t('AI Coach')}</span>
                      </div>
                      <div className="whitespace-pre-wrap break-words">{msg.content}</div>
                    </div>

                    {msg.note === 'no_valid_plan_change' && (
                      <div className="flex items-start gap-2 rounded-xl border border-border bg-card/80 px-3.5 py-2.5 text-[12.5px] text-muted-foreground">
                        <Info className="mt-0.5 size-4 shrink-0 text-primary" aria-hidden />
                        <span>
                          {t('The AI Coach suggested an adjustment that could not be safely validated against your current plan, so only advice is shown.')}
                        </span>
                      </div>
                    )}

                    {propState && effectiveStatus && (
                      <div
                        className={cn(
                          'flex flex-col gap-3 rounded-2xl border bg-card p-4',
                          effectiveStatus === 'pending'
                            ? 'border-primary/40'
                            : 'border-border',
                        )}
                      >
                        <div className="flex items-center justify-between gap-2">
                          <p className="text-[13px] font-semibold">{t('Proposed Plan Changes')}</p>
                          {effectiveStatus === 'pending' && (
                            <span className="text-[11.5px] text-muted-foreground">
                              {t('Review the diff below. Nothing changes until you confirm.')}
                            </span>
                          )}
                        </div>

                        <div className="grid grid-cols-1 gap-2.5 md:grid-cols-2">
                          {propState.data.dayDiffs.map((diff) => (
                            <div
                              key={diff.date}
                              className="flex flex-col gap-2 rounded-xl border border-primary/25 bg-primary/[0.03] p-3"
                            >
                              <div className="flex items-center justify-between gap-2">
                                <span className="text-[13px] font-semibold">
                                  {shortDate(diff.date, lang)} ({diff.date})
                                </span>
                                {diff.after.isAIClone && (
                                  <Badge className="rounded-full bg-primary/15 text-primary hover:bg-primary/15">
                                    {t('AI adjusted')}
                                  </Badge>
                                )}
                              </div>
                              <div className="grid grid-cols-[1fr_auto_1fr] items-center gap-2 text-[12.5px]">
                                <div className="rounded-lg border border-border bg-background px-2.5 py-1.5">
                                  <p className="text-[10.5px] text-muted-foreground">{t('Before')}</p>
                                  <p className="font-medium">
                                    {diff.before.isRest ? t('Rest day') : diff.before.routineName || '—'}
                                  </p>
                                </div>
                                <ArrowRight className="size-3.5 text-muted-foreground" aria-hidden />
                                <div className="rounded-lg border border-primary/40 bg-background px-2.5 py-1.5">
                                  <p className="text-[10.5px] text-primary">{t('After')}</p>
                                  <p className="font-medium">
                                    {diff.after.isRest ? t('Rest day') : diff.after.routineName || '—'}
                                  </p>
                                </div>
                              </div>
                              {diff.slotChanges.length > 0 && (
                                <ul className="space-y-1 text-[12px] text-muted-foreground">
                                  {diff.slotChanges.map((sc, i) => (
                                    <li key={i}>
                                      {sc.kind === 'swapped' &&
                                        `${t('Swap')}: ${sc.fromName} → ${sc.toName} (${sc.sets}${sc.reps ? ` × ${sc.reps}` : ''})`}
                                      {sc.kind === 'setsChanged' &&
                                        `${sc.name}: ${sc.beforeSets} → ${sc.afterSets} ${t('Sets')}${sc.afterReps ? ` × ${sc.afterReps}` : ''}`}
                                      {sc.kind === 'added' &&
                                        `${t('Added')}: ${sc.name} (${sc.sets}${sc.reps ? ` × ${sc.reps}` : ''})`}
                                    </li>
                                  ))}
                                </ul>
                              )}
                              {diff.reasons.length > 0 && (
                                <p className="text-[11.5px] text-muted-foreground">
                                  {diff.reasons.join(' · ')}
                                </p>
                              )}
                            </div>
                          ))}
                        </div>

                        {propState.error && (
                          <p className="text-[12.5px] text-destructive">{propState.error}</p>
                        )}

                        <div className="flex flex-wrap items-center gap-2 pt-0.5">
                          {(effectiveStatus === 'pending' || effectiveStatus === 'applying') && (
                            <>
                              <Button
                                type="button"
                                size="sm"
                                disabled={readOnly || effectiveStatus === 'applying'}
                                onClick={() => void applyProposal(msg.id)}
                              >
                                <Check className="mr-1.5 size-4" aria-hidden />
                                {effectiveStatus === 'applying'
                                  ? t('Applying…')
                                  : t('Confirm & Apply Changes')}
                              </Button>
                              <Button
                                type="button"
                                size="sm"
                                variant="ghost"
                                disabled={effectiveStatus === 'applying'}
                                onClick={() => dismissProposal(msg.id)}
                              >
                                <X className="mr-1 size-3.5" aria-hidden />
                                {t('Dismiss')}
                              </Button>
                            </>
                          )}
                          {effectiveStatus === 'applied' && (
                            <span className="inline-flex items-center gap-1.5 text-[12.5px] font-medium text-primary">
                              <CheckCircle2 className="size-4" aria-hidden />
                              {t('Applied (rev {rev})', { rev: propState.appliedRev ?? rev ?? 0 })}
                            </span>
                          )}
                          {effectiveStatus === 'superseded' && (
                            <span className="inline-flex items-center gap-1.5 text-[12.5px] text-muted-foreground">
                              <Clock className="size-3.5" aria-hidden />
                              {t('Plan changed — ask again')}
                            </span>
                          )}
                          {effectiveStatus === 'dismissed' && (
                            <span className="inline-flex items-center gap-1.5 text-[12.5px] text-muted-foreground">
                              <X className="size-3.5" aria-hidden />
                              {t('Suggestion dismissed')}
                            </span>
                          )}
                        </div>
                      </div>
                    )}
                  </div>
                </div>
              )
            })}

            {asking && (
              <div className="flex justify-start">
                <div className="inline-flex items-center gap-2 rounded-2xl border border-border bg-card px-4 py-2.5 text-[13px] text-muted-foreground">
                  <Sparkles className="size-4 animate-pulse text-primary" aria-hidden />
                  <span>{t('AI Coach is thinking…')}</span>
                </div>
              </div>
            )}
            <div ref={bottomRef} />
          </div>

          {/* Pinned Chat Input Composer */}
          <form
            onSubmit={(e) => {
              e.preventDefault()
              void ask()
            }}
            className="flex items-end gap-2.5"
          >
            <textarea
              rows={2}
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (
                  e.key === 'Enter' &&
                  !e.shiftKey &&
                  !e.nativeEvent.isComposing &&
                  e.keyCode !== 229
                ) {
                  e.preventDefault()
                  void ask()
                }
              }}
              placeholder={t('Message your AI Coach… (Enter to send, Shift+Enter for new line)')}
              disabled={composerDisabled}
              className="min-h-[44px] max-h-36 flex-1 resize-none rounded-xl border border-input bg-background px-3.5 py-2.5 text-[14px] outline-none placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-50"
            />
            <Button
              type="submit"
              size="sm"
              className="h-11 shrink-0 px-4"
              disabled={composerDisabled || !draft.trim()}
            >
              {asking ? (
                <Sparkles className="mr-1.5 size-4 animate-pulse" aria-hidden />
              ) : (
                <Send className="mr-1.5 size-4" aria-hidden />
              )}
              {asking ? t('Thinking…') : t('Send')}
            </Button>
          </form>
        </div>
      </Panel>

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

          <Panel
            title={t('Top Fatigued Muscles')}
            description={`${t('Recent Workouts (14d)')}: ${summary.recentWorkoutsCount}`}
          >
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
