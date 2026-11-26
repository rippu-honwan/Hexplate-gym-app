import { useEffect, useState } from 'react'
import { ChevronRight, Hexagon, Menu, PanelLeft } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { Sheet, SheetContent, SheetDescription, SheetTitle } from '@/components/ui/sheet'
import { ToggleGroup, ToggleGroupItem } from '@/components/ui/toggle-group'
import { Tooltip, TooltipContent, TooltipTrigger } from '@/components/ui/tooltip'
import { useI18n } from '@/i18n'
import { RANGES, SPLITS, type RangeKey, type SplitFilter } from '@/lib/analytics'
import { cn } from '@/lib/utils'
import { NAV_GROUPS, TOP_NAV_ITEMS, VIEW_MAP, type NavGroupKey, type ViewKey } from '@/nav'

export type { ViewKey } from '@/nav'

function Brand({ collapsed }: { collapsed?: boolean }) {
  return (
    <div className={cn('flex h-[68px] shrink-0 items-center gap-2.5 px-5', collapsed && 'justify-center px-0')}>
      <span className="grid size-7 shrink-0 place-items-center rounded-lg bg-primary text-primary-foreground">
        <Hexagon className="size-4" style={{ strokeWidth: 2.25 }} aria-hidden />
      </span>
      {!collapsed && <span className="text-[15px] font-semibold tracking-tight">Hexplate</span>}
    </div>
  )
}

function NavTree({
  view,
  onSelect,
  collapsed,
  aiConfigured,
}: {
  view: ViewKey
  onSelect: (v: ViewKey) => void
  collapsed?: boolean
  aiConfigured?: boolean
}) {
  const { t } = useI18n()
  const activeGroup = VIEW_MAP[view]?.group
  const [openGroups, setOpenGroups] = useState<Record<NavGroupKey, boolean>>({
    training: true,
    'body-recovery': true,
    'watch-reports': false,
    'connect-data': false,
    settings: false,
  })

  useEffect(() => {
    if (activeGroup) {
      setOpenGroups((prev) => (prev[activeGroup] ? prev : { ...prev, [activeGroup]: true }))
    }
  }, [activeGroup])

  const toggleGroup = (key: NavGroupKey) => setOpenGroups((prev) => ({ ...prev, [key]: !prev[key] }))

  if (collapsed) {
    return (
      <nav aria-label={t('Dashboard views')} className="flex flex-1 flex-col items-center gap-1 overflow-y-auto px-2 pb-4">
        {TOP_NAV_ITEMS.map(({ key, label, icon: Icon }) => {
          const active = key === view
          const translated = t(label)
          return (
            <Tooltip key={key}>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  onClick={() => onSelect(key)}
                  aria-current={active ? 'page' : undefined}
                  aria-label={translated}
                  className={cn(
                    'relative flex size-10 items-center justify-center rounded-lg text-sidebar-foreground/80 outline-none transition-colors duration-150 hover:bg-foreground/[0.06] hover:text-sidebar-foreground focus-visible:ring-2 focus-visible:ring-ring',
                    active && 'bg-sidebar-accent text-sidebar-foreground hover:bg-sidebar-accent',
                  )}
                >
                  <Icon className={cn('size-[18px]', active ? 'text-sidebar-primary' : 'text-muted-foreground')} aria-hidden />
                  {key === 'ai-coach' && aiConfigured && (
                    <span className="absolute top-2 right-2 size-1.5 rounded-full bg-primary" aria-hidden />
                  )}
                </button>
              </TooltipTrigger>
              <TooltipContent side="right">{translated}</TooltipContent>
            </Tooltip>
          )
        })}

        <div className="my-1.5 h-px w-6 bg-sidebar-border" aria-hidden />

        {NAV_GROUPS.map((group) => {
          const GroupIcon = group.icon
          const hasActive = group.items.some((item) => item.key === view)
          const groupLabel = t(group.label)
          return (
            <DropdownMenu key={group.key}>
              <Tooltip>
                <TooltipTrigger asChild>
                  <DropdownMenuTrigger asChild>
                    <button
                      type="button"
                      aria-label={groupLabel}
                      className={cn(
                        'flex size-10 items-center justify-center rounded-lg text-sidebar-foreground/80 outline-none transition-colors duration-150 hover:bg-foreground/[0.06] hover:text-sidebar-foreground focus-visible:ring-2 focus-visible:ring-ring',
                        hasActive && 'bg-sidebar-accent text-sidebar-foreground hover:bg-sidebar-accent',
                      )}
                    >
                      <GroupIcon className={cn('size-[18px]', hasActive ? 'text-sidebar-primary' : 'text-muted-foreground')} aria-hidden />
                    </button>
                  </DropdownMenuTrigger>
                </TooltipTrigger>
                <TooltipContent side="right">{groupLabel}</TooltipContent>
              </Tooltip>
              <DropdownMenuContent side="right" align="start" sideOffset={8} className="w-52">
                <DropdownMenuLabel className="text-[11px] font-medium text-muted-foreground">{groupLabel}</DropdownMenuLabel>
                <DropdownMenuSeparator />
                {group.items.map((item) => {
                  const ItemIcon = item.icon
                  const itemActive = item.key === view
                  return (
                    <DropdownMenuItem
                      key={item.key}
                      onSelect={() => onSelect(item.key)}
                      className={cn('gap-2.5 text-[13px]', itemActive && 'bg-sidebar-accent font-medium text-foreground')}
                    >
                      <ItemIcon className={cn('size-4 shrink-0', itemActive ? 'text-primary' : 'text-muted-foreground')} aria-hidden />
                      <span className="truncate">{t(item.label)}</span>
                    </DropdownMenuItem>
                  )
                })}
              </DropdownMenuContent>
            </DropdownMenu>
          )
        })}
      </nav>
    )
  }

  return (
    <nav aria-label={t('Dashboard views')} className="flex flex-1 flex-col gap-1 overflow-y-auto px-3 pb-5">
      <div className="flex flex-col gap-0.5">
        {TOP_NAV_ITEMS.map(({ key, label, icon: Icon }) => {
          const active = key === view
          return (
            <button
              key={key}
              type="button"
              onClick={() => onSelect(key)}
              aria-current={active ? 'page' : undefined}
              className={cn(
                'flex h-9 w-full items-center gap-2.5 rounded-lg px-2.5 text-left text-[13.5px] text-sidebar-foreground/85 outline-none transition-colors duration-150 hover:bg-foreground/[0.06] hover:text-sidebar-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset',
                active && 'bg-sidebar-accent font-medium text-sidebar-foreground hover:bg-sidebar-accent',
              )}
            >
              <Icon className={cn('size-[17px] shrink-0', active ? 'text-sidebar-primary' : 'text-muted-foreground')} aria-hidden />
              <span className="truncate">{t(label)}</span>
              {key === 'ai-coach' && aiConfigured && (
                <span className="ml-auto size-1.5 shrink-0 rounded-full bg-primary" aria-hidden />
              )}
            </button>
          )
        })}
      </div>

      <div className="my-1.5 h-px bg-sidebar-border" aria-hidden />

      <div className="flex flex-col gap-1">
        {NAV_GROUPS.map((group) => {
          const GroupIcon = group.icon
          const open = openGroups[group.key]
          const hasActive = group.items.some((i) => i.key === view)
          return (
            <div key={group.key} className="flex flex-col">
              <button
                type="button"
                onClick={() => toggleGroup(group.key)}
                aria-expanded={open}
                className={cn(
                  'flex h-8 w-full items-center gap-2 rounded-lg px-2.5 text-left text-[12.5px] font-medium text-muted-foreground outline-none transition-colors duration-150 hover:bg-foreground/[0.05] hover:text-sidebar-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset',
                  hasActive && 'text-sidebar-foreground',
                )}
              >
                <GroupIcon className={cn('size-[15px] shrink-0', hasActive ? 'text-sidebar-primary' : 'text-muted-foreground')} aria-hidden />
                <span className="truncate">{t(group.label)}</span>
                <ChevronRight
                  className={cn('ml-auto size-3.5 shrink-0 text-muted-foreground/80 transition-transform duration-150', open && 'rotate-90')}
                  aria-hidden
                />
              </button>
              {open && (
                <div className="mt-0.5 ml-3.5 flex flex-col gap-0.5 border-l border-sidebar-border pl-2.5">
                  {group.items.map((item) => {
                    const ItemIcon = item.icon
                    const active = item.key === view
                    return (
                      <button
                        key={item.key}
                        type="button"
                        onClick={() => onSelect(item.key)}
                        aria-current={active ? 'page' : undefined}
                        className={cn(
                          'flex h-8 w-full items-center gap-2 rounded-md px-2 text-left text-[13px] text-sidebar-foreground/80 outline-none transition-colors duration-150 hover:bg-foreground/[0.06] hover:text-sidebar-foreground focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-inset',
                          active && 'bg-sidebar-accent font-medium text-sidebar-foreground hover:bg-sidebar-accent',
                        )}
                      >
                        <ItemIcon className={cn('size-[15px] shrink-0', active ? 'text-sidebar-primary' : 'text-muted-foreground')} aria-hidden />
                        <span className="truncate">{t(item.label)}</span>
                      </button>
                    )
                  })}
                </div>
              )}
            </div>
          )
        })}
      </div>
    </nav>
  )
}

export function Sidebar({
  view,
  onSelect,
  collapsed,
  aiConfigured,
}: {
  view: ViewKey
  onSelect: (v: ViewKey) => void
  collapsed: boolean
  aiConfigured?: boolean
}) {
  return (
    <aside
      className={cn(
        'no-print hidden shrink-0 border-r border-sidebar-border bg-sidebar md:block',
        collapsed ? 'w-16' : 'w-[238px]',
      )}
    >
      <div className="sticky top-0 flex h-svh flex-col">
        <Brand collapsed={collapsed} />
        <NavTree view={view} onSelect={onSelect} collapsed={collapsed} aiConfigured={aiConfigured} />
      </div>
    </aside>
  )
}

export function MobileNav({
  open,
  onOpenChange,
  view,
  onSelect,
  aiConfigured,
}: {
  open: boolean
  onOpenChange: (o: boolean) => void
  view: ViewKey
  onSelect: (v: ViewKey) => void
  aiConfigured?: boolean
}) {
  const { t } = useI18n()
  return (
    <Sheet open={open} onOpenChange={onOpenChange}>
      <SheetContent side="left" className="w-[272px] gap-0 border-sidebar-border bg-sidebar p-0 shadow-none">
        <SheetTitle className="sr-only">{t('Navigation')}</SheetTitle>
        <SheetDescription className="sr-only">{t('Dashboard views')}</SheetDescription>
        <Brand />
        <NavTree
          view={view}
          onSelect={(v) => {
            onSelect(v)
            onOpenChange(false)
          }}
          aiConfigured={aiConfigured}
        />
      </SheetContent>
    </Sheet>
  )
}

export function Header(props: {
  title: string
  lede: string
  showFilters: boolean
  range: RangeKey
  onRange: (r: RangeKey) => void
  split: SplitFilter
  onSplit: (s: SplitFilter) => void
  onToggleSidebar: () => void
  onOpenMobileNav: () => void
  source: 'mock' | 'local'
  serverReachable: boolean
  onOpenGeneralSettings: () => void
}) {
  const { t } = useI18n()
  const isSample = props.source === 'mock'
  return (
    <header className="no-print sticky top-0 z-20 border-b border-border bg-background/80 backdrop-blur-xl supports-[backdrop-filter]:bg-background/70">
      <div className="flex min-h-[68px] flex-wrap items-center gap-x-3 gap-y-2 px-4 py-3 md:px-7">
        <Button variant="ghost" size="icon" className="md:hidden" onClick={props.onOpenMobileNav} aria-label={t('Open navigation')}>
          <Menu aria-hidden />
        </Button>
        <Button variant="ghost" size="icon" className="hidden md:inline-flex" onClick={props.onToggleSidebar} aria-label={t('Toggle sidebar')}>
          <PanelLeft aria-hidden />
        </Button>
        <div className="mr-auto min-w-0">
          <h1 className="truncate text-[17px] font-semibold">{props.title}</h1>
          <p className="hidden truncate text-[13px] text-muted-foreground lg:block">{props.lede}</p>
        </div>

        {props.showFilters && (
          <div className="order-last flex w-full items-center gap-2 sm:order-none sm:w-auto">
            <ToggleGroup
              type="single"
              value={props.range}
              onValueChange={(v) => v && props.onRange(v as RangeKey)}
              variant="outline"
              size="sm"
              spacing={0}
              aria-label={t('Date range')}
              className="shrink-0"
            >
              {RANGES.map((r) => (
                <ToggleGroupItem key={r.key} value={r.key} className="px-3 data-[state=on]:bg-foreground data-[state=on]:text-background">
                  {r.label}
                </ToggleGroupItem>
              ))}
            </ToggleGroup>
            <Select value={props.split} onValueChange={(v) => props.onSplit(v as SplitFilter)}>
              <SelectTrigger size="sm" className="ml-auto w-[140px] sm:ml-0" aria-label={t('Training split filter')}>
                <SelectValue />
              </SelectTrigger>
              <SelectContent align="end">
                {SPLITS.map((s) => (
                  <SelectItem key={s.key} value={s.key}>
                    {t(s.label)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>
        )}

        <button
          type="button"
          onClick={props.onOpenGeneralSettings}
          className="outline-none focus-visible:ring-2 focus-visible:ring-ring rounded-full"
          title={isSample ? t('Sample data') : t('Local')}
        >
          <Badge variant="outline" className="h-6 gap-1.5 rounded-full px-2.5 font-normal text-muted-foreground hover:bg-foreground/[0.04]">
            <span className={cn('size-1.5 rounded-full', isSample ? 'bg-amber-500' : 'bg-primary')} aria-hidden />
            {isSample ? t('Sample data') : t('Local')}
          </Badge>
        </button>
      </div>
      {isSample && (
        <div className="border-t border-border bg-muted/60 px-4 py-1.5 text-[12px] text-muted-foreground md:px-7">
          {props.serverReachable
            ? t('Sample mode active — write actions are disabled. Switch back to Local data in Settings to edit.')
            : t('Standalone preview — connect to the Hexplate server for live data and write actions.')}
        </div>
      )}
    </header>
  )
}
