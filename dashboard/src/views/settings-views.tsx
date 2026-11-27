import { useEffect, useState } from 'react'
import { CheckCircle2, Eye, EyeOff, HardDrive, KeyRound, Plug, RefreshCw, ShieldCheck, Trash2 } from 'lucide-react'
import { MeterRow, Panel } from '@/components/charts'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { useI18n, type LangCode } from '@/i18n'
import { api } from '@/lib/api'
import { fmtInt } from '@/lib/format'
import type { AiConfigMasked, BackupStatus, SigningStatus } from '@/types/hexplate'

function originOfUrl(raw: string | null | undefined): string | null {
  if (!raw || !raw.trim()) return null
  try {
    const u = new URL(raw.trim())
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null
    return u.origin.toLowerCase()
  } catch {
    return null
  }
}

export function SettingsGeneralView({
  dark,
  onSetDark,
  serverReachable,
  sampleMode,
  previewOnly,
  serverLang,
  onSetSampleMode,
  onLangChanged,
}: {
  dark: boolean
  onSetDark: (next: boolean) => void
  serverReachable: boolean
  sampleMode: boolean
  previewOnly: boolean
  serverLang?: LangCode
  onSetSampleMode: (next: boolean) => void
  onLangChanged: (lang: LangCode, strings: Record<string, string>) => Promise<void>
}) {
  const { lang, hasZhStrings, languages, t, setLocalLang } = useI18n()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const selectLang = async (code: LangCode) => {
    const canPersist = serverReachable && !previewOnly
    const alreadySynced = code === lang && (code !== 'zh' || hasZhStrings) && (!canPersist || serverLang === code)
    if (alreadySynced) return
    setError(null)
    if (canPersist) {
      setBusy(true)
      try {
        const res = await api.setLang(code)
        await onLangChanged(res.lang, res.strings)
      } catch (e) {
        setError((e as Error).message)
      } finally {
        setBusy(false)
      }
      return
    }
    if (code === 'en') {
      setLocalLang('en')
      return
    }
    if (hasZhStrings) {
      setLocalLang('zh')
      return
    }
    if (!serverReachable) {
      setError(t('Switch to Local Server or connect to the server to load Traditional Chinese.'))
      return
    }
    setBusy(true)
    try {
      const res = await api.i18n('zh')
      if (Object.keys(res.strings).length > 0) {
        setLocalLang('zh', res.strings)
      } else {
        setError(t('Switch to Local Server or connect to the server to load Traditional Chinese.'))
      }
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="flex flex-col gap-5">
      {error && <div className="rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">{error}</div>}

      <Panel
        title={t('Interface Language')}
        description={t('Choose English or Traditional Chinese for the web dashboard. Synced with your server setting.')}
      >
        <div className="flex flex-col gap-2.5">
          <div className="flex flex-wrap gap-2">
            {languages.map((opt) => (
              <Button
                key={opt.code}
                size="sm"
                variant={lang === opt.code ? 'default' : 'outline'}
                disabled={busy}
                onClick={() => void selectLang(opt.code)}
              >
                {opt.label}
              </Button>
            ))}
          </div>
          {previewOnly && serverReachable && (
            <p className="text-[12px] text-muted-foreground">
              {t('Preview language only — switch to Local Server to save on server.')}
            </p>
          )}
          {lang === 'zh' && !hasZhStrings && (
            <p className="text-[12px] text-muted-foreground">
              {t('Switch to Local Server or connect to the server to load Traditional Chinese.')}
            </p>
          )}
        </div>
      </Panel>

      <Panel title={t('Appearance')}>
        <div className="flex flex-wrap gap-2">
          <Button size="sm" variant={!dark ? 'default' : 'outline'} onClick={() => onSetDark(false)}>
            {t('Light')}
          </Button>
          <Button size="sm" variant={dark ? 'default' : 'outline'} onClick={() => onSetDark(true)}>
            {t('Dark')}
          </Button>
        </div>
      </Panel>

      <Panel title={t('Data Source')}>
        <div className="flex flex-wrap items-center gap-2">
          <Button
            size="sm"
            variant={!sampleMode && serverReachable ? 'default' : 'outline'}
            disabled={!serverReachable}
            onClick={() => onSetSampleMode(false)}
          >
            {t('Local Server')}
          </Button>
          <Button size="sm" variant={sampleMode || !serverReachable ? 'default' : 'outline'} onClick={() => onSetSampleMode(true)}>
            {t('Sample Preview')}
          </Button>
        </div>
      </Panel>
    </div>
  )
}

export function SettingsAiView({
  ai,
  readOnly,
  onUpdated,
}: {
  ai: AiConfigMasked | null
  readOnly: boolean
  onUpdated: (next: AiConfigMasked) => void
}) {
  const { t } = useI18n()
  const [baseUrl, setBaseUrl] = useState(ai?.baseUrl ?? '')
  const [model, setModel] = useState(ai?.model ?? '')
  const [fallbackModel, setFallbackModel] = useState(ai?.fallbackModel ?? '')
  const [apiKey, setApiKey] = useState('')
  const [showKey, setShowKey] = useState(false)
  const [dailyCap, setDailyCap] = useState(String(ai?.dailyTokenCap ?? 200000))
  const [rateLimit, setRateLimit] = useState(String(ai?.rateLimitPerMin ?? 10))
  const [saving, setSaving] = useState(false)
  const [testing, setTesting] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!ai) return
    setBaseUrl(ai.baseUrl ?? '')
    setModel(ai.model ?? '')
    setFallbackModel(ai.fallbackModel ?? '')
    setDailyCap(String(ai.dailyTokenCap))
    setRateLimit(String(ai.rateLimitPerMin))
  }, [ai])

  const hostChanged = Boolean(ai?.hasKey && ai?.baseUrl && originOfUrl(baseUrl) !== originOfUrl(ai.baseUrl))

  const sourceLabel = (src: AiConfigMasked['source'] | undefined) => {
    if (src === 'file') return t('Saved file (0600)')
    if (src === 'env') return t('Environment variables')
    if (src === 'mixed') return t('File + Environment')
    return t('None')
  }

  const onSave = async (e: React.FormEvent) => {
    e.preventDefault()
    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const capNum = Number(dailyCap)
      const rateNum = Number(rateLimit)
      const updated = await api.saveAiConfig({
        baseUrl: baseUrl.trim(),
        model: model.trim(),
        fallbackModel: fallbackModel.trim(),
        apiKey: apiKey.trim() || undefined,
        dailyTokenCap: Number.isFinite(capNum) ? Math.trunc(capNum) : undefined,
        rateLimitPerMin: Number.isFinite(rateNum) ? Math.trunc(rateNum) : undefined,
      })
      setApiKey('')
      onUpdated(updated)
      setNotice(t('Configuration saved.'))
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const onTest = async () => {
    setTesting(true)
    setError(null)
    setNotice(null)
    try {
      const res = await api.testAiConnection({
        baseUrl: baseUrl.trim() || undefined,
        model: model.trim() || undefined,
        fallbackModel: fallbackModel.trim(),
        apiKey: apiKey.trim() || undefined,
      })
      setNotice(t('Connection succeeded ({ms} ms, model: {model}).', { ms: res.elapsedMs, model: res.model }))
      const latest = await api.getAiConfig()
      onUpdated(latest)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setTesting(false)
    }
  }

  const onClearKey = async () => {
    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const updated = await api.saveAiConfig({ clearApiKey: true })
      setApiKey('')
      onUpdated(updated)
      setNotice(t('Saved key cleared.'))
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const onResetEnv = async () => {
    setSaving(true)
    setError(null)
    setNotice(null)
    try {
      const updated = await api.saveAiConfig({ resetToEnv: true })
      setApiKey('')
      onUpdated(updated)
      setNotice(t('Reset to environment variables.'))
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setSaving(false)
    }
  }

  const used = ai?.dailyTokensUsed ?? 0
  const cap = ai?.dailyTokenCap ?? 200000

  return (
    <div className="flex flex-col gap-5">
      {notice && (
        <div className="flex items-center gap-2 rounded-xl border border-primary/35 bg-primary/[0.06] px-4 py-3 text-[13px]">
          <CheckCircle2 className="size-4 shrink-0 text-primary" aria-hidden />
          <span>{notice}</span>
        </div>
      )}
      {error && (
        <div className="rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">
          {error}
        </div>
      )}

      <Panel
        title={t('AI Provider Configuration')}
        description={t('Configure any OpenAI-compatible API (OpenAI, OpenRouter, Gemini OpenAI endpoint, local Ollama/vLLM). Used immediately by both this Web AI Coach and your iPhone app without restarting the server.')}
        action={
          <Badge variant={ai?.configured ? 'default' : 'outline'} className="rounded-full">
            {ai?.configured ? t('Configured') : t('Not configured')}
          </Badge>
        }
      >
        <form onSubmit={onSave} className="flex flex-col gap-4">
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            <label className="flex flex-col gap-1.5 text-[13px]">
              <span className="font-medium">{t('Provider Base URL')}</span>
              <Input
                value={baseUrl}
                onChange={(e) => setBaseUrl(e.target.value)}
                placeholder="https://api.openai.com/v1"
                disabled={readOnly || saving}
                autoComplete="off"
              />
            </label>
            <label className="flex flex-col gap-1.5 text-[13px]">
              <span className="font-medium">{t('Model Name')}</span>
              <Input
                value={model}
                onChange={(e) => setModel(e.target.value)}
                placeholder="gpt-4o-mini"
                disabled={readOnly || saving}
                autoComplete="off"
              />
            </label>
            <label className="flex flex-col gap-1.5 text-[13px]">
              <span className="font-medium">{t('Fallback Model (Optional)')}</span>
              <Input
                value={fallbackModel}
                onChange={(e) => setFallbackModel(e.target.value)}
                placeholder="gemini-flash-lite-latest"
                disabled={readOnly || saving}
                autoComplete="off"
              />
            </label>
          </div>

          <label className="flex flex-col gap-1.5 text-[13px]">
            <div className="flex items-center justify-between gap-2">
              <span className="font-medium">{t('API Key')}</span>
              {ai?.hasKey && (
                <span className="inline-flex items-center gap-1 text-[12px] text-muted-foreground">
                  <KeyRound className="size-3.5" aria-hidden />
                  {ai.keyHint ? `${t('Saved key')}: ${ai.keyHint}` : t('Key saved (hidden)')}
                </span>
              )}
            </div>
            <div className="relative">
              <Input
                type={showKey ? 'text' : 'password'}
                value={apiKey}
                onChange={(e) => setApiKey(e.target.value)}
                placeholder={
                  hostChanged
                    ? t('Enter a new API key (required when changing host)')
                    : ai?.hasKey
                      ? t('Leave blank to keep the saved key for this host')
                      : 'sk-...'
                }
                disabled={readOnly || saving}
                autoComplete="new-password"
                className="pr-10"
              />
              <button
                type="button"
                onClick={() => setShowKey((s) => !s)}
                aria-label={showKey ? t('Hide key') : t('Show key')}
                className="absolute top-1/2 right-2.5 -translate-y-1/2 text-muted-foreground hover:text-foreground"
              >
                {showKey ? <EyeOff className="size-4" aria-hidden /> : <Eye className="size-4" aria-hidden />}
              </button>
            </div>
          </label>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <label className="flex flex-col gap-1.5 text-[13px]">
              <span className="font-medium">{t('Daily Token Cap')}</span>
              <Input
                type="number"
                min={1}
                max={10000000}
                value={dailyCap}
                onChange={(e) => setDailyCap(e.target.value)}
                disabled={readOnly || saving}
              />
            </label>
            <label className="flex flex-col gap-1.5 text-[13px]">
              <span className="font-medium">{t('Rate Limit (req / min)')}</span>
              <Input
                type="number"
                min={1}
                max={600}
                value={rateLimit}
                onChange={(e) => setRateLimit(e.target.value)}
                disabled={readOnly || saving}
              />
            </label>
          </div>

          <div className="flex flex-wrap items-center gap-2 pt-1">
            <Button type="submit" size="sm" disabled={readOnly || saving || testing}>
              {saving ? t('Saving…') : t('Save Configuration')}
            </Button>
            <Button type="button" size="sm" variant="outline" disabled={readOnly || saving || testing} onClick={() => void onTest()}>
              <Plug className="mr-1.5 size-3.5" aria-hidden />
              {testing ? t('Testing…') : t('Test Connection')}
            </Button>
            {ai?.hasKey && (ai.source === 'file' || ai.source === 'mixed') && (
              <Button type="button" size="sm" variant="ghost" disabled={readOnly || saving || testing} onClick={() => void onClearKey()}>
                <Trash2 className="mr-1.5 size-3.5" aria-hidden />
                {t('Clear Saved Key')}
              </Button>
            )}
            {(ai?.source === 'file' || ai?.source === 'mixed') && (
              <Button type="button" size="sm" variant="ghost" disabled={readOnly || saving || testing} onClick={() => void onResetEnv()}>
                {t('Reset to Environment')}
              </Button>
            )}
          </div>
        </form>
      </Panel>

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Panel title={t('24-Hour Token Usage')} description={`${t('Config source')}: ${sourceLabel(ai?.source)}`}>
          <ul className="flex flex-col gap-3">
            <MeterRow
              label={t('24-Hour Token Usage')}
              value={t('{used} / {cap} tokens', { used: fmtInt(used), cap: fmtInt(cap) })}
              fraction={cap > 0 ? used / cap : 0}
            />
          </ul>
        </Panel>

        <Panel title={t('Security & Storage')}>
          <div className="flex items-start gap-3 text-[13px] leading-relaxed text-muted-foreground">
            <ShieldCheck className="mt-0.5 size-5 shrink-0 text-primary" aria-hidden />
            <p>
              {t('Your API key is stored exclusively in a local 0600 file (<data_dir>/ai-config.json) outside SQLite and is never copied into iCloud backups or JSON exports. Saved keys are strictly bound to their provider origin.')}
            </p>
          </div>
        </Panel>
      </div>
    </div>
  )
}

export function SettingsBackupView({
  backup,
  signing,
  readOnly,
  onRefresh,
}: {
  backup: BackupStatus | null
  signing: SigningStatus | null
  readOnly: boolean
  onRefresh: () => Promise<void>
}) {
  const { lang, t } = useI18n()
  const locale = lang === 'zh' ? 'zh-Hant' : 'en-US'
  const [busy, setBusy] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!signing?.running || readOnly) return
    const id = window.setInterval(() => {
      void onRefresh()
    }, 3000)
    return () => window.clearInterval(id)
  }, [signing?.running, readOnly, onRefresh])

  const toggleBackup = async () => {
    if (!backup) return
    setBusy(true)
    setError(null)
    try {
      await api.setBackup(!backup.on)
      await onRefresh()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const runBackupNow = async () => {
    setBusy(true)
    setError(null)
    setNotice(null)
    try {
      const res = await api.runBackup()
      setNotice(res.ok ? t('Backed up: {n} new Watch recordings and the database.', { n: res.copied }) : t('Backup failed.'))
      await onRefresh()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const runSigning = async () => {
    setBusy(true)
    setError(null)
    try {
      await api.runSigning()
      await onRefresh()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  const daysLeft = signing?.expires ? Math.ceil((signing.expires * 1000 - Date.now()) / 86_400_000) : null

  return (
    <div className="flex flex-col gap-5">
      {notice && <div className="rounded-xl border border-primary/30 bg-primary/[0.06] px-4 py-3 text-[13px]">{notice}</div>}
      {error && <div className="rounded-xl border border-destructive/40 bg-destructive/10 px-4 py-3 text-[13px] text-destructive">{error}</div>}

      <Panel
        title={t('Backup')}
        description={t("The Watch hands each set's recording to the phone, then deletes its own. The phone sends it to this Mac, which saves it and copies it to the backup; only then does the phone delete its copy. Your training log stays on the phone and is kept here in every version, copied to the backup a minute after each sync.")}
        action={
          backup && (
            <Button size="sm" variant="outline" disabled={readOnly || busy} onClick={() => void toggleBackup()}>
              {backup.on ? t('Turn off') : t('Turn on')}
            </Button>
          )
        }
      >
        {backup ? (
          <div className="flex flex-col gap-3">
            <dl className="divide-y divide-border text-[13.5px]">
              <div className="flex items-center justify-between gap-4 py-2.5 first:pt-0">
                <dt className="text-muted-foreground">{t('Status')}</dt>
                <dd className="font-medium">
                  {!backup.on
                    ? t('Backup is off')
                    : backup.error
                      ? <span className="text-destructive">{backup.error}</span>
                      : backup.at
                        ? new Date(backup.at * 1000).toLocaleString(locale)
                        : t('Not backed up yet')}
                </dd>
              </div>
              <div className="flex items-center justify-between gap-4 py-2.5">
                <dt className="text-muted-foreground">{t('Folder')}</dt>
                <dd className="truncate font-mono text-[12.5px]">{backup.folder}</dd>
              </div>
              <div className="flex items-center justify-between gap-4 py-2.5">
                <dt className="text-muted-foreground">{t('Daily copies')}</dt>
                <dd>{t('{n} of the latest {k} days', { n: backup.copies, k: 30 })}</dd>
              </div>
              <div className="flex items-center justify-between gap-4 py-2.5 last:pb-0">
                <dt className="text-muted-foreground">{t('Watch recordings')}</dt>
                <dd>{t('{n} files', { n: backup.motion })}</dd>
              </div>
            </dl>
            {backup.on && (
              <div className="pt-1">
                <Button size="sm" disabled={readOnly || busy} onClick={() => void runBackupNow()}>
                  <HardDrive className="mr-1.5 size-4" aria-hidden />
                  {t('Back up now')}
                </Button>
              </div>
            )}
          </div>
        ) : (
          <p className="text-[13px] text-muted-foreground">{t('No data yet.')}</p>
        )}
      </Panel>

      <Panel
        title={t('Apple ID signing')}
        description={
          signing?.available
            ? t('Free Apple ID profiles expire every 7 days, which stops Hexplate from opening. Keep your iPhone unlocked on USB or the same Wi-Fi, then click to re-sign with Xcode and reinstall without losing data.')
            : t('This server runs on Linux without Xcode. Refresh signing from your Mac with Hexplate Sign.app (or python -m hexserver sign) — the new expiry date syncs back here automatically.')
        }
      >
        {signing ? (
          <div className="flex flex-col gap-3">
            <dl className="divide-y divide-border text-[13.5px]">
              <div className="flex items-center justify-between gap-4 py-2.5 first:pt-0">
                <dt className="text-muted-foreground">{t('Status')}</dt>
                <dd className="font-medium">
                  {signing.running
                    ? signing.stage || t('Refreshing…')
                    : signing.error
                      ? <span className="text-destructive">{signing.error}</span>
                      : signing.at
                        ? new Date(signing.at * 1000).toLocaleString(locale)
                        : signing.available
                          ? t('Not refreshed from this server yet')
                          : t('Run on your Mac (requires macOS and Xcode)')}
                </dd>
              </div>
              {signing.device && (
                <div className="flex items-center justify-between gap-4 py-2.5">
                  <dt className="text-muted-foreground">{t('Device')}</dt>
                  <dd>{signing.device}</dd>
                </div>
              )}
              {signing.expires && (
                <div className="flex items-center justify-between gap-4 py-2.5 last:pb-0">
                  <dt className="text-muted-foreground">{t('Valid until')}</dt>
                  <dd className={daysLeft !== null && daysLeft <= 1 ? 'font-medium text-destructive' : ''}>
                    {new Date(signing.expires * 1000).toLocaleString(locale)}
                    {daysLeft !== null && daysLeft > 0 ? ` · ${t(daysLeft === 1 ? '{n} day left' : '{n} days left', { n: daysLeft })}` : ''}
                  </dd>
                </div>
              )}
            </dl>
            {signing.available && (
              <div className="pt-1">
                <Button size="sm" disabled={readOnly || busy || signing.running} onClick={() => void runSigning()}>
                  <RefreshCw className={`mr-1.5 size-4 ${signing.running ? 'animate-spin' : ''}`} aria-hidden />
                  {signing.running ? t('Refreshing…') : t('Refresh Apple ID signing')}
                </Button>
              </div>
            )}
          </div>
        ) : (
          <p className="text-[13px] text-muted-foreground">{t('No data yet.')}</p>
        )}
      </Panel>
    </div>
  )
}
