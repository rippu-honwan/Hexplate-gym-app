import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { TooltipProvider } from '@/components/ui/tooltip'
import { Header, MobileNav, Sidebar } from '@/components/shell'
import { buildMockDataset } from '@/data/mock'
import { useI18n, type LangCode } from '@/i18n'
import type { RangeKey, SplitFilter } from '@/lib/analytics'
import { api } from '@/lib/api'
import type { Granularity } from '@/lib/dates'
import { VIEW_MAP, formatHashRoute, parseHashRoute, type RouteState, type ViewKey } from '@/nav'
import type { AiConfigMasked, BootstrapData, HexplateDataset } from '@/types/hexplate'
import { AnalyticsViews } from '@/views/analytics-views'
import { CoachView } from '@/views/coach-view'
import { McpView, SyncDataView, WebhooksView } from '@/views/connect-views'
import { SettingsAiView, SettingsBackupView, SettingsGeneralView } from '@/views/settings-views'
import { BodyView, ExerciseDetailView, ExercisesView, PlanView, ReportView, StatsView, WorkoutDetailView } from '@/views/training-views'
import { MotionDetailView, MotionListView, RepCounterView } from '@/views/watch-views'

function useTheme() {
  const [dark, setDark] = useState(() => document.documentElement.classList.contains('dark'))
  useEffect(() => {
    document.documentElement.classList.toggle('dark', dark)
    document.documentElement.style.colorScheme = dark ? 'dark' : 'light'
  }, [dark])
  const setExplicit = (next: boolean) => {
    localStorage.setItem('hexplate-theme', next ? 'dark' : 'light')
    setDark(next)
  }
  return [dark, setExplicit] as const
}

export default function App() {
  const mockData = useMemo(() => buildMockDataset(), [])
  const { lang, hasZhStrings, t, applyServerLocale, setLocalLang } = useI18n()
  const [route, setRoute] = useState<RouteState>(() => parseHashRoute(window.location.hash))
  const [range, setRange] = useState<RangeKey>('30d')
  const [split, setSplit] = useState<SplitFilter>('all')
  const [granularity, setGranularity] = useState<Granularity>('daily')
  const [collapsed, setCollapsed] = useState(false)
  const [mobileNav, setMobileNav] = useState(false)
  const [dark, setDark] = useTheme()

  const [bootstrap, setBootstrap] = useState<BootstrapData | null>(null)
  const [liveData, setLiveData] = useState<HexplateDataset | null>(null)
  const [serverReachable, setServerReachable] = useState(false)
  const [sampleOverride, setSampleOverride] = useState(false)

  const navigate = useCallback((view: ViewKey, detailId: string | null = null) => {
    setRoute({ view, detailId })
    const nextHash = formatHashRoute(view, detailId)
    if (window.location.hash !== nextHash) {
      window.location.hash = nextHash
    }
  }, [])

  useEffect(() => {
    const onHash = () => setRoute(parseHashRoute(window.location.hash))
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [])

  const refreshServer = useCallback(async () => {
    try {
      const boot = await api.bootstrap()
      setBootstrap(boot)
      setServerReachable(true)
      applyServerLocale(boot.lang as LangCode, boot.strings, boot.languages)
    } catch {
      setServerReachable(false)
      return
    }
    try {
      const ds = await api.dataset()
      setLiveData(ds)
    } catch {
      setLiveData(null)
    }
  }, [applyServerLocale])

  useEffect(() => {
    void refreshServer()
  }, [refreshServer])

  // One-shot self-healing hydration when lang is 'zh' with an empty cached dictionary.
  const hydrateAttemptRef = useRef<string | null>(null)
  useEffect(() => {
    if (hasZhStrings || lang !== 'zh') {
      hydrateAttemptRef.current = null
      return
    }
    if (!serverReachable) return
    const attemptKey = `${lang}:${serverReachable}`
    if (hydrateAttemptRef.current === attemptKey) return
    hydrateAttemptRef.current = attemptKey
    let active = true
    api
      .i18n('zh')
      .then((res) => {
        if (active && Object.keys(res.strings).length > 0) {
          setLocalLang('zh', res.strings)
        }
      })
      .catch(() => {
        // One-shot attempt; Settings shows a clear recovery note if unreachable.
      })
    return () => {
      active = false
    }
  }, [hasZhStrings, lang, serverReachable, setLocalLang])

  const handleSetSampleMode = useCallback(
    (next: boolean) => {
      setSampleOverride(next)
      if (!next) {
        if (bootstrap) {
          applyServerLocale(bootstrap.lang as LangCode, bootstrap.strings, bootstrap.languages)
        }
        void refreshServer()
      }
    },
    [applyServerLocale, bootstrap, refreshServer],
  )

  const handleLangChanged = useCallback(
    async (nextLang: LangCode, nextStrings: Record<string, string>) => {
      applyServerLocale(nextLang, nextStrings)
      await refreshServer()
    },
    [applyServerLocale, refreshServer],
  )

  const handleAiUpdated = useCallback((next: AiConfigMasked) => {
    setBootstrap((prev) => (prev ? { ...prev, ai: next } : prev))
  }, [])

  const useSample = !serverReachable || sampleOverride || !liveData
  const data = useSample ? mockData : liveData
  const meta = VIEW_MAP[route.view]

  useEffect(() => {
    document.title = `${t(meta.label)} · Hexplate`
  }, [meta.label, t])

  const renderContent = () => {
    if (route.view === 'sessions' && route.detailId) {
      return (
        <WorkoutDetailView
          workoutId={route.detailId}
          readOnlySample={useSample}
          onBack={() => navigate('sessions', null)}
          onOpenExercise={(exId) => navigate('exercises', exId)}
          onOpenMotion={(wid) => navigate('motion', wid)}
        />
      )
    }
    if (route.view === 'exercises' && route.detailId) {
      return (
        <ExerciseDetailView
          exerciseId={route.detailId}
          readOnlySample={useSample}
          onBack={() => navigate('exercises', null)}
          onOpenWorkout={(wid) => navigate('sessions', wid)}
        />
      )
    }
    if (route.view === 'motion' && route.detailId) {
      return (
        <MotionDetailView
          workoutId={route.detailId}
          readOnlySample={useSample}
          onBack={() => navigate('motion', null)}
          onOpenWorkout={(wid) => navigate('sessions', wid)}
        />
      )
    }

    switch (route.view) {
      case 'overview':
      case 'volume':
      case 'muscle-targets':
      case 'recovery':
      case 'nutrition':
      case 'sessions':
        return (
          <AnalyticsViews
            view={route.view}
            data={data}
            range={range}
            split={split}
            granularity={granularity}
            onGranularity={setGranularity}
            onNavigate={(v) => navigate(v, null)}
            onOpenWorkout={(id) => navigate('sessions', id)}
            onSwitchSample={serverReachable ? () => setSampleOverride(true) : undefined}
          />
        )
      case 'ai-coach':
        return (
          <CoachView
            readOnly={useSample}
            ai={bootstrap?.ai ?? null}
            initialUndo={bootstrap?.aiUndo ?? null}
            onOpenAiSettings={() => navigate('settings-ai')}
            onPlanMutated={refreshServer}
          />
        )
      case 'plan':
        return <PlanView data={data} />
      case 'exercises':
        return <ExercisesView data={data} onOpenExercise={(exId) => navigate('exercises', exId)} />
      case 'body':
        return <BodyView data={data} />
      case 'stats':
        return <StatsView data={data} onOpenExercise={(exId) => navigate('exercises', exId)} />
      case 'report':
        return <ReportView readOnlySample={useSample} onOpenWorkout={(wid) => navigate('sessions', wid)} />
      case 'reps':
        return <RepCounterView data={data} />
      case 'motion':
        return <MotionListView data={data} onOpenMotion={(wid) => navigate('motion', wid)} />
      case 'sync-data':
        return <SyncDataView readOnly={useSample} onMutated={refreshServer} />
      case 'webhooks':
        return <WebhooksView readOnly={useSample} />
      case 'mcp':
        return <McpView mcp={bootstrap?.mcp ?? null} />
      case 'settings-general':
        return (
          <SettingsGeneralView
            dark={dark}
            onSetDark={setDark}
            serverReachable={serverReachable}
            sampleMode={useSample}
            previewOnly={sampleOverride}
            serverLang={bootstrap?.lang as LangCode | undefined}
            onSetSampleMode={handleSetSampleMode}
            onLangChanged={handleLangChanged}
          />
        )
      case 'settings-ai':
        return <SettingsAiView ai={bootstrap?.ai ?? null} readOnly={useSample} onUpdated={handleAiUpdated} />
      case 'settings-backup':
        return (
          <SettingsBackupView
            backup={bootstrap?.backup ?? null}
            signing={bootstrap?.signing ?? null}
            readOnly={useSample}
            onRefresh={refreshServer}
          />
        )
    }
  }

  return (
    <TooltipProvider delayDuration={300}>
      <div className="flex min-h-svh bg-background text-foreground">
        <Sidebar view={route.view} onSelect={(v) => navigate(v, null)} collapsed={collapsed} aiConfigured={bootstrap?.ai.configured} />
        <MobileNav open={mobileNav} onOpenChange={setMobileNav} view={route.view} onSelect={(v) => navigate(v, null)} aiConfigured={bootstrap?.ai.configured} />
        <div className="flex min-w-0 flex-1 flex-col">
          <Header
            title={t(meta.label)}
            lede={t(meta.lede)}
            showFilters={Boolean(meta.hasAnalyticsFilters && !route.detailId)}
            range={range}
            onRange={setRange}
            split={split}
            onSplit={setSplit}
            onToggleSidebar={() => setCollapsed((c) => !c)}
            onOpenMobileNav={() => setMobileNav(true)}
            source={useSample ? 'mock' : 'local'}
            serverReachable={serverReachable}
            onOpenGeneralSettings={() => navigate('settings-general')}
          />
          <main className="mx-auto flex w-full max-w-[1280px] flex-col gap-4 px-4 py-5 md:gap-5 md:px-7 md:py-7">
            {renderContent()}
          </main>
        </div>
      </div>
    </TooltipProvider>
  )
}
