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
