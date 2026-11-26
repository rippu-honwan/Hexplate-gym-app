import { useCallback, useEffect, useState } from 'react'
import { Check, Copy, Download, Pause, Play, Plus, RefreshCw, Send, Trash2 } from 'lucide-react'
import { Panel } from '@/components/charts'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table'
import { useI18n } from '@/i18n'
import { api } from '@/lib/api'
import { fmt1 } from '@/lib/format'
import type { ConnectPayload, McpInfo, ServerAddresses, SyncDataPayload } from '@/types/hexplate'

function CopyButton({ text }: { text: string }) {
  const { t } = useI18n()
  const [copied, setCopied] = useState(false)
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1800)
    } catch {
      // Clipboard API unavailable
    }
  }
  return (
    <Button type="button" variant="outline" size="sm" onClick={copy}>
      {copied ? <Check className="mr-1.5 size-3.5 text-primary" aria-hidden /> : <Copy className="mr-1.5 size-3.5" aria-hidden />}
      {copied ? t('Copied') : t('Copy')}
    </Button>
  )
}

export function SyncDataView({
  readOnly,
  onMutated,
}: {
  readOnly: boolean
  onMutated: () => Promise<void>
}) {
  const { lang, t } = useI18n()
  const locale = lang === 'zh' ? 'zh-Hant' : 'en-US'
  const [payload, setPayload] = useState<SyncDataPayload | null>(null)
  const [pairCode, setPairCode] = useState<{ code: string; serverAddresses: ServerAddresses } | null>(null)
  const [confirmUnpair, setConfirmUnpair] = useState<string | null>(null)
  const [confirmRestore, setConfirmRestore] = useState<number | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    try {
      setPayload(await api.syncData())
      setError(null)
    } catch (e) {
      if (!readOnly) setError((e as Error).message)
    }
  }, [readOnly])

  useEffect(() => {
    if (!readOnly) void load()
  }, [load, readOnly])

  const generateCode = async () => {
    setBusy(true)
    setError(null)
    try {
      const res = await api.newPairCode()
      setPairCode({ code: res.code, serverAddresses: res.serverAddresses })
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const doUnpair = async (hash: string) => {
    setBusy(true)
    try {
      await api.revokePhone(hash)
      setConfirmUnpair(null)
      setNotice(t('Phone unpaired.'))
      await load()
      await onMutated()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const doRestore = async (rev: number) => {
    setBusy(true)
    try {
      await api.restoreVersion(rev)
      setConfirmRestore(null)
      setNotice(t('Version restored.'))
      await load()
      await onMutated()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex flex-col gap-5">
      <div className="flex flex-wrap gap-2">
        {readOnly ? (
          <>
            <Button size="sm" variant="outline" disabled>
              <Download className="mr-1.5 size-4" aria-hidden />
              {t('Download JSON Backup')}
            </Button>
            <Button size="sm" variant="outline" disabled>
              <Download className="mr-1.5 size-4" aria-hidden />
              {t('Download Sets CSV')}
            </Button>
          </>
        ) : (
          <>
            <Button asChild size="sm" variant="outline">
              <a href="/data/latest.json" download>
                <Download className="mr-1.5 size-4" aria-hidden />
                {t('Download JSON Backup')}
              </a>
            </Button>
            <Button asChild size="sm" variant="outline">
              <a href="/data/sets.csv" download>
                <Download className="mr-1.5 size-4" aria-hidden />
                {t('Download Sets CSV')}
              </a>
            </Button>
          </>
        )}
      </div>

      {notice && <div className="rounded-xl border border-primary/30 bg-primary/[0.06] px-4 py-3 text-[13px]">{notice}</div>}
      {error && <div className="rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">{error}</div>}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Panel title={t('Pair a phone')} description={t('A code lets one phone sync with this Mac. It works once, for 5 minutes.')}>
          {pairCode ? (
            <div className="flex flex-col gap-3">
              <div className="flex items-center justify-between gap-3 rounded-xl border border-border bg-muted/40 px-4 py-3">
                <code className="text-[26px] font-semibold tracking-[0.18em]">{pairCode.code}</code>
                <CopyButton text={pairCode.code} />
              </div>
              <p className="text-[12.5px] text-muted-foreground">{t('Expires in 5 minutes · single use')}</p>
              <div className="space-y-1 text-[13px]">
                <p>
                  <span className="text-muted-foreground">{t('Server address')}: </span>
                  <code className="font-medium">{pairCode.serverAddresses.local}</code>
                </p>
                {pairCode.serverAddresses.ip && (
                  <p>
                    <span className="text-muted-foreground">{t('Wi-Fi fallback')}: </span>
                    <code className="font-medium">{pairCode.serverAddresses.ip}</code>
                  </p>
                )}
              </div>
              <div>
                <Button size="sm" variant="outline" disabled={readOnly || busy} onClick={generateCode}>
                  <RefreshCw className="mr-1.5 size-3.5" aria-hidden />
                  {t('Generate Pairing Code')}
                </Button>
              </div>
            </div>
          ) : (
            <div>
              <Button size="sm" disabled={readOnly || busy} onClick={generateCode}>
                {t('Generate Pairing Code')}
              </Button>
            </div>
          )}
        </Panel>

        <Panel title={t('Paired phones')}>
          {!payload || payload.tokens.length === 0 ? (
            <p className="text-[13px] text-muted-foreground">{t('No phone paired yet.')}</p>
          ) : (
            <ul className="divide-y divide-border">
              {payload.tokens.map((tok) => (
                <li key={tok.hash} className="flex items-center justify-between gap-3 py-2.5 first:pt-0 last:pb-0">
                  <div>
                    <p className="text-[13.5px] font-medium">{t('Phone {n}', { n: tok.index })}</p>
                    <p className="text-[12px] text-muted-foreground">{new Date(tok.createdAt * 1000).toLocaleString(locale)}</p>
                  </div>
                  {confirmUnpair === tok.hash ? (
                    <div className="flex items-center gap-1.5">
                      <Button size="sm" variant="destructive" disabled={readOnly || busy} onClick={() => doUnpair(tok.hash)}>
                        {t('Confirm Unpair')}
                      </Button>
                      <Button size="sm" variant="ghost" onClick={() => setConfirmUnpair(null)}>
                        {t('Cancel')}
                      </Button>
                    </div>
                  ) : (
                    <Button size="sm" variant="outline" disabled={readOnly || busy} onClick={() => setConfirmUnpair(tok.hash)}>
                      {t('Unpair')}
                    </Button>
                  )}
                </li>
              ))}
            </ul>
          )}
        </Panel>
      </div>

      <Panel
        title={t('Versions')}
        description={t('Every copy the phone sends is kept. The backup is the openGym JSON the app imports; the CSV has one row per set, for a spreadsheet.')}
      >
        {!payload || payload.versions.length === 0 ? (
          <p className="text-[13px] text-muted-foreground">{t('No data yet.')}</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow className="hover:bg-transparent">
                <TableHead className="text-[12px]">{t('Version')}</TableHead>
                <TableHead className="text-[12px]">{t('Received')}</TableHead>
                <TableHead className="text-right text-[12px]">{t('Workouts')}</TableHead>
                <TableHead className="text-right text-[12px]">{t('Size')}</TableHead>
                <TableHead className="text-right text-[12px]" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {payload.versions.map((v) => (
                <TableRow key={v.rev}>
                  <TableCell className="text-[13px] font-medium">{t('Rev')} {v.rev}</TableCell>
                  <TableCell className="text-[13px] text-muted-foreground">{new Date(v.receivedAt * 1000).toLocaleString(locale)}</TableCell>
                  <TableCell className="text-right text-[13px]">{v.workouts}</TableCell>
                  <TableCell className="text-right text-[13px]">{fmt1(v.bytes / 1024)} KB</TableCell>
                  <TableCell className="text-right">
                    <div className="inline-flex items-center gap-1.5">
                      <Button asChild size="sm" variant="ghost">
                        <a href={`/data/rev/${v.rev}.json`} download>{t('Download')}</a>
                      </Button>
                      {confirmRestore === v.rev ? (
                        <>
                          <Button size="sm" variant="destructive" disabled={readOnly || busy} onClick={() => doRestore(v.rev)}>
                            {t('Confirm Restore')}
                          </Button>
                          <Button size="sm" variant="ghost" onClick={() => setConfirmRestore(null)}>
                            {t('Cancel')}
                          </Button>
                        </>
                      ) : (
                        <Button size="sm" variant="outline" disabled={readOnly || busy} onClick={() => setConfirmRestore(v.rev)}>
                          {t('Restore')}
                        </Button>
                      )}
                    </div>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </Panel>
    </div>
  )
}

export function WebhooksView({ readOnly }: { readOnly: boolean }) {
  const { t } = useI18n()
  const [data, setData] = useState<ConnectPayload | null>(null)
  const [label, setLabel] = useState('')
  const [url, setUrl] = useState('')
  const [selectedEvents, setSelectedEvents] = useState<string[]>(['workout.finished'])
  const [newSecret, setNewSecret] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [confirmDel, setConfirmDel] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const load = useCallback(async () => {
    try {
      setData(await api.connect())
    } catch (e) {
      if (!readOnly) setError((e as Error).message)
    }
  }, [readOnly])

  useEffect(() => {
    if (!readOnly) void load()
  }, [load, readOnly])

  const toggleEvent = (key: string) =>
    setSelectedEvents((prev) => (prev.includes(key) ? prev.filter((x) => x !== key) : [...prev, key]))

  const onAdd = async (e: React.FormEvent) => {
    e.preventDefault()
    setBusy(true)
    setError(null)
    setNewSecret(null)
    setNotice(null)
    try {
      const res = await api.addWebhook({ label: label.trim(), url: url.trim(), events: selectedEvents })
      setNewSecret(res.secret)
      setLabel('')
      setUrl('')
      await load()
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const onTest = async (id: string) => {
    setBusy(true)
    setNotice(null)
    setError(null)
    try {
      const res = await api.testWebhook(id)
      setNotice(`${res.ok ? t('Test sent.') : t('Test failed.')} ${res.message}`)
      await load()
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const onPause = async (id: string, paused: boolean) => {
    setBusy(true)
    try {
      await api.pauseWebhook(id, paused)
      await load()
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const onDelete = async (id: string) => {
    setBusy(true)
    try {
      await api.deleteWebhook(id)
      setConfirmDel(null)
      setNotice(t('Webhook deleted.'))
      await load()
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const eventsList = data?.events ?? [
    { key: 'workout.finished', label: 'Workout finished' },
    { key: 'workout.pr', label: 'New personal record' },
    { key: 'weighin.logged', label: 'Weigh-in logged' },
  ]

  return (
    <div className="flex flex-col gap-5">
      {newSecret && (
        <div className="rounded-2xl border border-primary/40 bg-primary/[0.06] p-4">
          <p className="text-[13.5px] font-medium">{t('Signing secret (shown once)')}</p>
          <p className="mt-0.5 text-[12.5px] text-muted-foreground">{t('Copy this secret now — it cannot be shown again.')}</p>
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <code className="break-all rounded-lg border border-border bg-background px-3 py-1.5 text-[13px]">{newSecret}</code>
            <CopyButton text={newSecret} />
          </div>
        </div>
      )}
      {notice && <div className="rounded-xl border border-primary/30 bg-primary/[0.06] px-4 py-3 text-[13px]">{notice}</div>}
      {error && <div className="rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">{error}</div>}

      <Panel
        title={t('Webhooks')}
        description={t('A signed JSON message to Home Assistant, n8n, Node-RED or ntfy when you finish a workout, set a record or weigh in. Sent when the phone syncs, for what happened in the last seven days.')}
      >
        {!data || data.webhooks.length === 0 ? (
          <p className="text-[13px] text-muted-foreground">{t('No webhooks yet.')}</p>
        ) : (
          <ul className="divide-y divide-border">
            {data.webhooks.map((h) => (
              <li key={h.id} className="flex flex-col gap-2 py-3 first:pt-0 last:pb-0 sm:flex-row sm:items-center sm:justify-between">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-[14px] font-medium">{h.label}</span>
                    <Badge variant={h.paused ? 'secondary' : 'outline'} className="rounded-full text-[11px]">
                      {h.paused ? t('Paused') : h.last_ok === null ? t('Active') : h.last_ok ? t('Delivered') : t('Failed')}
                    </Badge>
                  </div>
                  <p className="mt-0.5 truncate text-[12.5px] text-muted-foreground">
                    {h.maskedUrl} · {h.events.join(', ')}
                  </p>
                  {h.last_msg && <p className="text-[12px] text-muted-foreground">{h.last_msg}</p>}
                </div>
                <div className="flex shrink-0 flex-wrap items-center gap-1.5">
                  <Button size="sm" variant="outline" disabled={readOnly || busy} onClick={() => onTest(h.id)}>
                    <Send className="mr-1.5 size-3.5" aria-hidden />
                    {t('Send Test')}
                  </Button>
                  <Button size="sm" variant="outline" disabled={readOnly || busy} onClick={() => onPause(h.id, !h.paused)}>
                    {h.paused ? <Play className="mr-1.5 size-3.5" aria-hidden /> : <Pause className="mr-1.5 size-3.5" aria-hidden />}
                    {h.paused ? t('Resume') : t('Pause')}
                  </Button>
                  {confirmDel === h.id ? (
                    <>
                      <Button size="sm" variant="destructive" disabled={readOnly || busy} onClick={() => onDelete(h.id)}>
                        {t('Delete')}
                      </Button>
                      <Button size="sm" variant="ghost" onClick={() => setConfirmDel(null)}>
                        {t('Cancel')}
                      </Button>
                    </>
                  ) : (
                    <Button size="sm" variant="ghost" disabled={readOnly || busy} onClick={() => setConfirmDel(h.id)} aria-label={t('Delete')}>
                      <Trash2 className="size-4 text-destructive" aria-hidden />
                    </Button>
                  )}
                </div>
              </li>
            ))}
          </ul>
        )}
      </Panel>

      <Panel title={t('Add Webhook')}>
        <form onSubmit={onAdd} className="flex flex-col gap-3">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-[1fr_2fr]">
            <Input value={label} onChange={(e) => setLabel(e.target.value)} placeholder={t('Name (optional)')} maxLength={60} disabled={readOnly} />
            <Input value={url} onChange={(e) => setUrl(e.target.value)} type="url" required placeholder={t('https://… (the URL your tool gave you)')} disabled={readOnly} />
          </div>
          <div className="flex flex-wrap gap-4 text-[13px]">
            {eventsList.map((ev) => (
              <label key={ev.key} className="inline-flex items-center gap-2">
                <input
                  type="checkbox"
                  checked={selectedEvents.includes(ev.key)}
                  onChange={() => toggleEvent(ev.key)}
                  disabled={readOnly}
                  className="accent-primary"
                />
                <span>{t(ev.label)}</span>
              </label>
            ))}
          </div>
          <div className="flex items-center justify-between gap-3 pt-1">
            <code className="text-[11.5px] text-muted-foreground">X-Hexplate-Signature: t=&lt;seconds&gt;,v1=&lt;HMAC-SHA256&gt;</code>
            <Button type="submit" size="sm" disabled={readOnly || busy || !url.trim() || selectedEvents.length === 0}>
              <Plus className="mr-1.5 size-4" aria-hidden />
              {t('Add Webhook')}
            </Button>
          </div>
        </form>
      </Panel>
    </div>
  )
}

export function McpView({ mcp }: { mcp: McpInfo | null }) {
  const { t } = useI18n()
  const fallbackSnippet = JSON.stringify(
    {
      mcpServers: {
        hexplate: {
          command: '/path/to/server/.venv/bin/python',
          args: ['-m', 'hexserver', 'mcp'],
          env: { PYTHONPATH: '/path/to/server' },
        },
      },
    },
    null,
    2,
  )
  const info = mcp ?? {
    configJson: fallbackSnippet,
    claudeDesktopPath: '~/Library/Application Support/Claude/claude_desktop_config.json',
    claudeCodePath: '.mcp.json',
    dbExists: false,
    tools: [
      { name: 'get_summary', description: 'Totals, recent workouts, this week volume, latest body weight.' },
      { name: 'get_exercise_history', description: 'Per-session Epley 1RM and working sets for an exercise.' },
      { name: 'get_routines', description: 'Saved training routines with sets, reps, weights, and notes.' },
      { name: 'get_schema', description: 'SQLite tables and SQL helpers exname() / e1rm().' },
      { name: 'run_query', description: 'Authorizer-enforced read-only SQLite SELECT query.' },
    ],
  }

  return (
    <div className="flex flex-col gap-5">
      <Panel
        title={t('MCP Server')}
        description={t('Read-only SQLite access for external AI assistants')}
        action={
          <Badge variant="outline" className="gap-1.5 rounded-full">
            <span className={info.dbExists ? 'size-1.5 rounded-full bg-primary' : 'size-1.5 rounded-full bg-muted-foreground'} aria-hidden />
            {info.dbExists ? t('Connected (read-only)') : t('Waiting for first phone sync')}
          </Badge>
        }
      >
        <div className="grid grid-cols-1 gap-3 md:grid-cols-2">
          <div className="rounded-xl border border-border p-4">
            <div className="mb-2 flex items-center justify-between gap-2">
              <p className="text-[13px] font-medium">{t('Claude Desktop Config')}</p>
              <CopyButton text={info.configJson} />
            </div>
            <p className="mb-2 text-[12px] text-muted-foreground">
              <code>{info.claudeDesktopPath}</code>
            </p>
            <pre className="overflow-x-auto rounded-lg bg-muted/60 p-3 text-[11.5px] leading-relaxed">{info.configJson}</pre>
          </div>

          <div className="rounded-xl border border-border p-4">
            <div className="mb-2 flex items-center justify-between gap-2">
              <p className="text-[13px] font-medium">{t('Claude Code (.mcp.json)')}</p>
              <CopyButton text={info.configJson} />
            </div>
            <p className="mb-2 text-[12px] text-muted-foreground">
              <code>{info.claudeCodePath}</code>
            </p>
            <pre className="overflow-x-auto rounded-lg bg-muted/60 p-3 text-[11.5px] leading-relaxed">{info.configJson}</pre>
          </div>
        </div>
      </Panel>

      <Panel title={t('Available MCP Tools')}>
        <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {info.tools.map((tool) => (
            <div key={tool.name} className="rounded-xl border border-border p-3.5">
              <code className="text-[13px] font-semibold text-primary">{tool.name}</code>
              <p className="mt-1.5 text-[12.5px] leading-relaxed text-muted-foreground">{tool.description}</p>
            </div>
          ))}
        </div>
      </Panel>
    </div>
  )
}
