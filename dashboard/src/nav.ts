import {
  Activity,
  BarChart3,
  Bot,
  CalendarDays,
  ChartColumn,
  Cpu,
  Dumbbell,
  FileText,
  Gauge,
  HardDrive,
  HeartPulse,
  LayoutGrid,
  Link2,
  ListChecks,
  Scale,
  Server,
  Settings,
  SlidersHorizontal,
  Sparkles,
  Target,
  Utensils,
  Watch,
  Webhook,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

export type ViewKey =
  | 'overview'
  | 'ai-coach'
  | 'sessions'
  | 'volume'
  | 'plan'
  | 'exercises'
  | 'muscle-targets'
  | 'recovery'
  | 'body'
  | 'nutrition'
  | 'stats'
  | 'report'
  | 'reps'
  | 'motion'
  | 'sync-data'
  | 'webhooks'
  | 'mcp'
  | 'settings-general'
  | 'settings-ai'
  | 'settings-backup'

export type NavGroupKey = 'training' | 'body-recovery' | 'watch-reports' | 'connect-data' | 'settings'

export interface NavItemSpec {
  key: ViewKey
  label: string
  lede: string
  icon: LucideIcon
  group?: NavGroupKey
  hasAnalyticsFilters?: boolean
}

export interface NavGroupSpec {
  key: NavGroupKey
  label: string
  icon: LucideIcon
  items: NavItemSpec[]
}

export const TOP_NAV_ITEMS: NavItemSpec[] = [
  {
    key: 'overview',
    label: 'Overview',
    lede: 'Training, recovery and nutrition at a glance',
    icon: LayoutGrid,
    hasAnalyticsFilters: true,
  },
  {
    key: 'ai-coach',
    label: 'AI Coach',
    lede: 'Ask your personal coach to review your data and adjust upcoming workouts',
    icon: Sparkles,
  },
]

export const NAV_GROUPS: NavGroupSpec[] = [
  {
    key: 'training',
    label: 'Training',
    icon: Dumbbell,
    items: [
      {
        key: 'sessions',
        label: 'Sessions & History',
        lede: 'Every logged workout — click any session to inspect sets, reps and heart rate',
        icon: ListChecks,
        group: 'training',
        hasAnalyticsFilters: true,
      },
      {
        key: 'volume',
        label: 'Volume & Splits',
        lede: 'How much work you lifted, and where it landed',
        icon: ChartColumn,
        group: 'training',
        hasAnalyticsFilters: true,
      },
      {
        key: 'plan',
        label: 'Plan & Routines',
        lede: 'Weekly schedule, rotation loop and saved routines',
        icon: CalendarDays,
        group: 'training',
      },
      {
        key: 'exercises',
        label: 'Exercises & 1RM',
        lede: 'Every trained lift with Epley estimated 1RM progression',
        icon: Dumbbell,
        group: 'training',
      },
      {
        key: 'muscle-targets',
        label: 'Muscle Targets',
        lede: 'Weekly effective working sets per muscle against your target bands',
        icon: Target,
        group: 'training',
        hasAnalyticsFilters: true,
      },
    ],
  },
  {
    key: 'body-recovery',
    label: 'Body & Recovery',
    icon: HeartPulse,
    items: [
      {
        key: 'recovery',
        label: 'Recovery & Load',
        lede: 'Readiness, muscle fatigue and acute-to-chronic load balance',
        icon: Activity,
        group: 'body-recovery',
        hasAnalyticsFilters: true,
      },
      {
        key: 'body',
        label: 'Body & Measurements',
        lede: 'Bodyweight trend, goal tracking and tape measurements',
        icon: Scale,
        group: 'body-recovery',
      },
      {
        key: 'nutrition',
        label: 'Nutrition & Macros',
        lede: 'Daily calories and macros against your goals',
        icon: Utensils,
        group: 'body-recovery',
        hasAnalyticsFilters: true,
      },
    ],
  },
  {
    key: 'watch-reports',
    label: 'Watch & Reports',
    icon: Watch,
    items: [
      {
        key: 'stats',
        label: 'Consistency & Stats',
        lede: '53-week consistency heatmap, weekly volume and top lifts',
        icon: BarChart3,
        group: 'watch-reports',
      },
      {
        key: 'report',
        label: 'Training Report',
        lede: 'Printable period comparison against the previous identical window',
        icon: FileText,
        group: 'watch-reports',
      },
      {
        key: 'reps',
        label: 'Rep Counter',
        lede: 'Apple Watch live rep counting accuracy vs confirmed sets',
        icon: Gauge,
        group: 'watch-reports',
      },
      {
        key: 'motion',
        label: 'Motion Data',
        lede: '50 Hz Apple Watch sensor quality, gaps, capture windows and traces',
        icon: Cpu,
        group: 'watch-reports',
      },
    ],
  },
  {
    key: 'connect-data',
    label: 'Connect & Data',
    icon: Link2,
    items: [
      {
        key: 'sync-data',
        label: 'Sync & Backup',
        lede: 'Pair phones, inspect version history, restore backups and export data',
        icon: HardDrive,
        group: 'connect-data',
      },
      {
        key: 'webhooks',
        label: 'Webhooks',
        lede: 'Signed JSON webhooks triggered when your phone syncs',
        icon: Webhook,
        group: 'connect-data',
      },
      {
        key: 'mcp',
        label: 'MCP Server',
        lede: 'Connect Claude Desktop or Claude Code to your local workout database',
        icon: Server,
        group: 'connect-data',
      },
    ],
  },
  {
    key: 'settings',
    label: 'Settings',
    icon: Settings,
    items: [
      {
        key: 'settings-general',
        label: 'General & Language',
        lede: 'Interface language, appearance and data source',
        icon: SlidersHorizontal,
        group: 'settings',
      },
      {
        key: 'settings-ai',
        label: 'AI Coach & API',
        lede: 'Configure your OpenAI-compatible AI provider for Web Coach and iPhone AI',
        icon: Bot,
        group: 'settings',
      },
      {
        key: 'settings-backup',
        label: 'Backup & Signing',
        lede: 'Automatic iCloud/folder backup and 7-day Apple ID signing status',
        icon: HardDrive,
        group: 'settings',
      },
    ],
  },
]

export const ALL_NAV_ITEMS: NavItemSpec[] = [
  ...TOP_NAV_ITEMS,
  ...NAV_GROUPS.flatMap((g) => g.items),
]

export const VIEW_MAP: Record<ViewKey, NavItemSpec> = Object.fromEntries(
  ALL_NAV_ITEMS.map((item) => [item.key, item]),
) as Record<ViewKey, NavItemSpec>

export interface RouteState {
  view: ViewKey
  detailId: string | null
}

export function parseHashRoute(hash: string): RouteState {
  const clean = hash.replace(/^#\/?/, '').trim()
  if (!clean) return { view: 'overview', detailId: null }
  const [seg, ...rest] = clean.split('/')
  const detail = rest.length ? decodeURIComponent(rest.join('/')) : null
  if (seg in VIEW_MAP) {
    return { view: seg as ViewKey, detailId: detail }
  }
  return { view: 'overview', detailId: null }
}

export function formatHashRoute(view: ViewKey, detailId?: string | null): string {
  if (detailId) return `#/${view}/${encodeURIComponent(detailId)}`
  return `#/${view}`
}
