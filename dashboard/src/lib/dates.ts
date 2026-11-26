// ISO-day helpers in UTC, so a day string never shifts with the viewer's time zone.

export type Granularity = 'daily' | 'weekly' | 'monthly'
export type DateLang = 'en' | 'zh'

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']

const ZH_SHORT = new Intl.DateTimeFormat('zh-Hant', { month: 'short', day: 'numeric', timeZone: 'UTC' })
const ZH_MONTH = new Intl.DateTimeFormat('zh-Hant', { month: 'short', timeZone: 'UTC' })
const ZH_WEEKDAY = new Intl.DateTimeFormat('zh-Hant', { month: 'short', day: 'numeric', weekday: 'short', timeZone: 'UTC' })
const ZH_WEEKDAY_SHORT = new Intl.DateTimeFormat('zh-Hant', { weekday: 'short', timeZone: 'UTC' })

const utc = (iso: string) => new Date(iso + 'T00:00:00Z')
const iso = (t: Date) => t.toISOString().slice(0, 10)

export function addDays(d: string, n: number): string {
  const t = utc(d)
  t.setUTCDate(t.getUTCDate() + n)
  return iso(t)
}

export function daysBetween(a: string, b: string): number {
  return Math.round((utc(b).getTime() - utc(a).getTime()) / 86_400_000)
}

/** The bucket a day falls in: itself, its Monday, or its month's first day. */
export function bucketOf(d: string, g: Granularity): string {
  if (g === 'daily') return d
  if (g === 'monthly') return d.slice(0, 8) + '01'
  return addDays(d, -((utc(d).getUTCDay() + 6) % 7))
}

export function nextBucket(b: string, g: Granularity): string {
  if (g === 'daily') return addDays(b, 1)
  if (g === 'weekly') return addDays(b, 7)
  const t = utc(b)
  t.setUTCMonth(t.getUTCMonth() + 1)
  return iso(t)
}

export function weekdayOfIso(d: string): number {
  return utc(d).getUTCDay()
}

export function weekdayShort(weekdayIdx: number, lang: DateLang = 'en'): string {
  const idx = ((weekdayIdx % 7) + 7) % 7
  if (lang === 'zh') {
    // 2026-01-04 is a Sunday in UTC.
    return ZH_WEEKDAY_SHORT.format(new Date(Date.UTC(2026, 0, 4 + idx)))
  }
  return WEEKDAYS[idx]
}

export function shortDate(d: string, lang: DateLang = 'en'): string {
  const t = utc(d)
  if (lang === 'zh') return ZH_SHORT.format(t)
  return `${MONTHS[t.getUTCMonth()]} ${t.getUTCDate()}`
}

export function bucketLabel(b: string, g: Granularity, lang: DateLang = 'en'): string {
  if (g === 'monthly') {
    const t = utc(b)
    return lang === 'zh' ? ZH_MONTH.format(t) : MONTHS[t.getUTCMonth()]
  }
  return shortDate(b, lang)
}

export function weekdayDate(d: string, lang: DateLang = 'en'): string {
  const t = utc(d)
  if (lang === 'zh') return ZH_WEEKDAY.format(t)
  return `${WEEKDAYS[t.getUTCDay()]}, ${shortDate(d, 'en')}`
}
