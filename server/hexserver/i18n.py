"""The dashboard in English or Traditional Chinese (Settings › Language).

Words are the app's own where it has them: its zh-Hant Localizable.strings (muscles, body parts)
and openGym's zh-TW exercise names, shown the way the phone's profile asks (`enOnly`,
`enParens`). The dashboard's own phrases are in ZH below; anything missing stays English.
The language is set per request (dashboard.py's middleware), so pages just call t().
"""
import datetime as dt
import json
import re
from contextvars import ContextVar
from functools import cache
from pathlib import Path

LANG: ContextVar[str] = ContextVar("lang", default="en")
APP = Path(__file__).resolve().parents[2] / "app"


@cache
def app_strings() -> dict:
    p = APP / "Hexplate/zh-Hant.lproj/Localizable.strings"
    if not p.exists():
        return {}
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', p.read_text(encoding="utf-8"), re.M)
    un = lambda s: s.replace('\\"', '"').replace("\\\\", "\\")
    return {un(k): un(v) for k, v in pairs if "%" not in k}


@cache
def exercise_names() -> dict:
    p = APP / "HexplateCore/Sources/HexplateCore/Resources/exercise-names-zh-TW.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def zh() -> bool:
    return LANG.get() == "zh"


def t(s: str, /, **kw) -> str:
    out = (ZH.get(s) or app_strings().get(s) or s) if zh() else s
    return out.format(**kw) if kw else out


def tn(n, one: str, many: str, /, **kw) -> str:
    """A count with its noun: English picks one or many; Chinese has one form (the `many` key)."""
    return t(one if n == 1 and not zh() else many, n=n, **kw)


# The tape's names apart from ZH: "Chest" here is a girth, not the muscle.
MEASURE = {"Body fat": "體脂率", "Neck": "頸圍", "Chest": "胸圍", "Waist": "腰圍", "Abdomen": "腹圍", "Hips": "臀圍", "Left arm": "左上臂",
           "Right arm": "右上臂", "Left forearm": "左前臂", "Right forearm": "右前臂", "Left thigh": "左大腿", "Right thigh": "右大腿",
           "Left calf": "左小腿", "Right calf": "右小腿", "Left ankle": "左腳踝", "Right ankle": "右腳踝"}


def tm(s: str) -> str:
    return MEASURE.get(s) or t(s) if zh() else s


def exercise(ex_id, english: str, state) -> str:
    """An exercise's name as the phone shows it: Chinese, with the English in brackets unless the
    profile turned that off (ExerciseNames.style)."""
    if not zh() or (state or {}).get("enOnly", {}).get("zh-TW") is True:
        return english
    name = exercise_names().get(str(ex_id))
    if not name:
        return english
    brackets = (state or {}).get("enParens", {}).get("zh-TW") is not False
    return f"{name} ({english})" if brackets and name.lower() != english.lower() else name


WEEKDAY = "日一二三四五六"


def fd(d, kind="d") -> str:
    """A date (or datetime) in one of the dashboard's few styles."""
    if not zh():
        return d.strftime({"d": "%-d %b", "dy": "%-d %b %Y", "wd": "%a %-d %b", "wdy": "%a %-d %b %Y", "long": "%A, %-d %B",
                           "longy": "%A, %-d %B %Y", "month": "%B %Y", "a": "%a", "A": "%A", "dm": "%-d/%-m", "time": "%H:%M",
                           "dt": "%-d %b, %H:%M", "wdt": "%a %-d %b, %H:%M"}[kind])
    w = WEEKDAY[(d.weekday() + 1) % 7]
    md, ymd = f"{d.month}月{d.day}日", f"{d.year}年{d.month}月{d.day}日"
    hm = f"{d:%H:%M}" if isinstance(d, dt.datetime) else ""
    return {"d": md, "dy": ymd, "wd": f"{md}（週{w}）", "wdy": f"{ymd}（週{w}）", "long": f"{md} 星期{w}", "longy": f"{ymd} 星期{w}",
            "month": f"{d.year}年{d.month}月", "a": f"週{w}", "A": f"星期{w}", "dm": f"{d.month}/{d.day}", "time": hm,
            "dt": f"{md} {hm}", "wdt": f"{md}（週{w}）{hm}"}[kind]


ZH = {
    # Window
    "Training": "訓練", "Progress": "進度", "Summary": "總覽", "History": "歷史紀錄", "Plan": "計畫", "Exercises": "動作",
    "Body": "身體", "Stats": "數據統計", "Report": "報告", "Rep counter": "次數計算", "Sync & backup": "同步與備份",
    "Connect": "連接", "Settings": "設定", "Sections": "分頁",
    "Synced {when}": "已同步 {when}", "Not synced yet": "尚未同步",
    # Shared
    "Nothing here yet.": "暫時沒有內容。", "No data yet.": "尚無資料。", "One entry so far.": "目前只有一筆。",
    "No workouts yet. Pair your phone in Sync & backup and they appear here.": "尚無訓練。在「同步與備份」配對手機後就會顯示在這裡。",
    "Workout": "訓練", "Workouts": "訓練次數", "Volume": "總訓練量", "Working sets": "正式組", "Sets": "組數", "Reps": "次數",
    "Weight": "重量", "RIR": "RIR", "Heart rate": "心率", "Set": "組", "Date": "日期", "Exercise": "動作", "Time": "時間",
    "Duration": "時間", "Records": "紀錄", "Body weight": "體重", "Note": "備忘錄", "Today": "今天", "Rest": "休息",
    "this week": "本週", "{n} sets": "{n} 組", "{n} set": "{n} 組", "{n} min": "{n} 分鐘", "{h} h {m} min": "{h} 小時 {m} 分鐘",
    "{n} PR": "{n} 項紀錄", "PR": "紀錄", "+{n} more": "另外 {n} 個", "Goal {v}": "目標 {v}", "Less": "少", "More": "多",
    "rest": "休息", "Training days, last {n} weeks": "訓練日，最近 {n} 週",
    "{name}: {sets} sets, aim {lo}–{hi} ({word})": "{name}：{sets} 組，目標 {lo}–{hi}（{word}）",
    "under range": "低於範圍", "in range": "在範圍內", "over range": "高於範圍",
    "Print": "列印", "Download": "下載", "Restore": "還原", "Unpair": "解除配對", "Delete": "刪除", "Pause": "暫停", "Resume": "繼續",
    # Summary
    "This week": "本週", "Week of {d}": "{d} 起的一週", "of {n}": "/ {n}", "Weeks in a row": "連續週數",
    "with a workout": "每週都有訓練", "{n} freeze banked": "存有 {n} 次保護", "{n} freezes banked": "存有 {n} 次保護",
    "best {n}": "最佳 {n} 週", "4-week average {v}": "四週平均 {v}", "Weekly volume": "每週訓練量", "last {n} weeks": "最近 {n} 週",
    "This week {v} so far; the 4 weeks before averaged {a}.": "本週至今 {v}；之前四週平均 {a}。",
    "Muscle sets": "肌肉組數", "{n} of {m} muscles in their weekly range. The shaded band is the range.": "{m} 個肌群中有 {n} 個在每週範圍內。淺色帶是目標範圍。",
    "Recent workouts": "最近訓練", "Latest records": "最新紀錄", "No records yet.": "尚無紀錄。", "Latest {d}": "最新 {d}",
    "No weigh-ins yet.": "尚無體重紀錄。",
    # History
    "{n} workout": "{n} 次訓練", "{n} workouts": "{n} 次訓練", " with “{q}”": "，含「{q}」", "Exercise or workout": "動作或訓練",
    "Search workouts": "搜尋訓練", "No workout matches.": "沒有符合的訓練。", "Not found": "找不到", "No workout with that id.": "找不到這次訓練。",
    "best {w} × {r} · e1RM {e}": "最佳 {w} × {r} · 預估 1RM {e}",
    "Warm-ups are dimmed, sets not ticked are struck through. Edit a workout on the phone.": "熱身組顏色較淡，未勾選的組有刪除線。請在手機上編輯訓練。",
    # Plan
    "No routines yet. Make one on the phone.": "尚無課表。請在手機上建立。", "{n} routine": "{n} 個課表", "{n} routines": "{n} 個課表",
    "rotation": "輪替", "weekly plan": "每週計畫", "{n} workouts a week": "每週 {n} 次訓練", "Week": "一週",
    "What each day of this week holds, as the phone plans it. Change the plan on the phone.": "這一週每天的安排，與手機相同。請在手機上修改計畫。",
    "Rotation": "輪替", "The loop the rotation works through, in order.": "輪替依序循環的課表。",
    "Sets × reps": "組數 × 次數", "{n} exercises · {s} sets": "{n} 個動作 · {s} 組",
    # Exercises
    "{n} trained, most recent first": "練過 {n} 個，最近的在前", "Find an exercise": "搜尋動作", "No exercise matches.": "沒有符合的動作。",
    "{n} session · last {d}": "{n} 次 · 上次 {d}", "{n} sessions · last {d}": "{n} 次 · 上次 {d}",
    "No working sets logged for this exercise.": "這個動作還沒有正式組紀錄。", "Best e1RM": "最佳預估 1RM", "Heaviest set": "最重一組",
    "Sessions": "訓練次數", "Last time": "上次", "since {d}": "自 {d}", "Estimated 1RM per session": "每次訓練的預估 1RM",
    "From {a} to {b} {u} over {n} sessions.": "{n} 次訓練由 {a} 到 {b} {u}。", "Best set": "最佳一組", "e1RM": "預估 1RM",
    "Estimated 1RM uses the Epley formula, weight × (1 + reps / 30), on ticked working sets.": "預估 1RM 以 Epley 公式計算：重量 ×（1 + 次數 / 30），只計已勾選的正式組。",
    # Body
    "No weigh-ins or measurements yet. Log them on the phone.": "尚無體重或身體圍度紀錄。請在手機上記錄。",
    "{n} weigh-in": "{n} 筆體重", "{n} weigh-ins": "{n} 筆體重", "{n} measurement": "{n} 筆圍度", "{n} measurements": "{n} 筆圍度",
    "Latest": "最新", "30 days": "30 天", "90 days": "90 天", "change": "變化", "Goal": "目標", "{v} to go": "還差 {v}",
    "3 months": "3 個月", "1 year": "1 年", "All": "全部", "{n} weigh-ins in this range.": "此範圍內有 {n} 筆體重。",
    " The dashed line is your goal.": "虛線是你的目標。", "Measurements": "身體圍度", "Measure": "項目", "Since first": "與第一筆相比",
    "Weigh-ins": "體重紀錄", "latest 20": "最近 20 筆", "No measurements yet.": "尚無身體圍度紀錄。",
    # Stats
    "4 weeks": "4 週", "{v} a week": "每週 {v}", "Time trained": "訓練時間", "h": "小時", "{v} a workout": "每次 {v}",
    "Consistency": "規律性", "last 12 months": "最近 12 個月",
    "{n} training days in the last year; darker days moved more weight.": "過去一年訓練了 {n} 天；顏色越深，當天訓練量越大。",
    "The busiest week, highlighted, was {d} with {v}.": "訓練量最大的一週是 {d}，共 {v}（已標示）。",
    "Muscle balance": "肌肉平衡", "average sets a week": "每週平均組數",
    "Working sets per muscle, averaged over the range, against each weekly range.": "每個肌群的正式組數（範圍內每週平均）與每週目標範圍對比。",
    "Most trained": "最常訓練", "by working sets": "依正式組數", "No sets in this range.": "此範圍內沒有訓練組。",
    "Week of {d}: {v}, {n} workouts": "{d} 起的一週：{v}，{n} 次訓練",
    # Report
    "Training report": "訓練報告", "7 days": "7 天", "{a} – {b} · {n} days, compared with the {n} days before": "{a} – {b} · {n} 天，與之前 {n} 天比較",
    "vs before": "相比之前", "{n} new": "{n} 項新紀錄", "No records in this range.": "此範圍內沒有新紀錄。",
    "Muscles worked": "訓練到的肌肉", "effective working sets": "有效正式組數", "Muscle": "肌肉", "No working sets.": "沒有正式組。",
    "Every workout": "每次訓練", "No workouts in this range.": "此範圍內沒有訓練。",
    "Made by Hexplate on {d}. The phone makes the same report as a PDF (Settings › Report).": "由 Hexplate 於 {d} 製作。手機也能製作同樣的 PDF 報告（設定 › 報告）。",
    # Rep counter
    "How well the watch counts your reps": "手錶計算次數有多準確", "Sets recorded": "已記錄組數", "{n} exercises": "{n} 個動作",
    "Confirmed": "已確認", "counts checked on the watch": "在手錶上確認過的次數", "Exact": "完全正確", "{a} of {b} counted right": "{b} 組中 {a} 組正確",
    "Mean error": "平均誤差", "reps": "次", "live count vs confirmed": "即時計數與確認後的差距", "By exercise": "依動作", "Checked": "已確認",
    "Error": "誤差", "No motion files yet.": "尚無動作檔。", "Latest sets": "最近的組", "When": "時間", "Live": "即時", "Final": "最終", "Off": "差距",
    "No sets yet.": "尚無訓練組。",
    "Live is the watch's own count; Final is the count after you corrected it on the watch. The full check against the phone's log is analysis/motion_check.py.":
        "「即時」是手錶自己的計數；「最終」是你在手錶上修正後的次數。與手機紀錄的完整比對請用 analysis/motion_check.py。",
    # Sync & backup
    "Pair phones, keep every version, download your data": "配對手機、保留每個版本、下載你的資料",
    "Sets (CSV)": "訓練組 (CSV)", "Download backup": "下載備份", "Pair a phone": "配對手機",
    "A code lets one phone sync with this Mac. It works once, for 5 minutes.": "配對碼讓一部手機與這部 Mac 同步，只能用一次，5 分鐘內有效。",
    "New pairing code": "新的配對碼", "Paired phones": "已配對的手機", "No phone paired yet.": "尚未配對手機。", "Phone {n}": "手機 {n}",
    "Paired {d}": "{d} 配對", "Versions": "版本", "latest 30": "最近 30 個", "Version": "版本", "Received": "收到時間", "Size": "大小",
    "Every copy the phone sends is kept. The backup is the openGym JSON the app imports; the CSV has one row per set, for a spreadsheet.":
        "手機傳來的每個版本都會保留。備份是 app 可匯入的 openGym JSON；CSV 每組一行，可用試算表開啟。",
    "Works once, for 5 minutes. On the phone: Settings › Server, address {a}, then this code.": "只能用一次，5 分鐘內有效。在手機：設定 › 伺服器，輸入地址 {a}，再輸入這個配對碼。",
    " If the phone cannot reach it, try {a}.": "如果手機連不上，可以試 {a}。",
    "Unpair this phone? It stops syncing until it is paired again.": "要解除這部手機的配對嗎？重新配對前它不會再同步。",
    "Make rev {rev} the current copy? The phone takes it on its next sync and merges in anything it changed since. No version is deleted.":
        "要把第 {rev} 版設為目前的資料嗎？手機下次同步時會取得它，並合併之後的變更。不會刪除任何版本。",
    # Connect
    "Send your training to other tools": "把訓練資料傳到其他工具", "Webhooks": "Webhook", "No webhooks yet.": "尚無 Webhook。",
    "A signed JSON message to Home Assistant, n8n, Node-RED or ntfy when you finish a workout, set a record or weigh in. Sent when the phone syncs, for what happened in the last seven days.":
        "完成訓練、創下紀錄或記錄體重時，傳送已簽署的 JSON 訊息到 Home Assistant、n8n、Node-RED 或 ntfy。手機同步時傳送，涵蓋最近七天發生的事。",
    "Add a webhook": "新增 Webhook", "Name (optional)": "名稱（選填）", "https://… (the URL your tool gave you)": "https://…（工具提供的網址）",
    "Name": "名稱", "URL": "網址", "Add webhook": "新增 Webhook", "Send test": "傳送測試", "Paused": "已暫停", "Not sent yet": "尚未傳送",
    "Delivered": "已送達", "Failed": "失敗", "Delete this webhook? Its URL and secret are forgotten.": "要刪除這個 Webhook 嗎？它的網址和密鑰會被清除。",
    "Not added.": "沒有新增。", "Webhook added.": "已新增 Webhook。", "Its signing secret, shown only now. Copy it into your tool:": "這是它的簽署密鑰，只會顯示這一次。請複製到你的工具：",
    "Test sent.": "測試已送出。", "Test failed.": "測試失敗。", "Workout finished": "完成訓練", "New personal record": "新個人紀錄", "Weigh-in logged": "記錄體重",
    "MCP server": "MCP 伺服器", "for AI assistants": "給 AI 助理使用",
    # Settings
    "Language, backup and signing": "語言、備份與簽署", "Language": "語言",
    "The dashboard's language. The phone keeps its own.": "這個網頁的語言。手機的語言另外設定。",
    "Apple ID signing": "Apple ID 驗證", "Refresh Apple ID signing": "更新 Apple ID 驗證",
    "Refreshing Apple ID signing…": "正在更新 Apple ID 驗證…", "Refreshing…": "更新中…",
    "This takes about a minute.": "大約需要一分鐘。", "Not refreshed from this server yet": "尚未透過此伺服器更新",
    "Last refreshed {d}": "上次更新 {d}", "Device": "裝置", "Valid until": "有效期限",
    "Expired {d}": "已於 {d} 過期", "{n} day left": "剩餘 {n} 天", "{n} days left": "剩餘 {n} 天",
    "Checking iPhone…": "正在檢查 iPhone…", "Building and renewing Apple ID signing…": "正在編譯並更新 Apple ID 驗證…",
    "Installing on iPhone…": "正在安裝到 iPhone…",
    "Free Apple ID profiles expire every 7 days, which stops Hexplate from opening. Keep your iPhone unlocked on USB or the same Wi-Fi, then click to re-sign with Xcode and reinstall without losing data.":
        "免費 Apple ID 驗證每 7 天過期，過期後將無法開啟 Hexplate。請保持 iPhone 解鎖並連接 USB 或同一 Wi-Fi，按下按鈕即可透過 Xcode 重新簽署並安裝（不會遺失資料）。",
    "No paired iPhone found. Connect your iPhone to this Mac by USB or Wi-Fi and unlock it.":
        "找不到已配對的 iPhone。請將 iPhone 以 USB 或 Wi-Fi 連接到此 Mac 並解鎖。",
    "Xcode could not renew signing. Open Xcode › Settings › Accounts and sign in with your Apple ID.":
        "Xcode 無法更新簽署。請開啟 Xcode › 設定 › 帳號並登入 Apple ID。",
    "iPhone is locked. Unlock your iPhone and try again.": "iPhone 已鎖定，請解鎖後再試。",
    "Could not reach your iPhone. Keep it unlocked on the same Wi-Fi or connect it by USB.":
        "無法連線到 iPhone。請保持手機解鎖並連上同一 Wi-Fi，或改用 USB 連接。",
    "Enable Developer Mode on your iPhone (Settings › Privacy & Security › Developer Mode).":
        "請在 iPhone 開啟開發者模式（設定 › 隱私權與安全性 › 開發者模式）。",
    "Free Apple ID limit (3 sideloaded apps) reached on this iPhone. Remove another sideloaded app and try again.":
        "此 iPhone 已達免費 Apple ID 上限（最多 3 個自簽 App），請先移除其他自簽 App 再試。",
    "app/Local.xcconfig is missing. Add DEVELOPMENT_TEAM = <TEAM_ID> first.":
        "找不到 app/Local.xcconfig，請先設定 DEVELOPMENT_TEAM。",
    "Run on your Mac (requires macOS and Xcode)": "請在 Mac 上更新（需要 macOS 與 Xcode）",
    "This server runs on Linux without Xcode. Refresh signing from your Mac with Hexplate Sign.app (or python -m hexserver sign) — the new expiry date syncs back here automatically.":
        "此伺服器執行於 Linux（沒有 Xcode）。請在 Mac 上使用桌面 Hexplate Sign.app（或 python -m hexserver sign）更新驗證，新的有效期限會自動同步回來顯示。",
    "Free Apple ID profiles expire every 7 days, which stops Hexplate from opening. Re-signing requires Xcode on macOS with your iPhone unlocked on USB or the same Wi-Fi.":
        "免費 Apple ID 驗證每 7 天過期，過期後將無法開啟 Hexplate。重新簽署需要透過 Mac 上的 Xcode，並保持 iPhone 解鎖且連接 USB 或同一 Wi-Fi。",
    "Apple ID signing requires macOS with Xcode. Run signing refresh on your Mac.":
        "Apple ID 驗證需要 macOS 與 Xcode，請在你的 Mac 上執行更新。",
    "Backup": "備份", "Backup is on": "備份已開啟", "Backup is off": "備份已關閉", "Turn on": "開啟", "Turn off": "關閉", "Back up now": "立即備份", "Status": "狀態",
    "Last backup {d}": "上次備份 {d}", "Not backed up yet": "尚未備份", "Folder": "資料夾", "Daily copies": "每日副本",
    "{n} of the latest {k} days": "保留最近 {k} 天中的 {n} 份", "Watch recordings": "手錶紀錄", "{n} files": "{n} 個檔案",
    "Backed up: {n} new Watch recordings and the database.": "已備份：{n} 個新的手錶紀錄和資料庫。", "Backup failed.": "備份失敗。",
    "The Watch hands each set's recording to the phone, then deletes its own. The phone sends it to this Mac, which saves it and copies it to the backup; only then does the phone delete its copy. Your training log stays on the phone and is kept here in every version, copied to the backup a minute after each sync.":
        "手錶把每組的紀錄交給手機後，就刪除自己的那份。手機再傳到這部 Mac，Mac 儲存後複製到備份；之後手機才刪除自己的那份。訓練紀錄會留在手機上，這裡會保存每個版本，並在每次同步一分鐘後複製到備份。",
    "Backup is off: the phone deletes the Watch's recordings as soon as this Mac has them.": "備份已關閉：這部 Mac 收到手錶紀錄後，手機就會刪除它的那份。",
    "iCloud Drive": "iCloud 雲碟",
    "iCloud Drive is off on this Mac (System Settings › Apple Account › iCloud › iCloud Drive).": "這部 Mac 沒有開啟 iCloud 雲碟（系統設定 › Apple 帳號 › iCloud › iCloud 雲碟）。",
    "No permission to write to the backup folder. Give the server's Python Full Disk Access, or set HEXPLATE_BACKUP to another folder.":
        "沒有權限寫入備份資料夾。請給伺服器的 Python「完整磁碟取用權限」，或把 HEXPLATE_BACKUP 設為其他資料夾。",
    "A motion file came out the wrong size in the backup.": "備份中的動作檔大小不符。",
    # Motion data
    "Motion data": "動作數據", "What the watch recorded in each workout": "每次訓練手錶記錄到的動作",
    "{n} set files belong to no saved workout.": "有 {n} 個組別檔案不屬於任何已儲存的訓練。",
    "No motion files for this workout.": "這次訓練沒有動作檔。", "Clean": "無問題", "no quality flag": "沒有品質標記",
    "Recorded": "記錄時長", "of motion at 50 Hz": "50 Hz 動作數據", "Rows": "資料列", "samples": "個樣本",
    "1. What there is": "1. 有什麼數據", "Flags": "標記", "Flag": "標記", "Every set is clean.": "每組都沒有問題。",
    "2. Sampling: 50 Hz, no gaps?": "2. 取樣：50 Hz，有沒有斷層？", "Sample rate (Hz)": "取樣率（Hz）", "Sample rate": "取樣率",
    "50 Hz target": "目標 50 Hz", "Largest gap (s, log scale)": "最大斷層（秒，對數刻度）", "Largest gap": "最大斷層",
    "0.1 s: flagged above": "0.1 秒：超過即標記",
    "Each dot is a set; the x-axis labels are exercise.set as numbered in the table above.": "每個點是一組；橫軸標籤是「動作.組」，編號同上表。",
    "3. Does the window hold the whole set?": "3. 記錄範圍有沒有包住整組？", "Head: first second": "開頭：第一秒", "Head": "開頭",
    "Tail: last second": "結尾：最後一秒", "Tail": "結尾", "0.6: busy": "0.6：活動多",
    "How busy the first and last second is, against the set's 90th-percentile activity. A busy start with no rep in the first 2 s is the walk to the machine; a busy end would be a set cut before it finished.":
        "第一秒和最後一秒的活動量，相對該組第 90 百分位的活動量。開頭活動多但頭 2 秒沒有次數，是走去器械的動作；結尾活動多，代表該組未完就被切斷。",
    "magnitude": "合成量", "rep counted live": "即時計到的次數", "4. One set per exercise": "4. 每個動作一組",
    "{name}: {reps} reps logged, {auto} counted live": "{name}：記錄 {reps} 次，即時計到 {auto} 次",
    "User acceleration (g) and its smoothed magnitude; ticks: reps the watch counted live.": "使用者加速度（g）及其平滑合成量；虛線：手錶即時計到的次數。",
    "5. The watch's live count against the logged reps": "5. 手錶即時計數對比記錄次數", "Bias": "偏差",
    "No clean sets with a live count.": "沒有附即時計數的無問題組別。", "on the line: exact": "落在線上：完全準確",
    "logged reps": "記錄次數", "live count": "即時計數", "Live count vs logged": "即時計數對比記錄",
    "Clean sets only. Error is the mean miss in reps; bias above zero means the watch counts too many.": "只計無問題的組別。誤差是平均差了多少次；偏差大於零代表手錶計多了。",
    "6. Findings": "6. 結論", "{a} of {b} sets are clean.": "{b} 組中有 {a} 組沒有問題。",
    "Most common flag: {f} ({n} sets).": "最常見的標記：{f}（{n} 組）。",
    "Live count: exact on {x} of {n} clean sets, mean error {e} reps, bias {b:+.2f}.": "即時計數：{n} 組無問題組別中 {x} 組完全準確，平均誤差 {e} 次，偏差 {b:+.2f}。",
    "Hardest to count: {ex} (mean error {e}).": "最難計的動作：{ex}（平均誤差 {e}）。",
    "rate {v} Hz": "取樣率 {v} Hz", "gap {v} s": "斷層 {v} 秒", "saturated": "加速度爆表", "no movement": "沒有動作",
    "starts {v} s late": "遲了 {v} 秒開始", "{v} s per rep": "每次 {v} 秒", "clipped start": "開頭被切", "clipped end": "結尾被切", "empty": "空檔案",
}

LANG_OPTIONS = [
    {"code": "en", "label": "English"},
    {"code": "zh", "label": "繁體中文"},
]

# Separate React web dashboard localization table (kept apart from `ZH` so SSR HTML stays byte-identical).
DASHBOARD_ZH = {
    # Navigation groups & items
    "Overview": "總覽",
    "AI Coach": "AI 健身教練",
    "Body & Recovery": "身體與恢復",
    "Watch & Reports": "手錶與報告",
    "Connect & Data": "連線與資料",
    "Sessions & History": "訓練紀錄與歷史",
    "Volume & Splits": "訓練量與分化",
    "Plan & Routines": "課表與計畫",
    "Exercises & 1RM": "動作與預估 1RM",
    "Muscle Targets": "肌群目標組數",
    "Recovery & Load": "恢復與訓練負荷",
    "Body & Measurements": "體重與身體圍度",
    "Nutrition & Macros": "營養與巨量營養素",
    "Consistency & Stats": "規律性與統計",
    "Training Report": "訓練報告",
    "Rep Counter": "手錶次數計算",
    "Motion Data": "動作感測數據",
    "Sync & Backup": "同步與備份",
    "MCP Server": "MCP 伺服器",
    "General & Language": "一般與語言",
    "AI Coach & API": "AI 教練與 API",
    "Backup & Signing": "備份與簽署",
    "Dashboard views": "儀表板分頁",
    "Navigation": "導覽選單",
    "Open navigation": "開啟導覽選單",
    "Toggle sidebar": "收合或展開側邊欄",
    "Switch to light appearance": "切換為淺色外觀",
    "Switch to dark appearance": "切換為深色外觀",
    # View ledes
    "Training, recovery and nutrition at a glance": "一覽訓練、恢復與營養狀態",
    "Ask your personal coach to review your data and adjust upcoming workouts": "讓你的私人 AI 教練檢視即時資料並安全調整未來課表",
    "Every logged workout — click any session to inspect sets, reps and heart rate": "所有已記錄的訓練——點擊任一場次檢視每組重量、次數與心率",
    "How much work you lifted, and where it landed": "總訓練量趨勢與各分化占比",
    "Weekly schedule, rotation loop and saved routines": "每週計畫、輪替循環與已儲存課表",
    "Every trained lift with Epley estimated 1RM progression": "所有練過的動作與預估 1RM 進步曲線",
    "Weekly effective working sets per muscle against your target bands": "各肌群每週有效正式組數與目標區間對比",
    "Readiness, muscle fatigue and acute-to-chronic load balance": "準備度、肌肉疲勞與急慢性負荷比",
    "Bodyweight trend, goal tracking and tape measurements": "體重趨勢、目標進度與身體圍度",
    "Daily calories and macros against your goals": "每日熱量與蛋白質、碳水、脂肪目標對比",
    "53-week consistency heatmap, weekly volume and top lifts": "過去 53 週訓練規律熱圖、每週訓練量與最常訓練動作",
    "Printable period comparison against the previous identical window": "可列印的區間比較訓練報告",
    "Apple Watch live rep counting accuracy vs confirmed sets": "Apple Watch 即時動作計次準確度對比確認次數",
    "50 Hz Apple Watch sensor quality, gaps, capture windows and traces": "Apple Watch 50 Hz 感測品質、斷層、區間與三軸加速度軌跡",
    "Pair phones, inspect version history, restore backups and export data": "配對手機、檢視版本紀錄、還原備份與匯出資料",
    "Signed JSON webhooks triggered when your phone syncs": "手機同步時觸發的已簽署 JSON Webhook",
    "Connect Claude Desktop or Claude Code to your local workout database": "將 Claude Desktop 或 Claude Code 連接到本機訓練資料庫",
    "Interface language, appearance and data source": "介面語言、外觀主題與資料來源",
    "Configure your OpenAI-compatible AI provider for Web Coach and iPhone AI": "設定相容 OpenAI 格式的 AI 服務，同時供應網頁 AI 教練與 iPhone AI 功能",
    "Automatic iCloud/folder backup and 7-day Apple ID signing status": "自動備份設定與免費 Apple ID 7 天簽署狀態",
    # Global filters & status badges
    "Date range": "日期範圍",
    "Training split filter": "訓練分化篩選",
    "All splits": "全部分化",
    "Push": "推（Push）",
    "Pull": "拉（Pull）",
    "Legs": "腿（Legs）",
    "Upper": "上肢（Upper）",
    "Lower": "下肢（Lower）",
    "Other": "其他",
    "Daily": "每日",
    "Weekly": "每週",
    "Monthly": "每月",
    "Granularity": "時間粒度",
    "Local": "本機即時",
    "Sample data": "範例資料",
    "Mock data": "範例資料",
    "Sample mode active — write actions are disabled. Switch back to Local data in Settings to edit.": "目前為範例資料模式，所有寫入與修改操作已停用。請在設定切換回本機資料以進行操作。",
    "Standalone preview — connect to the Hexplate server for live data and write actions.": "目前為獨立預覽模式，請透過 Hexplate 伺服器開啟以存取即時資料與寫入功能。",
    "Switch to Sample data": "預覽範例資料",
    "Switch to Local data": "切換回本機資料",
    "No synced workouts yet": "尚未同步任何訓練紀錄",
    "Pair your iPhone in Sync & Backup to see your real data, or preview with sample data.": "前往「同步與備份」配對 iPhone 以檢視你的真實資料，或先以範例資料預覽版面。",
    # Analytics KPIs & charts
    "Training volume": "總訓練量",
    "Work sets": "正式組數",
    "Avg readiness": "平均準備度",
    "Volume per session": "單次訓練量",
    "Personal records": "個人紀錄（PR）",
    "Avg sleep": "平均睡眠",
    "Avg HRV": "平均心率變異度（HRV）",
    "Acute : chronic load": "急慢性負荷比",
    "Avg calories": "平均熱量",
    "Avg protein": "平均蛋白質",
    "Protein goal met": "蛋白質達標率",
    "Meals per day": "每日餐數",
    "Avg duration": "平均時長",
    "Sets per session": "單次組數",
    "vs previous {range}": "對比前 {range}",
    "Total {unit} lifted {scope}": "總舉起重量（{unit}），{scope}",
    "across all splits": "涵蓋所有分化",
    "in {split} sessions only": "僅計算 {split} 訓練",
    "{split} sessions only": "僅顯示 {split} 訓練",
    "Weekly sets vs target": "每週肌群組數與目標",
    "Average working sets per week for each muscle {scope}": "各肌群每週平均有效正式組數（{scope}）",
    "Target range": "目標範圍",
    "In range": "達標範圍內",
    "Outside range": "超出或低於範圍",
    "Below target": "低於目標",
    "Above target": "高於目標",
    "Sets / week": "每週組數",
    "Target": "目標",
    "Muscle fatigue": "肌肉疲勞度",
    "Right now, highest first": "目前疲勞狀態，由高至低排列",
    "Recovered": "已恢復",
    "Recovered in about {h} h": "約 {h} 小時後恢復",
    "Macros": "巨量營養素",
    "Daily average against your goals. A day is on goal within 10% of the calorie target.": "每日平均值對比目標（熱量在目標 10% 內視為達標）。",
    "Share of calories": "熱量來源比例",
    "Calories": "熱量",
    "Protein": "蛋白質",
    "Carbs": "碳水化合物",
    "Fat": "脂肪",
    "Protein per kg": "每公斤蛋白質",
    "Kcal vs goal": "熱量差額",
    "Days on goal": "達標天數比例",
    "Recent sessions": "最近訓練",
    "All sessions": "所有訓練",
    "Show all sessions": "查看全部訓練",
    "Volume by split": "各分化訓練量",
    "Share of the period's work": "區間內各分化占比",
    "No sessions in this period.": "此區間內沒有訓練紀錄。",
    "Readiness": "準備度",
    "Average morning score; the dashed line at 70 means ready to train. Not affected by the split filter.": "每日早晨準備度分數；70 分虛線代表適合訓練（不受分化篩選影響）。",
    "Readiness metrics come from Apple Health on your iPhone and are not stored in the server database.": "準備度指標（睡眠、HRV、靜息心率）僅存於 iPhone Apple Health，伺服器端不儲存此項資料。",
    "Training load balance": "訓練負荷平衡",
    "7-day load against the 28-day weekly average. The shaded zone, 0.8 to 1.3, is where most progress happens safely.": "7 天急性負荷對比 28 天每週平均慢性負荷。0.8 至 1.3 陰影區間為最安全有效的進步帶。",
    "Load ratio": "負荷比",
    "Daily average; the dashed line is your {kcal} kcal goal. Not affected by the split filter.": "每日平均值；虛線為 {kcal} kcal 目標（不受分化篩選影響）。",
    "Daily average; the dashed line is your {g} g goal.": "每日平均值；虛線為 {g} g 目標。",
    "No meals logged in this period.": "此區間內尚未記錄飲食。",
    # Sessions table
    "Search routine or lift": "搜尋課表或動作",
    "All statuses": "全部狀態",
    "PR Hit": "創下 PR",
    "Completed": "已完成",
    "Deload": "減量週",
    "Recovery": "恢復訓練",
    "Routine": "課表",
    "PRs": "PR 數",
    "Newest first": "最新優先",
    "Oldest first": "最舊優先",
    "Most volume": "訓練量最高",
    "Most sets": "組數最多",
    "Longest": "時長最長",
    "Most PRs": "PR 最多",
    "{n} sessions": "{n} 次訓練",
    "{shown} of {total} sessions": "顯示 {total} 次中的 {shown} 次",
    "No sessions match. Clear the search or pick another status.": "找不到符合的訓練，請清除搜尋或改選其他狀態。",
    "Back to Sessions": "返回訓練紀錄",
    "Back to Exercises": "返回動作列表",
    "Back to Motion Data": "返回動作數據",
    "Workout detail": "訓練詳情",
    "Warm-up": "熱身組",
    "Left": "左",
    "Right": "右",
    "Skipped": "未完成",
    "Inspect Motion Data": "檢視動作感測數據",
    # Muscles
    "Chest": "胸肌",
    "Upper back": "上背",
    "Shoulders": "肩膀",
    "Biceps": "二頭肌",
    "Triceps": "三頭肌",
    "Quads": "股四頭肌",
    "Hamstrings": "腿後側",
    "Glutes": "臀部",
    "Calves": "小腿",
    "Abs": "腹肌",
    # Plan, Exercises, Body, Stats, Report
    "Weekly schedule": "每週行程",
    "AI adjusted": "AI 已調整",
    "Routines": "課表清單",
    "Exercises": "動作",
    "Current queue": "目前輪替佇列",
    "Completed in cycle": "本輪已完成",
    "Remaining in cycle": "本輪待完成",
    "Estimated 1RM": "預估 1RM",
    "Heaviest set": "最重一組",
    "Best set": "最佳組",
    "All time": "全部時間",
    "4 weeks": "4 週",
    "3 months": "3 個月",
    "1 year": "1 年",
    "7 days": "7 天",
    "Print / Save PDF": "列印／儲存 PDF",
    "Previous period": "前一區間",
    "No body measurements recorded yet.": "尚未記錄身體圍度。",
    "Current weight": "最新體重",
    "30d change": "30 天變化",
    "90d change": "90 天變化",
    "Goal weight": "目標體重",
    "Bodyweight trend": "體重趨勢",
    "Active days": "訓練天數",
    "Current streak": "目前連續週數",
    "Best streak": "最佳連續週數",
    "{n} wk": "{n} 週",
    # Watch Reps & Motion
    "Sets recorded": "已記錄組數",
    "Confirmed": "已確認",
    "Exact": "完全準確",
    "Mean error": "平均誤差",
    "Unlinked files": "未關聯檔案",
    "View Diagnostics": "檢視診斷",
    "No motion data recorded yet.": "尚無 Apple Watch 動作數據。",
    "Clean sets": "無問題組數",
    "Total duration": "總記錄時長",
    "Total samples": "總樣本數",
    "Overview & Quality Flags": "1. 數據總覽與品質標記",
    "Sampling Rate & Gaps": "2. 取樣率（50 Hz）與最大斷層",
    "Capture Window (Head & Tail)": "3. 記錄區間（開頭與結尾活動度）",
    "3-Axis Acceleration Traces": "4. 動作三軸加速度與合成量軌跡",
    "Live Count vs Logged Reps": "5. 手錶即時計數對比記錄次數",
    "Diagnostic Findings": "6. 診斷結論",
    # Sync & Backup, Webhooks, MCP
    "Generate Pairing Code": "產生配對碼",
    "Expires in 5 minutes · single use": "5 分鐘內有效 · 僅可使用一次",
    "Server address": "伺服器位址",
    "Wi-Fi fallback": "區域網路備援位址",
    "Copy": "複製",
    "Copied": "已複製",
    "Download JSON Backup": "下載 JSON 備份",
    "Download Sets CSV": "下載訓練組 CSV",
    "Rev": "版本",
    "Confirm Unpair": "確認解除配對",
    "Confirm Restore": "確認還原",
    "Cancel": "取消",
    "Version restored.": "已還原該版本。",
    "Phone unpaired.": "已解除手機配對。",
    "Add Webhook": "新增 Webhook",
    "Signing secret (shown once)": "簽署密鑰（僅顯示一次）",
    "Copy this secret now — it cannot be shown again.": "請立即複製此密鑰，之後將無法再次查看。",
    "Events": "訂閱事件",
    "Send Test": "傳送測試",
    "Active": "啟用中",
    "Webhook deleted.": "已刪除 Webhook。",
    "Available MCP Tools": "可用 MCP 工具",
    "Read-only SQLite access for external AI assistants": "提供外部 AI 助理唯讀存取本機訓練資料庫",
    "Database status": "資料庫狀態",
    "Connected (read-only)": "已就緒（唯讀）",
    "Waiting for first phone sync": "等待首次手機同步",
    "Claude Desktop Config": "Claude Desktop 設定",
    "Claude Code (.mcp.json)": "Claude Code 設定（.mcp.json）",
    # Settings: General, AI, Backup & Signing
    "Interface Language": "介面語言",
    "Choose English or Traditional Chinese for the web dashboard. Synced with your server setting.": "選擇網頁儀表板的介面語言（英文或繁體中文），設定將同步儲存在伺服器。",
    "Appearance": "外觀主題",
    "Light": "淺色",
    "Dark": "深色",
    "Data Source": "資料來源",
    "Local Server": "本機伺服器",
    "Sample Preview": "範例資料預覽",
    "AI Provider Configuration": "AI 服務商設定",
    "Configure any OpenAI-compatible API (OpenAI, OpenRouter, Gemini OpenAI endpoint, local Ollama/vLLM). Used immediately by both this Web AI Coach and your iPhone app without restarting the server.": "設定任何相容 OpenAI 格式的 API（如 OpenAI、OpenRouter、Gemini 或本機模型）。儲存後無須重啟伺服器，即可立即供應網頁 AI 教練與 iPhone App 使用。",
    "Provider Base URL": "API Base URL",
    "Model Name": "模型名稱（Model）",
    "Fallback Model (Optional)": "備援模型（選填）",
    "API Key": "API 金鑰（API Key）",
    "Leave blank to keep the saved key for this host": "留空以沿用此主機已儲存的金鑰",
    "Enter a new API key (required when changing host)": "請輸入新的 API 金鑰（更換主機時必填）",
    "Daily Token Cap": "每日 Token 上限",
    "Rate Limit (req / min)": "每分鐘請求上限",
    "Save Configuration": "儲存設定",
    "Saving…": "儲存中…",
    "Test Connection": "測試連線",
    "Testing…": "測試中…",
    "Clear Saved Key": "清除已存金鑰",
    "Reset to Environment": "重設為環境變數",
    "Configured": "已設定",
    "Not configured": "尚未設定",
    "Config source": "設定來源",
    "Saved file (0600)": "本機檔案（0600）",
    "Environment variables": "環境變數",
    "File + Environment": "檔案與環境變數混合",
    "None": "無",
    "24-Hour Token Usage": "過去 24 小時 Token 用量",
    "{used} / {cap} tokens": "{used} / {cap} tokens",
    "Security & Storage": "安全性與儲存位置",
    "Your API key is stored exclusively in a local 0600 file (<data_dir>/ai-config.json) outside SQLite and is never copied into iCloud backups or JSON exports. Saved keys are strictly bound to their provider origin.": "API 金鑰僅以 0600 權限獨立存於本機 <data_dir>/ai-config.json，不寫入 SQLite 資料庫，絕不會同步至 iCloud 備份或匯出檔；且金鑰嚴格綁定來源主機以防外洩。",
    "Configuration saved.": "AI 設定已儲存。",
    "Connection succeeded ({ms} ms, model: {model}).": "連線測試成功（{ms} ms，模型：{model}）。",
    "Saved key cleared.": "已清除儲存的金鑰。",
    "Reset to environment variables.": "已重設為環境變數設定。",
    "Show key": "顯示金鑰",
    "Hide key": "隱藏金鑰",
    "Saved key": "已存金鑰",
    "Key saved (hidden)": "金鑰已儲存（隱藏）",
    # AI Coach
    "Personal AI Fitness Coach": "個人 AI 健身教練",
    "Direct read of your synced workouts, recovery fatigue, body weight, nutrition and 15-day plan — with safe Preview, Approve & Undo plan edits.": "直接讀取你同步的訓練紀錄、肌群疲勞度、體重、飲食與未來 15 天課表，並以「預覽差異 → 確認套用 → 一鍵撤銷」安全修改計畫。",
    "AI Provider Not Configured": "尚未設定 AI 服務",
    "Paste your AI API Base URL, Model, and API Key in Settings to activate your personal AI Coach.": "請先到「設定 → AI 教練與 API」貼上你的 API Base URL、模型與金鑰，即可啟用個人 AI 教練。",
    "Open AI Settings": "前往 AI 設定",
    "Live Context Loaded": "已讀取即時訓練資料",
    "Today's plan is locked on the web to protect active iPhone sessions. The AI Coach can review all history and edit upcoming days (tomorrow through +14 days).": "為保護 iPhone 上進行中的訓練，今日課表於網頁端鎖定；AI 教練可完整讀取歷史資料並調整明天起未來 14 天的課表。",
    "Ask your AI coach anything — or request a plan change…": "向你的 AI 教練提問，或要求調整接下來的課表…",
    "Ask Coach": "傳送給教練",
    "Thinking…": "教練分析中…",
    "Quick prompts": "快速提問",
    "How is my weekly muscle balance and fatigue looking?": "我這週各肌群的訓練平衡與疲勞度如何？",
    "Move tomorrow's workout to the day after tomorrow.": "把明天的訓練順延到後天。",
    "Reduce sets by 1 on my most fatigued muscle next session.": "將下次訓練中最疲勞肌群的動作減少 1 組。",
    "Suggest a lighter recovery tweak for my next training day.": "請針對我下一次訓練提出較輕量的恢復調整建議。",
    "Proposed Plan Changes": "建議課表變更（預覽）",
    "Review the Before and After diff below. Nothing is saved until you click Approve & Apply.": "請先核對以下調整前後的差異。在你按下「確認並套用變更」前，不會修改任何資料。",
    "Before": "調整前",
    "After": "調整後",
    "Approve & Apply to Plan": "確認並套用變更",
    "Applying…": "套用中…",
    "Discard Proposal": "捨棄建議",
    "Plan updated (rev {rev}). Your iPhone will merge these changes on its next sync.": "課表已更新（版本 rev {rev}），iPhone 下次同步時將自動合併這些變更。",
    "Last AI Plan Change": "最近一次 AI 課表調整",
    "Undo Last Change": "撤銷上次變更",
    "Undoing…": "撤銷中…",
    "AI plan change undone (rev {rev}).": "已撤銷上次 AI 課表變更（版本 rev {rev}）。",
    "Undo unavailable because a touched day is today or already has a logged workout.": "無法撤銷：受影響日期包含今天或已有已完成的訓練紀錄。",
    "AI Coach answered your question. No plan changes were needed.": "AI 教練已回覆你的問題，本次無須修改課表。",
    "The AI Coach suggested an adjustment that could not be safely validated against your current plan, so only advice is shown.": "AI 教練提出的變更未通過安全驗證（例如觸及鎖定日期），因此僅顯示建議內容而未產生變更。",
    "Upcoming 7 Days": "未來 7 天課表",
    "Top Fatigued Muscles": "目前最疲勞肌群",
    "Recent Workouts (14d)": "近 14 天訓練",
    "Today's Nutrition": "今日營養攝取",
    "Locked (iPhone)": "鎖定（手機端編輯）",
    "Locked": "已鎖定",
    "Rest day": "休息日",
    "Swap": "替換動作",
    "Sets": "組數",
    "Added": "新增動作",
    "All muscles recovered": "所有肌群均已恢復",
    "No meals logged today": "今日尚未記錄飲食",
    "Recovering muscles": "恢復中肌群",
    "Preview language only — switch to Local Server to save on server.": "僅預覽語言——請切換回「本機伺服器」以將設定儲存至伺服器。",
    "Switch to Local Server or connect to the server to load Traditional Chinese.": "請切換至「本機伺服器」或連接 Hexplate 伺服器以載入繁體中文介面字典。",
    "New Chat": "新對話",
    "Confirm & Apply Changes": "確認並執行更改",
    "Dismiss": "略過",
    "Applied (rev {rev})": "已執行更改（版本 rev {rev}）",
    "Suggestion dismissed": "已略過建議",
    "Plan changed — ask again": "課表已有變動，請重新詢問",
    "Review the diff below. Nothing changes until you confirm.": "請先核對以下差異；按下確認前不會修改任何課表。",
    "Ask about your recovery, muscle balance, or upcoming workouts. When the coach recommends a plan adjustment, you can review and confirm it right below the reply.": "可以詢問恢復狀態、肌群平衡或接下來的訓練計畫。當教練建議調整課表時，你可以直接在回覆下方預覽並按下確認才會執行。",
    "Message your AI Coach… (Enter to send, Shift+Enter for new line)": "輸入訊息給 AI 教練…（Enter 傳送，Shift+Enter 換行）",
    "Send": "傳送",
    "Retry": "重試",
    "AI Coach is thinking…": "AI 教練正在思考…",
}


def dashboard_zh_strings() -> dict[str, str]:
    """Full Traditional Chinese dictionary for the React web dashboard (`ZH` + `DASHBOARD_ZH`)."""
    return {**ZH, **DASHBOARD_ZH}
