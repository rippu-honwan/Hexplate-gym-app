import { useMemo, useState } from 'react'
import { ArrowDown, ArrowUp, ChevronRight, ChevronsUpDown, Search } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { useI18n } from '@/i18n'
import { weekdayDate } from '@/lib/dates'
import { fmtInt } from '@/lib/format'
import { cn } from '@/lib/utils'
import type { Session, SessionStatus } from '@/types/hexplate'

export const STATUS_LABEL: Record<SessionStatus, string> = { pr: 'PR Hit', completed: 'Completed', deload: 'Deload', recovery: 'Recovery' }

const STATUS_CLASS: Record<SessionStatus, string> = {
  pr: 'border-transparent bg-primary/12 text-primary',
  completed: 'border-foreground/15 bg-foreground/[0.03] text-foreground',
  deload: 'border-transparent bg-foreground/[0.08] text-foreground/75',
  recovery: 'border-dashed border-foreground/30 bg-transparent text-foreground/75',
}

export function StatusBadge({ status }: { status: SessionStatus }) {
  const { t } = useI18n()
  return <Badge variant="outline" className={cn('rounded-full font-medium', STATUS_CLASS[status])}>{t(STATUS_LABEL[status])}</Badge>
}

type SortKey = 'd' | 'minutes' | 'workSets' | 'vol' | 'prs'
const COLUMNS: { key: SortKey; label: string; numeric?: boolean }[] = [
  { key: 'd', label: 'Date' },
  { key: 'minutes', label: 'Duration', numeric: true },
  { key: 'workSets', label: 'Sets', numeric: true },
  { key: 'vol', label: 'Volume', numeric: true },
  { key: 'prs', label: 'PRs', numeric: true },
]

const SORTS: { value: string; label: string }[] = [
  { value: 'd:-1', label: 'Newest first' },
  { value: 'd:1', label: 'Oldest first' },
  { value: 'vol:-1', label: 'Most volume' },
  { value: 'workSets:-1', label: 'Most sets' },
  { value: 'minutes:-1', label: 'Longest' },
  { value: 'prs:-1', label: 'Most PRs' },
]

function SortHeader({ col, sort, onSort }: { col: (typeof COLUMNS)[number]; sort: { key: SortKey; dir: 1 | -1 }; onSort: (k: SortKey) => void }) {
  const { t } = useI18n()
  const active = sort.key === col.key
  const Icon = !active ? ChevronsUpDown : sort.dir === 1 ? ArrowUp : ArrowDown
  return (
    <TableHead className={cn(col.numeric && 'text-right')} aria-sort={active ? (sort.dir === 1 ? 'ascending' : 'descending') : 'none'}>
      <button
        type="button"
        onClick={() => onSort(col.key)}
        className={cn(
          '-mx-1 inline-flex items-center gap-1 rounded px-1 text-[12px] font-medium text-muted-foreground outline-none transition-colors duration-150 hover:text-foreground focus-visible:ring-2 focus-visible:ring-ring',
          active && 'text-foreground',
        )}
      >
        {t(col.label)}
        <Icon className="size-3.5" aria-hidden />
      </button>
    </TableHead>
  )
}

export function SessionsTable({
  sessions,
  unitLabel = 'kg',
  limit,
  onShowAll,
  onSelectSession,
}: {
  sessions: Session[]
  unitLabel?: string
  limit?: number
  onShowAll?: () => void
  onSelectSession?: (id: string) => void
}) {
  const { lang, t } = useI18n()
  const [query, setQuery] = useState('')
  const [status, setStatus] = useState<'all' | SessionStatus>('all')
  const [sort, setSort] = useState<{ key: SortKey; dir: 1 | -1 }>({ key: 'd', dir: -1 })

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    return sessions
      .filter((s) => status === 'all' || s.status === status)
      .filter((s) => !q || s.routine.toLowerCase().includes(q) || s.topExercise.toLowerCase().includes(q) || s.split.includes(q))
      .sort((a, b) => (a[sort.key] < b[sort.key] ? -1 : a[sort.key] > b[sort.key] ? 1 : 0) * sort.dir)
  }, [sessions, query, status, sort])

  const shown = limit ? rows.slice(0, limit) : rows
  const onSort = (key: SortKey) => setSort((s) => (s.key === key ? { key, dir: s.dir === 1 ? -1 : 1 } : { key, dir: -1 }))

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-wrap items-center gap-2">
        <div className="relative min-w-0 basis-full sm:max-w-64 sm:basis-auto sm:flex-1">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
          <Input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t('Search routine or lift')}
            aria-label={t('Search workouts')}
            className="h-8 pl-8"
          />
        </div>
        <Select value={status} onValueChange={(v) => setStatus(v as 'all' | SessionStatus)}>
          <SelectTrigger size="sm" className="w-[144px]" aria-label={t('All statuses')}><SelectValue /></SelectTrigger>
          <SelectContent>
            <SelectItem value="all">{t('All statuses')}</SelectItem>
            {(Object.keys(STATUS_LABEL) as SessionStatus[]).map((k) => (
              <SelectItem key={k} value={k}>{t(STATUS_LABEL[k])}</SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Select value={`${sort.key}:${sort.dir}`} onValueChange={(v) => { const [key, dir] = v.split(':'); setSort({ key: key as SortKey, dir: Number(dir) as 1 | -1 }) }}>
          <SelectTrigger size="sm" className="w-[144px] sm:hidden" aria-label={t('Newest first')}><SelectValue /></SelectTrigger>
          <SelectContent>
            {SORTS.map((o) => <SelectItem key={o.value} value={o.value}>{t(o.label)}</SelectItem>)}
          </SelectContent>
        </Select>
        <p className="ml-auto text-[12px] text-muted-foreground" aria-live="polite">
          {limit && rows.length > limit
            ? t('{shown} of {total} sessions', { shown: fmtInt(limit), total: fmtInt(rows.length) })
            : t('{n} sessions', { n: fmtInt(rows.length) })}
        </p>
      </div>

      <ul className="divide-y divide-border sm:hidden" aria-label={t('Sessions')}>
        {shown.map((s) => (
          <li key={s.id}>
            <button
              type="button"
              disabled={!onSelectSession}
              onClick={() => onSelectSession?.(s.id)}
              className="w-full rounded-lg px-2 py-3 text-left transition-colors duration-150 hover:bg-foreground/[0.03] disabled:cursor-default"
            >
              <div className="flex items-center gap-2">
                <span className="min-w-0 truncate text-[14px] font-medium">{s.routine}</span>
                <StatusBadge status={s.status} />
                <span className="ml-auto shrink-0 text-[14px] font-medium">{fmtInt(s.vol)} {unitLabel}</span>
              </div>
              <div className="mt-1 flex items-center gap-2 text-[12px] text-muted-foreground">
                <span className="shrink-0">{weekdayDate(s.d, lang)}</span>
                <span className="min-w-0 truncate">{s.topExercise}</span>
                <span className="ml-auto flex shrink-0 gap-3">
                  <span>{t('{n} sets', { n: fmtInt(s.workSets) })}</span>
                  <span>{t('{n} min', { n: fmtInt(s.minutes) })}</span>
                  {s.prs > 0 && <span className="text-primary">{t('{n} PR', { n: fmtInt(s.prs) })}</span>}
                </span>
              </div>
            </button>
          </li>
        ))}
        {shown.length === 0 && (
          <li className="py-10 text-center text-[13px] text-muted-foreground">{t('No sessions match. Clear the search or pick another status.')}</li>
        )}
      </ul>

      <Table className="hidden sm:table">
        <TableHeader>
          <TableRow className="hover:bg-transparent">
            <SortHeader col={COLUMNS[0]} sort={sort} onSort={onSort} />
            <TableHead className="text-[12px] font-medium text-muted-foreground">{t('Routine')}</TableHead>
            <TableHead className="text-[12px] font-medium text-muted-foreground">{t('Status')}</TableHead>
            {COLUMNS.slice(1).map((c) => <SortHeader key={c.key} col={c} sort={sort} onSort={onSort} />)}
            {onSelectSession && <TableHead className="w-8" />}
          </TableRow>
        </TableHeader>
        <TableBody>
          {shown.map((s) => (
            <TableRow
              key={s.id}
              onClick={onSelectSession ? () => onSelectSession(s.id) : undefined}
              className={cn(onSelectSession && 'cursor-pointer')}
            >
              <TableCell className="whitespace-nowrap text-[13px]">{weekdayDate(s.d, lang)}</TableCell>
              <TableCell className="text-[13px]">
                <span className="font-medium">{s.routine}</span>
                <span className="block text-[12px] text-muted-foreground">{s.topExercise}</span>
              </TableCell>
              <TableCell><StatusBadge status={s.status} /></TableCell>
              <TableCell className="text-right text-[13px]">{t('{n} min', { n: fmtInt(s.minutes) })}</TableCell>
              <TableCell className="text-right text-[13px]">{fmtInt(s.workSets)}</TableCell>
              <TableCell className="text-right text-[13px]">{fmtInt(s.vol)} {unitLabel}</TableCell>
              <TableCell className="text-right text-[13px]">{s.prs ? fmtInt(s.prs) : <span className="text-muted-foreground">0</span>}</TableCell>
              {onSelectSession && (
                <TableCell className="text-right text-muted-foreground">
                  <ChevronRight className="inline size-4" aria-hidden />
                </TableCell>
              )}
            </TableRow>
          ))}
          {shown.length === 0 && (
            <TableRow className="hover:bg-transparent">
              <TableCell colSpan={onSelectSession ? 8 : 7} className="py-10 text-center text-[13px] text-muted-foreground">
                {t('No sessions match. Clear the search or pick another status.')}
              </TableCell>
            </TableRow>
          )}
        </TableBody>
      </Table>

      {onShowAll && limit && rows.length > limit && (
        <Button variant="ghost" size="sm" className="self-start text-primary hover:text-primary" onClick={onShowAll}>
          {t('Show all sessions')}
        </Button>
      )}
    </div>
  )
}
