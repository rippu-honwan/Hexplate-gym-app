// Runtime bilingual i18n context. All Traditional Chinese UI strings live exclusively in
// `server/hexserver/i18n.py` and are delivered via `/analytics/api/bootstrap` and
// `/analytics/api/settings/lang`, keeping zero CJK literals in `dashboard/src/` and `dashboard/dist/`.
import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'

export type LangCode = 'en' | 'zh'

export interface LangOption {
  code: LangCode
  label: string
}

const DEFAULT_LANGUAGES: LangOption[] = [
  { code: 'en', label: 'English' },
  { code: 'zh', label: 'Traditional Chinese' },
]

const STORAGE_LANG = 'hexplate-lang'
const STORAGE_STRINGS = 'hexplate-zh-strings'

interface I18nValue {
  lang: LangCode
  isZh: boolean
  hasZhStrings: boolean
  languages: LangOption[]
  t: (key: string, vars?: Record<string, string | number>) => string
  applyServerLocale: (lang: LangCode, strings: Record<string, string>, languages?: LangOption[]) => void
  setLocalLang: (lang: LangCode, strings?: Record<string, string>) => void
}

const I18nContext = createContext<I18nValue>({
  lang: 'en',
  isZh: false,
  hasZhStrings: false,
  languages: DEFAULT_LANGUAGES,
  t: (key, vars) => formatTemplate(key, vars),
  applyServerLocale: () => {},
  setLocalLang: () => {},
})

function formatTemplate(template: string, vars?: Record<string, string | number>): string {
  if (!vars) return template
  return template.replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name) =>
    Object.prototype.hasOwnProperty.call(vars, name) ? String(vars[name]) : match,
  )
}

function readCachedStrings(): Record<string, string> {
  try {
    const raw = localStorage.getItem(STORAGE_STRINGS)
    if (!raw) return {}
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' ? (parsed as Record<string, string>) : {}
  } catch {
    return {}
  }
}

export function I18nProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<LangCode>(() => (localStorage.getItem(STORAGE_LANG) === 'zh' ? 'zh' : 'en'))
  const [strings, setStrings] = useState<Record<string, string>>(() => readCachedStrings())
  const [languages, setLanguages] = useState<LangOption[]>(DEFAULT_LANGUAGES)

  useEffect(() => {
    document.documentElement.lang = lang === 'zh' ? 'zh-Hant' : 'en'
  }, [lang])

  const applyServerLocale = useCallback((nextLang: LangCode, nextStrings: Record<string, string>, nextLangs?: LangOption[]) => {
    setLangState(nextLang)
    try {
      localStorage.setItem(STORAGE_LANG, nextLang)
    } catch {
      // Ignore storage quota / privacy mode errors.
    }
    if (nextLangs && nextLangs.length) {
      setLanguages(nextLangs)
    }
    if (nextLang === 'zh' && Object.keys(nextStrings).length > 0) {
      setStrings(nextStrings)
      try {
        localStorage.setItem(STORAGE_STRINGS, JSON.stringify(nextStrings))
      } catch {
        // Ignore storage quota errors.
      }
    }
  }, [])

  const setLocalLang = useCallback((nextLang: LangCode, nextStrings?: Record<string, string>) => {
    setLangState(nextLang)
    try {
      localStorage.setItem(STORAGE_LANG, nextLang)
    } catch {
      // Ignore storage errors.
    }
    if (nextStrings && Object.keys(nextStrings).length > 0) {
      setStrings(nextStrings)
      try {
        localStorage.setItem(STORAGE_STRINGS, JSON.stringify(nextStrings))
      } catch {
        // Ignore storage errors.
      }
    }
  }, [])

  const t = useCallback(
    (key: string, vars?: Record<string, string | number>) => {
      const base = lang === 'zh' ? strings[key] ?? key : key
      return formatTemplate(base, vars)
    },
    [lang, strings],
  )

  const hasZhStrings = useMemo(() => Object.keys(strings).length > 0, [strings])

  const value = useMemo<I18nValue>(
    () => ({ lang, isZh: lang === 'zh', hasZhStrings, languages, t, applyServerLocale, setLocalLang }),
    [lang, hasZhStrings, languages, t, applyServerLocale, setLocalLang],
  )

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>
}

export function useI18n(): I18nValue {
  return useContext(I18nContext)
}
