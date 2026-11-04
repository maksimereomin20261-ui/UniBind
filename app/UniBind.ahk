; ============================================
;  UniBind 2027 — Universal Binder
;  v2027.10 beta.1-hf2 (проверка архива, сохранение, импорт и резервные копии)
;  Биндер для GTA SAMP RP и любых других RP-серверов.
; ============================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn All, Off

; ============================================
;  DPI-АВАРНОСТЬ (критично для масштабирования оверлея)
; Без этого Windows на экранах с масштабом 125%+/150%+/200%
; виртуализирует процесс: A_ScreenWidth/Height занижены,
; окна размыты, координаты оверлея не верные.
; ============================================
try {
    ; Windows 10 1607+ — предпочитаем Per-Monitor V2 (масштаб за монитором)
    DllCall("user32\SetThreadDpiAwarenessContext", "Ptr", -4, "Ptr")  ; DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4
} catch {
    try {
        DllCall("shcore\SetProcessDpiAwareness", "Int", 2)           ; PROCESS_PER_MONITOR_DPI_AWARE = 2
    } catch {
        try {
            DllCall("user32\SetProcessDPIAware")                     ; старший Windows-режим fallback
        } catch {
            ; Не смогли установить DPI-aware — продолжим без этого
        }
    }
}
#Include lib\WebView2\WebView2.ahk
#Include lib\UniBindNeon.ahk
#Include lib\UniBindTray.ahk

; Админка — включается ТОЛЬКО если SA:MP запускается от админа.
; Если у тебя бинды не работают в GTA — раскомментируй блок ниже.
; if !A_IsAdmin {
;     try {
;         if A_IsCompiled
;             Run("*RunAs " A_ScriptFullPath)
;         else
;             Run('*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"')
;         ExitApp()
;     }
; }

; ============================================
;  ПУТИ И ПАПКИ
; ============================================
SetWorkingDir(A_ScriptDir)
global SKIP_PROFILE_SAVE_ON_EXIT := false
global ROOT_DIR     := A_ScriptDir
global DATA_DIR     := EnvGet("UNIBIND_DATA_DIR") != "" ? EnvGet("UNIBIND_DATA_DIR") : ROOT_DIR
global CONFIG_DIR   := DATA_DIR "\config"
global PROFILES_DIR := CONFIG_DIR "\profiles"
global UI_DIR       := ROOT_DIR "\ui"
global BACKUP_DIR   := DATA_DIR "\backups"
global LOG_DIR      := DATA_DIR "\logs"

for d in [CONFIG_DIR, PROFILES_DIR, UI_DIR, BACKUP_DIR, LOG_DIR]
    if !DirExist(d)
        try DirCreate(d)

global SETTINGS_FILE      := CONFIG_DIR "\settings.ini"
global PROFILES_DB := CONFIG_DIR "\profiles.dat"
global LEGACY_CONFIG_FILE := CONFIG_DIR "\doctor_config.ini"
global LEGACY_CONFIG_ROOT := DATA_DIR "\doctor_config.ini"
global HTML_FILE          := UI_DIR "\ui.html"
global UI_DOCUMENT_URI := ""
global CONFIG_FILE        := SETTINGS_FILE   ; алиас для совместимости

; ============================================
;  ЛОГИРОВАНИЕ
; ============================================
LogLine(text) {
    global LOG_DIR
    try {
        logFile := LOG_DIR "\UniBind_" A_YYYY "-" A_MM "-" A_DD ".log"
        FileAppend "[" A_Hour ":" A_Min ":" A_Sec "] " text "`n", logFile, "UTF-8"

        static lastCleanup := ""
        if (lastCleanup != A_YYYY A_MM A_DD) {
            lastCleanup := A_YYYY A_MM A_DD
            cutoff := DateAdd(A_Now, -14, "Days")
            cutoffStr := FormatTime(cutoff, "yyyyMMdd")
            Loop Files, LOG_DIR "\UniBind_*.log" {
                if RegExMatch(A_LoopFileName, "UniBind_(\d{4})-(\d{2})-(\d{2})\.log", &m) {
                    stamp := m[1] m[2] m[3]
                    if (stamp < cutoffStr)
                        try FileDelete(A_LoopFileFullPath)
                }
            }
        }
    }
}

; ============================================
;  ГЛОБАЛЬНОЕ СОСТОЯНИЕ
; ============================================
global MyGui := ""
global wvc := ""
global wv := ""
global SLOTS := []
global STATE := Map(
    "myName", "", "organization", "", "rank", "", "targetId", "",
    "variables", Map()
)
global CFG := Map(
    "chatKey", "t", "baseDelay", 2300,
    "afterChatDelay", 300, "afterEnterDelay", 400, "onlyGTA", true,
    "patientFormat", "plain", "jitter", 0,
    "overlayHotkey", "F10",
    "stopHotkey", "Backspace",
    "idInputHotkey", "p",
    "overlayOpacity", 235,
    "overlayWidth", 260,
    "overlayHeight", -1,
    "overlayX", -1,
    "overlayY", 20,
    "showIdInOverlay", true,
    "overlayEnabled", true,
    "overlayMode", "full",
    "overlayModeHotkey", "m",
    "overlayHints", "all"
)
global BINDER_ENABLED := true
global IS_SENDING := false
global SEND_BUSY := false
global FIRST_RUN := false 
global SEND_TOKEN := 0
global HK_INPUT := ""
global HK_MODS := Map("ctrl", false, "alt", false, "shift", false, "win", false)
global OVERLAY_VISIBLE := false
global OVERLAY_REBUILDING := false
global OVERLAY_PREVIEW := false
global OVERLAY_OPACITY_PREVIEW := -1
global OVERLAY_OPACITY_PREVIEW_PENDING := false
global OVERLAY_EDIT_MODE := false
global OVERLAY_EDIT_BACKUP := Map()
global OverlayEditorGui := ""
global OverlayEditorCtl := Map()
global OverlayGui := ""
global OVERLAY_INDEX := 1  ; единственный источник позиции в списке
global UI_TEXT_INPUT_ACTIVE := false
global OVERLAY_PAGE := 1
global OVERLAY_ID_INPUT_MODE := false
global OVERLAY_ID_INPUT := ""
global OVERLAY_ID_HOOK := ""
global OVERLAY_MAX_PAGES := 1
global OVERLAY_TOTAL := 0
global OVERLAY_SELECTED := 1
global OVERLAY_BINDS := []
global OVERLAY_CACHE := Map()
global NEON_LAYOUT := Map()
global ACTIVE_HOTKEYS := Map()
global UTILITY_HOTKEYS := Map("overlay", "", "stop", "", "id", "", "mode", "")
global PENDING_IMPORT_PATH := ""
global PROFILES := []
global ACTIVE_PROFILE_IDX := 1
global NEXT_PROFILE_ID := 1
global STATS := Map(
    "totalSent", 0,
    "stat1", 0, "stat2", 0, "stat3", 0, "stat4", 0, "stat5", 0
)
global CATEGORIES := []

Loop 100 {
    SLOTS.Push(Map("name", "", "hotkey", "", "enabled", false,
                   "category", "", "statType", "", "lines", [], "showInOverlay", true,
                   "sortOrder", A_Index))
}

if (A_Args.Length > 0 && A_Args[1] = "--data-self-test")
    RunDataSelfTests()

if (A_Args.Length > 0 && A_Args[1] = "--self-test")
    RunOverlaySelfTests()
if (A_Args.Length > 0 && A_Args[1] = "--overlay-gui-test")
    RunOverlayGuiSmokeTests()

if !FileExist(HTML_FILE) {
    MsgBox "ui.html не найден в " UI_DIR "`n`nОжидаемый путь: " HTML_FILE, "Ошибка", "IconX"
    ExitApp
}

if !ValidateUiBuild()
    ExitApp()

if !CheckNumericHelpers() {
    ExitApp()
}
SetupTray()
Main()

OnExit(CleanupOnExit)

CleanupOnExit(exitReason, exitCode) {
    try BlockInput("Off")
    try SetTimer(OverlayTick, 0)
    try SetTimer(BlockInputFailsafe, 0)
    global HK_INPUT, OVERLAY_ID_HOOK, PROFILES

    try {
        if !SKIP_PROFILE_SAVE_ON_EXIT && IsObject(PROFILES) && PROFILES.Length > 0
            SaveProfilesToIni()
    } catch as err {
        LogLine("CleanupOnExit: SaveProfilesToIni failed: " err.Message)
    }

    if HK_INPUT is InputHook
        try HK_INPUT.Stop()
    if OVERLAY_ID_HOOK is InputHook
        try OVERLAY_ID_HOOK.Stop()
    LogLine("Exit: " exitReason)
}

SweepOldSandboxes() {
    global CONFIG_DIR
    if !DirExist(CONFIG_DIR)
        return
    cutoff := DateAdd(A_Now, -7, "Days")
    Loop Files, CONFIG_DIR "\_import_sandbox_*", "D" {
        if (A_LoopFileTimeModified < cutoff)
            try DirDelete(A_LoopFileFullPath, 1)
    }
}

; ============================================
;  ТРЕЙ
; ============================================
SetupTray() {
    try TraySetIcon(A_ScriptFullPath)
    A_IconTip := "UniBind 2027 — Universal Binder`nЛКМ: показать окно`nПКМ: меню"

    A_TrayMenu.Delete()
    A_TrayMenu.Add("⚡  Открыть UniBind",       (*) => ShowMainGui())
    A_TrayMenu.Default := "⚡  Открыть UniBind"
    A_TrayMenu.ClickCount := 1
    A_TrayMenu.Add()
    A_TrayMenu.Add("⚙  Настройки",              (*) => OpenSettingsFromTray())
    A_TrayMenu.Add("👤  Профиль игрока",         (*) => OpenProfileFromTray())
    A_TrayMenu.Add("📋  Переменные",            (*) => OpenVarsFromTray())
    A_TrayMenu.Add()
    A_TrayMenu.Add("🗂  Папка биндов",           (*) => TrayPopup_OpenBindsFolder())
    A_TrayMenu.Add("🖥  Оверлей (показать/скрыть)", (*) => ToggleOverlay())
    A_TrayMenu.Add("🎛  Настройка Overlay",      (*) => OpenOverlaySettingsFromTray())
    A_TrayMenu.Add("🔄  Перезагрузить",         (*) => Reload())
    A_TrayMenu.Add("⏸  Приостановить хоткеи",   (*) => ToggleSuspend())
    A_TrayMenu.Add()
    A_TrayMenu.Add("🚪  Выход",                 (*) => ExitApp())
    OnMessage(0x404, TrayPopup_OnNotify)
}

ShowMainGui() {
    global MyGui
    if !MyGui
        return
    try {
        WinRestore("ahk_id " MyGui.Hwnd)
        WinActivate("ahk_id " MyGui.Hwnd)
    }
}

OpenBackupFolder() {
    global BACKUP_DIR
    if !DirExist(BACKUP_DIR)
        try DirCreate(BACKUP_DIR)
    try Run(BACKUP_DIR)
}

OpenSettingsFromTray() {
    global wv, MyGui
    if !MyGui
        return
    try {
        WinRestore("ahk_id " MyGui.Hwnd)
        WinActivate("ahk_id " MyGui.Hwnd)
        wv.PostWebMessageAsString("open_settings_from_tray")
    }
}
OpenProfileFromTray() {
    global wv, MyGui
    if !MyGui
        return
    try {
        WinRestore("ahk_id " MyGui.Hwnd)
        WinActivate("ahk_id " MyGui.Hwnd)
        wv.PostWebMessageAsString("open_profile_from_tray")
    }
}
OpenVarsFromTray() {
    global wv, MyGui
    if !MyGui
        return
    try {
        WinRestore("ahk_id " MyGui.Hwnd)
        WinActivate("ahk_id " MyGui.Hwnd)
        wv.PostWebMessageAsString("open_vars_from_tray")
    }
}
OpenOverlaySettingsFromTray() {
    global wv, MyGui
    if !MyGui
        return
    try {
        WinRestore("ahk_id " MyGui.Hwnd)
        WinActivate("ahk_id " MyGui.Hwnd)
        wv.PostWebMessageAsString("open_overlay_settings_from_tray")
    }
}

ToggleSuspend() {
    Suspend(-1)
    state := A_IsSuspended ? "приостановлены" : "активны"
    SendNotify("Хоткеи " state, A_IsSuspended ? "warning" : "success")
    try TrayTip("UniBind 2027", "Хоткеи " state, 0x1)
}

; ============================================
;  ГЛАВНОЕ ОКНО
; ============================================
Main() {
    global MyGui, wvc, wv, HTML_FILE, UI_DOCUMENT_URI

    MyGui := Gui("-Caption +Resize +MinSize1024x700", "UniBind 2027")
    MyGui.BackColor := "0x050507"
    MyGui.MarginX := 0
    MyGui.MarginY := 0
    MyGui.Show("w1280 h800 Center")
    Sleep 250
    SweepOldSandboxes()

    try WinSetStyle("-0xC40000", "ahk_id " MyGui.Hwnd)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", MyGui.Hwnd, "Int", 34, "Int*", 0xFFFFFFFE, "Int", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", MyGui.Hwnd, "Int", 33, "Int*", 2, "Int", 4)
    try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", MyGui.Hwnd, "Int", 2, "Int*", 0, "Int", 4)
    try DllCall("SetWindowPos", "Ptr", MyGui.Hwnd, "Ptr", 0, "Int", 0, "Int", 0,
        "Int", 0, "Int", 0, "UInt", 0x27, "Ptr", 0)

    try {
        loader := ROOT_DIR "\lib\WebView2\" (A_PtrSize * 8) "bit\WebView2Loader.dll"
        if !FileExist(loader)
            throw Error("WebView2Loader.dll не найден: " loader)
        userData := A_AppData "\..\Local\UniBind\WebView2"
        DirCreate(userData)
        wvc := WebView2.CreateControllerAsync(MyGui.Hwnd, 0, userData, "", loader).await2()
        wv := wvc.CoreWebView2
    } catch as err {
        LogLine("WebView2 init error: " err.Message)
        MsgBox "Ошибка WebView2: " err.Message, "Ошибка", "IconX"
        ExitApp
    }

    try wvc.DefaultBackgroundColor := 0xFF050507
    try wv.DefaultBackgroundColor := 0xFF050507
    try wv.Settings.AreBrowserAcceleratorKeysEnabled := false
    try wv.Settings.AreDefaultContextMenusEnabled := false
    ; Безопасность: интерфейсу не нужны DevTools, host-объекты, автозаполнение, зум и статус-бар.
    try wv.Settings.AreDevToolsEnabled := false
    try wv.Settings.AreHostObjectsAllowed := false
    try wv.Settings.IsStatusBarEnabled := false
    try wv.Settings.IsZoomControlEnabled := false
    try wv.Settings.IsGeneralAutofillEnabled := false
    try wv.Settings.IsPasswordAutosaveEnabled := false
    try wv.Settings.IsBuiltInErrorPageEnabled := false
    try wvc.Fill()
    try wvc.IsVisible := 1

    ; Register against the API shipped with this package. Fail visibly if registration fails.
    try {
        UI_DOCUMENT_URI := BuildUiDocumentUri(HTML_FILE)
        wv.add_WebMessageReceived(OnWebMessage)
        wv.add_NavigationStarting(OnUiNavigationStarting)
        wv.add_NewWindowRequested(OnUiNewWindowRequested)
        wv.add_NavigationCompleted((*) => OnNavigationCompleted())
    } catch as err {
        LogLine("WebView2 event registration failed: " err.Message)
        MsgBox "Не удалось подключить интерфейс: " err.Message, "UniBind", "IconX"
        ExitApp()
    }
    wv.Navigate(UI_DOCUMENT_URI "?build=2027.10-beta1")

    MyGui.OnEvent("Size", GuiResize)
    SetTimer(() => FallbackInit(), -2500)
    SetTimer(() => CheckGameStatus(), 2000)

    LoadConfig()
}

FallbackInit() {
    global wv
    if !wv
        return
    static done := false
    if done
        return
    done := true
    PushDataToHtml()
    RegisterAllHotkeys()
    SendOverlayState()
    SendStatus()
    SendFirstRunCheck()
}

OnNavigationCompleted() {
    SetTimer(() => (
        PushDataToHtml(),
        RegisterAllHotkeys(),
        SendOverlayState(),
        SendStatus(),
        SendFirstRunCheck()
    ), -200)
}



GuiResize(gui, minMax, w, h) {
    global wvc
    if (minMax = -1)
        return
    try wvc.Fill()
    SetTimer(() => DoFill(), -100)
}


DoFill() {
    global wvc
    try wvc.Fill()
}
; ============================================
;  СТАТУС ИГРЫ
; ============================================
CheckGameStatus() {
    global wv
    if !wv
        return
    static lastStatus := ""
    isRunning := ProcessExist("gta_sa.exe") ? true : false
    newStatus := isRunning ? "1" : "0"
    if (newStatus = lastStatus)
        return
    lastStatus := newStatus
    try wv.PostWebMessageAsString("game_status:" . newStatus)
}

; ============================================
;  ПЕРВЫЙ ЗАПУСК
; ============================================
SendFirstRunCheck() {
    global FIRST_RUN, wv
    if !FIRST_RUN || !wv
        return
    try wv.PostWebMessageAsString("show_welcome")
}

HandleWelcomeChoice(choice) {
    global FIRST_RUN, CONFIG_DIR, ROOT_DIR, BACKUP_DIR

    LogLine("Welcome choice: " choice)

    if (choice = "default") {
        ; Сначала пробуем восстановить твой сохранённый конфиг
        if TryRestoreExistingConfig() {
            FIRST_RUN := false
            try TrayTip("UniBind 2027", "Конфиг восстановлен. Перезапуск...", 0x1)
            Sleep(600)
            Reload()
            return
        }
        ; Нечего восстанавливать — генерируем универсальный набор
        SetupUniversalProfile()
    } else if (choice = "medical") {
        SetupMedicalProfile()
    } else {
        SetupEmptyProfile()
    }

    FIRST_RUN := false
    try TrayTip("UniBind 2027", "Профиль готов. Перезапуск...", 0x1)
    Sleep(500)
    Reload()
}

; Ищет сохранённый конфиг и восстанавливает его.
; Порядок поиска:
;   1) ROOT_DIR\config_backup\settings.ini — целая папка config от прошлого запуска
;   2) ROOT_DIR\config_backup_*\settings.ini — старая переименованная (любая)
;   3) BACKUP_DIR\*.UniBind (последний по времени) — полный экспорт
; Возвращает true, если что-то восстановили.
TryRestoreExistingConfig() {
    global CONFIG_DIR, DATA_DIR, BACKUP_DIR, PROFILES_DIR, CONFIG_FILE

    ; --- 1 и 2. config_backup* ---
    ; Ищем папки вида config_backup, config_backup_2026-10-09 и т.п.
    candidates := []
    if DirExist(DATA_DIR "\config_backup")
        candidates.Push(DATA_DIR "\config_backup")
    Loop Files, DATA_DIR "\config_backup_*", "D" {
        ; Только те, что похожи на бэкап конфига (внутри есть settings.ini)
        if FileExist(A_LoopFileFullPath "\settings.ini")
            candidates.Push(A_LoopFileFullPath)
    }

    if (candidates.Length > 0) {
        bkDir := candidates[1]
        LogLine("Restore: найден конфиг-бэкап " bkDir)
        try {
            ; Отложим текущий пустой config в сторону
            if DirExist(CONFIG_DIR)
                try DirMove(CONFIG_DIR, CONFIG_DIR "_empty_" A_YYYY A_MM A_DD "_" A_Hour A_Min)
            DirMove(bkDir, CONFIG_DIR)
            LogLine("Restore: config_backup → config")
            return true
        } catch as err {
            LogLine("Restore config_backup failed: " err.Message)
        }
    }

    ; --- 3. backups\*.UniBind — самый свежий ---
    if DirExist(BACKUP_DIR) {
        latest := ""
        latestTime := ""
        Loop Files, BACKUP_DIR "\*.UniBind" {
            if (A_LoopFileTimeModified > latestTime) {
                latestTime := A_LoopFileTimeModified
                latest := A_LoopFileFullPath
            }
        }
        if (latest != "") {
            ; Проверим, это полный экспорт (с [Meta] formatVersion) или
            ; одиночный бэкап профиля (создаётся при удалении профиля).
            fmt := IniValue(ReadIniRaw(latest), "Meta", "formatVersion")
            if (fmt != "") {
                LogLine("Restore: попытка из " latest)
                if RestoreFromUniBindExport(latest)
                    return true
            } else {
                LogLine("Restore: " latest " — одиночный профиль, пропуск")
            }
        }
    }

    LogLine("Restore: нечего восстанавливать")
    return false
}

; Восстанавливает конфиг из файла полного экспорта (.UniBind).
RestoreFromUniBindExport(path) {
    try {
        size := FileGetSize(path)
        if (size < 10 || size > 16 * 1024 * 1024)
            return false
        data := ReadIniRaw(path)
        if (IniValue(data, "Meta", "formatVersion") = "")
            return false
        ApplyImportSnapshot(data)
        return true
    } catch as err {
        LogLine("Restore export failed: " err.Message)
        return false
    }
}

SetupUniversalProfile() {
    global CONFIG_FILE, PROFILES_DIR

    ; --- settings.ini: базовые настройки ---
    try FileDelete(CONFIG_FILE)
    IniWrite("t",   CONFIG_FILE, "Settings", "chatKey")
    IniWrite(2300,  CONFIG_FILE, "Settings", "baseDelay")
    IniWrite(300,   CONFIG_FILE, "Settings", "afterChatDelay")
    IniWrite(400,   CONFIG_FILE, "Settings", "afterEnterDelay")
    IniWrite("plain", CONFIG_FILE, "Settings", "patientFormat")
    IniWrite(1,     CONFIG_FILE, "Settings", "onlyGTA")
    IniWrite(0,     CONFIG_FILE, "Settings", "jitter")
    IniWrite(1,     CONFIG_FILE, "Settings", "binderEnabled")

    ; --- профили ---
    IniWrite(1, CONFIG_FILE, "Profiles", "count")
    IniWrite(1, CONFIG_FILE, "Profiles", "active")
    IniWrite(2, CONFIG_FILE, "Profiles", "nextId")
    IniWrite(1, CONFIG_FILE, "Profiles", "profile1_id")
    IniWrite("Стандартный профиль", CONFIG_FILE, "Profiles", "profile1_label")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_name")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_hospital")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_rank")

    ; --- оверлей ---
    IniWrite(1,           CONFIG_FILE, "Overlay", "enabled")
    IniWrite("F10",       CONFIG_FILE, "Overlay", "hotkey")
    IniWrite("Backspace", CONFIG_FILE, "Overlay", "stopHotkey")
    IniWrite("p",         CONFIG_FILE, "Overlay", "idInputHotkey")
    IniWrite(235,         CONFIG_FILE, "Overlay", "opacity")
    IniWrite(260,         CONFIG_FILE, "Overlay", "width")
    IniWrite(-1,          CONFIG_FILE, "Overlay", "height")
    IniWrite(-1,          CONFIG_FILE, "Overlay", "x")
    IniWrite(20,          CONFIG_FILE, "Overlay", "y")
    IniWrite(1,           CONFIG_FILE, "Overlay", "showId")
    IniWrite("full",      CONFIG_FILE, "Overlay", "mode")
    IniWrite("m",         CONFIG_FILE, "Overlay", "modeHotkey")

    ; --- profiles\P1.ini ---
    pFile := PROFILES_DIR "\P1.ini"
    try FileDelete(pFile)

    cats := [
        ["Приветствие", "fa-comment"],
        ["RP-действия", "fa-user"],
        ["Основное",    "fa-star"],
        ["Прочее",      "fa-folder"]
    ]
    IniWrite(cats.Length, pFile, "Categories", "count")
    for i, c in cats {
        IniWrite(c[1], pFile, "Categories", "cat" i "_name")
        IniWrite(c[2], pFile, "Categories", "cat" i "_icon")
    }

    slots := [
        { n: "Приветствие", hk: "F1", cat: "Приветствие", st: "", lines: [
            { t: "Привет, {T}! Я {MY} из {ORG}.", d: 0 }
        ]},
        { n: "Представление", hk: "F2", cat: "Приветствие", st: "", lines: [
            { t: "Меня зовут {MY}, {RANK} организации {ORG}.", d: 2300 },
            { t: "/me представляется", d: 2000 },
            { t: "/do {MY} ждёт ответа.", d: 0 }
        ]},
        { n: "Действие /me", hk: "F3", cat: "RP-действия", st: "stat1", lines: [
            { t: "/me делает что-то", d: 2000 },
            { t: "/do Действие выполнено.", d: 0 }
        ]},
        { n: "Взять предмет", hk: "F4", cat: "RP-действия", st: "stat2", lines: [
            { t: "/me берёт предмет", d: 2000 },
            { t: "/do Предмет в руках.", d: 0 }
        ]},
        { n: "Согласие", hk: "F6", cat: "Основное", st: "", lines: [
            { t: "Хорошо, {T}, договорились.", d: 0 }
        ]},
        { n: "Прощание", hk: "F7", cat: "Приветствие", st: "", lines: [
            { t: "До связи, {T}. Хорошего дня!", d: 0 }
        ]}
    ]

    for i, s in slots {
        sec := "Slot" i
        IniWrite(s.n,  pFile, sec, "name")
        IniWrite(s.hk, pFile, sec, "hotkey")
        IniWrite(1,    pFile, sec, "enabled")
        IniWrite(s.cat, pFile, sec, "category")
        IniWrite(s.st,  pFile, sec, "statType")
        IniWrite(1,    pFile, sec, "showInOverlay")
        IniWrite(i,    pFile, sec, "sortOrder")
        IniWrite(s.lines.Length, pFile, sec, "lineCount")
        for li, ln in s.lines {
            IniWrite(ln.t, pFile, sec, "line" li "_text")
            IniWrite(ln.d, pFile, sec, "line" li "_delay")
        }
    }
}

; ============================================================
; Медицинский набор — из шаблона lib\templates\medical_profile.ini
; Копирует файл БАЙТ-В-БАЙТ → кодировка и эмодзи сохраняются.
; ============================================================
SetupMedicalProfile() {
    global CONFIG_FILE, PROFILES_DIR, ROOT_DIR

    ; --- settings.ini: базовые настройки ---
    try FileDelete(CONFIG_FILE)
    IniWrite("t",   CONFIG_FILE, "Settings", "chatKey")
    IniWrite(2300,  CONFIG_FILE, "Settings", "baseDelay")
    IniWrite(300,   CONFIG_FILE, "Settings", "afterChatDelay")
    IniWrite(400,   CONFIG_FILE, "Settings", "afterEnterDelay")
    IniWrite("plain", CONFIG_FILE, "Settings", "patientFormat")
    IniWrite(1,     CONFIG_FILE, "Settings", "onlyGTA")
    IniWrite(0,     CONFIG_FILE, "Settings", "jitter")
    IniWrite(1,     CONFIG_FILE, "Settings", "binderEnabled")

    IniWrite(1, CONFIG_FILE, "Profiles", "count")
    IniWrite(1, CONFIG_FILE, "Profiles", "active")
    IniWrite(2, CONFIG_FILE, "Profiles", "nextId")
    IniWrite(1, CONFIG_FILE, "Profiles", "profile1_id")
    IniWrite("Медицинский профиль", CONFIG_FILE, "Profiles", "profile1_label")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_name")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_hospital")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_rank")

    IniWrite(1,           CONFIG_FILE, "Overlay", "enabled")
    IniWrite("F10",       CONFIG_FILE, "Overlay", "hotkey")
    IniWrite("Backspace", CONFIG_FILE, "Overlay", "stopHotkey")
    IniWrite("p",         CONFIG_FILE, "Overlay", "idInputHotkey")
    IniWrite(235,         CONFIG_FILE, "Overlay", "opacity")
    IniWrite(260,         CONFIG_FILE, "Overlay", "width")
    IniWrite(-1,          CONFIG_FILE, "Overlay", "height")
    IniWrite(-1,          CONFIG_FILE, "Overlay", "x")
    IniWrite(20,          CONFIG_FILE, "Overlay", "y")
    IniWrite(1,           CONFIG_FILE, "Overlay", "showId")
    IniWrite("full",      CONFIG_FILE, "Overlay", "mode")
    IniWrite("m",         CONFIG_FILE, "Overlay", "modeHotkey")

    ; --- профиль: копия шаблона ---
    template := ROOT_DIR "\lib\templates\medical_profile.ini"
    pFile := PROFILES_DIR "\P1.ini"
    try FileDelete(pFile)

    if !FileExist(template) {
        LogLine("SetupMedicalProfile: шаблон не найден: " template " → fallback")
        SetupUniversalProfile()
        return
    }

    ; Читаем шаблон через ReadIniRaw (сам определит кодировку),
    ; затем пишем через WriteIniRaw — получим чистый UTF-16
    ; БЕЗ багов WinAPI с длинными русскими строками.
    try {
        tpl := ReadIniRaw(template)
        LogLine("SetupMedicalProfile: шаблон прочитан, секций=" tpl.Count)
        WriteIniRaw(pFile, tpl)
        LogLine("SetupMedicalProfile: записан → P1.ini")
    } catch as err {
        LogLine("SetupMedicalProfile: error: " err.Message)
        SetupUniversalProfile()
    }
}


SetupEmptyProfile() {
    global CONFIG_FILE, PROFILES_DIR

    try FileDelete(CONFIG_FILE)
    IniWrite("t",   CONFIG_FILE, "Settings", "chatKey")
    IniWrite(2300,  CONFIG_FILE, "Settings", "baseDelay")
    IniWrite(300,   CONFIG_FILE, "Settings", "afterChatDelay")
    IniWrite(400,   CONFIG_FILE, "Settings", "afterEnterDelay")
    IniWrite("plain", CONFIG_FILE, "Settings", "patientFormat")
    IniWrite(1,     CONFIG_FILE, "Settings", "onlyGTA")
    IniWrite(0,     CONFIG_FILE, "Settings", "jitter")
    IniWrite(1,     CONFIG_FILE, "Settings", "binderEnabled")

    IniWrite(1, CONFIG_FILE, "Profiles", "count")
    IniWrite(1, CONFIG_FILE, "Profiles", "active")
    IniWrite(2, CONFIG_FILE, "Profiles", "nextId")
    IniWrite(1, CONFIG_FILE, "Profiles", "profile1_id")
    IniWrite("Мой профиль", CONFIG_FILE, "Profiles", "profile1_label")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_name")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_hospital")
    IniWrite("", CONFIG_FILE, "Profiles", "profile1_rank")

    IniWrite(1,           CONFIG_FILE, "Overlay", "enabled")
    IniWrite("F10",       CONFIG_FILE, "Overlay", "hotkey")
    IniWrite("Backspace", CONFIG_FILE, "Overlay", "stopHotkey")
    IniWrite("p",         CONFIG_FILE, "Overlay", "idInputHotkey")
    IniWrite(235,         CONFIG_FILE, "Overlay", "opacity")
    IniWrite(260,         CONFIG_FILE, "Overlay", "width")
    IniWrite(-1,          CONFIG_FILE, "Overlay", "height")
    IniWrite(-1,          CONFIG_FILE, "Overlay", "x")
    IniWrite(20,          CONFIG_FILE, "Overlay", "y")
    IniWrite(1,           CONFIG_FILE, "Overlay", "showId")
    IniWrite("full",      CONFIG_FILE, "Overlay", "mode")
    IniWrite("m",         CONFIG_FILE, "Overlay", "modeHotkey")

    pFile := PROFILES_DIR "\P1.ini"
    try FileDelete(pFile)
    IniWrite(0, pFile, "Categories", "count")
}


; ============================================
;  WEBVIEW MESSAGE
; ============================================
BuildUiDocumentUri(path) {
    ; Canonical Windows file URI; handles spaces, Cyrillic and percent signs.
    output := Buffer(65536, 0)
    chars := output.Size // 2
    hr := DllCall("shlwapi\UrlCreateFromPathW", "Str", path, "Ptr", output, "UInt*", &chars, "UInt", 0, "Int")
    if (hr < 0)
        throw Error("UrlCreateFromPathW failed: " hr)
    return StrGet(output, "UTF-16")
}

IsTrustedUiDocument(uri) {
    global UI_DOCUMENT_URI
    if (UI_DOCUMENT_URI = "" || uri = "")
        return false
    document := RegExReplace(uri, "[?#].*$")
    return DllCall("shlwapi\UrlCompareW", "Str", document, "Str", UI_DOCUMENT_URI, "Int", 0, "Int") = 0
}

OpenExternalHttpUrl(url) {
    ; Reject quotes/control chars before passing a quoted URL to ShellExecute.
    if !RegExMatch(url, 'i)^https?://[^\s"<>]+$') || StrLen(url) > 8192
        return false
    try {
        Run('"' url '"')
        return true
    } catch as err {
        LogLine("Open URL failed: " err.Message)
        return false
    }
}

OnUiNavigationStarting(sender, args) {
    try {
        if IsTrustedUiDocument(args.Uri)
            return
        args.Cancel := true
        if args.IsUserInitiated
            OpenExternalHttpUrl(args.Uri)
    } catch as err {
        try args.Cancel := true
        LogLine("Blocked navigation: " err.Message)
    }
}

OnUiNewWindowRequested(sender, args) {
    try {
        args.Handled := true
        if args.IsUserInitiated
            OpenExternalHttpUrl(args.Uri)
    } catch as err {
        LogLine("Blocked new window: " err.Message)
    }
}

SplitUiFields(message) {
    fields := StrSplit(message, "|~|")
    for index, value in fields {
        if (index > 1 && SubStr(value, 1, 5) = "~ub2~") {
            ; Decode only tagged fields, once, in this order. Literal percent escapes survive.
            value := SubStr(value, 6)
            fields[index] := StrReplace(StrReplace(value, "%7C", "|", true), "%25", "%", true)
        }
    }
    return fields
}

OnWebMessage(sender, args) {
    global MyGui, BINDER_ENABLED, STATE, SLOTS, wv, OVERLAY_VISIBLE, CONFIG_FILE, OVERLAY_CACHE, IS_SENDING

    try {
        if !IsTrustedUiDocument(args.Source) {
            LogLine("Rejected WebMessage from untrusted document")
            return
        }
        msg := args.TryGetWebMessageAsString()

        if (StrLen(msg) > 4194304) {
            LogLine("WebMessage too large: " StrLen(msg))
            SendNotify("Пакет данных слишком велик; уменьшите объём изменений", "error")
            return
        }
        if (msg = "")
            return

        if (SubStr(msg, 1, 4) = "win:") {
            cmd := SubStr(msg, 5)
            switch cmd {
                case "close": ExitApp()
                case "min":   WinMinimize("ahk_id " MyGui.Hwnd)
                case "max":
                    if DllCall("IsZoomed", "Ptr", MyGui.Hwnd)
                        WinRestore("ahk_id " MyGui.Hwnd)
                    else
                        WinMaximize("ahk_id " MyGui.Hwnd)
                case "drag":
                    try {
                        DllCall("ReleaseCapture")
                        DllCall("SendMessage", "Ptr", MyGui.Hwnd, "UInt", 0xA1, "Ptr", 2, "Ptr", 0)
                    }
            }
            return
        }

        if (msg = "start_hk_capture") {
            StartHotkeyCapture()
            return
        }
        if (msg = "stop_hk_capture") {
            StopHotkeyCapture()
            return
        }
        if (msg = "start_overlay_hk_capture") {
            StartOverlayHotkeyCapture()
            return
        }
        if (msg = "start_stop_hk_capture") {
            StartStopHotkeyCapture()
            return
        }
        if (msg = "start_id_hk_capture") {
            StartIdHotkeyCapture()
            return
        }
        if (msg = "start_mode_hk_capture") {
            StartModeHotkeyCapture()
            return
        }

        if (msg = "welcome_default") {
            HandleWelcomeChoice("default")
            return
        }
        if (msg = "welcome_medical") {
            HandleWelcomeChoice("medical")
            return
        }
        if (msg = "welcome_new") {
            HandleWelcomeChoice("new")
            return
        }

        if (msg = "toggle_binder") {
            BINDER_ENABLED := !BINDER_ENABLED
            try IniSetSafe(CONFIG_FILE, "Settings", "binderEnabled", BINDER_ENABLED ? 1 : 0)

            if BINDER_ENABLED {
                RegisterAllHotkeys()
                SendNotify("Биндер включён", "success")
            } else {
                StopSending()
                ClearAllSlotHotkeys()
                UnregisterUtilityHotkeys()
                if OVERLAY_VISIBLE
                    HideOverlay()
                SendNotify("Биндер выключен — хоткеи отключены", "warning")
            }
            SendStatus()
            PushDataToHtml()
            return
        }

        if (SubStr(msg, 1, 14) = "ui_text_focus:") {
            global UI_TEXT_INPUT_ACTIVE
            UI_TEXT_INPUT_ACTIVE := (SubStr(msg, 15) = "1")
            return
        }
        if (SubStr(msg, 1, 12) = "overlay_nav:") {
            if !OVERLAY_VISIBLE
                return
            action := SubStr(msg, 13)
            switch action {
                case "up": OverlayMoveSel(-1)
                case "down": OverlayMoveSel(1)
                case "prev": OverlayPage(-1)
                case "next": OverlayPage(1)
                case "first": OverlaySelectBoundary(false)
                case "last": OverlaySelectBoundary(true)
                case "run": OverlayRunSelected()
                case "hide": HideOverlay()
            }
            return
        }
        if (SubStr(msg, 1, StrLen("preview_overlay_opacity:")) = "preview_overlay_opacity:") {
            value := SubStr(msg, StrLen("preview_overlay_opacity:") + 1)
            if !RegExMatch(value, "^\d{1,3}$")
                return
            global OVERLAY_OPACITY_PREVIEW, OVERLAY_OPACITY_PREVIEW_PENDING
            OVERLAY_OPACITY_PREVIEW := SafeInt(value, 235, 80, 255)
            if !OVERLAY_OPACITY_PREVIEW_PENDING {
                OVERLAY_OPACITY_PREVIEW_PENDING := true
                SetTimer(ApplyOverlayOpacityPreview, -25)
            }
            return
        }
        if (msg = "clear_overlay_opacity_preview") {
            ClearOverlayOpacityPreview()
            return
        }
        if (msg = "toggle_overlay") {
            ToggleOverlay()
            return
        }
        if (msg = "export_config") {
            ExportConfig()
            return
        }
        if (msg = "import_config") {
            ImportConfig()
            return
        }
        if (msg = "import_confirmed") {
            ImportConfigConfirmed()
            return
        }
        if (msg = "import_cancelled") {
            ImportConfigCancelled()
            return
        }
        if (msg = "paste_into_field") {
            PasteIntoField()
            return
        }

        if (SubStr(msg, 1, 9) = "open_url:") {
            url := SubStr(msg, 10)
            OpenExternalHttpUrl(url)
            return
        }
        if (msg = "start_overlay_editing") {
            StartOverlayEdit()
            return
        }
        if (msg = "stop_overlay_editing_apply") {
            StopOverlayEdit(true)
            return
        }
        if (msg = "stop_overlay_editing_cancel") {
            StopOverlayEdit(false)
            return
        }

        if (msg = "toggle_overlay_preview") {
            ToggleOverlayPreview()
            return
        }

        if (SubStr(msg, 1, 17) = "set_overlay_mode:") {
            SetOverlayModeLive(SubStr(msg, 18))
            return
        }

        if (SubStr(msg, 1, 20) = "set_overlay_enabled:") {
            val := SubStr(msg, 21)
            CFG["overlayEnabled"] := (val = "1")
            try IniSetSafe(CONFIG_FILE, "Overlay", "enabled", CFG["overlayEnabled"] ? 1 : 0)
            if !CFG["overlayEnabled"] && OVERLAY_VISIBLE
                HideOverlay()
            PushDataToHtml()
            return
        }

        if (msg = "reset_stats") {
            ResetStats()
            return
        }

        if (SubStr(msg, 1, 8) = "run_bind") {
            parts := StrSplit(msg, ":")
            if (parts.Length >= 2)
                RunSlotByNum(RequireInt(parts[2], 1, 100, "Номер бинда"), true)
            return
        }

        if (msg = "create_bind") {
            HandleCreateBind()
            return
        }
        if (SubStr(msg, 1, 12) = "delete_bind:") {
            HandleDeleteBind(Integer(SubStr(msg, 13)))
            return
        }
        if (SubStr(msg, 1, 10) = "copy_bind:") {
            HandleCopyBind(Integer(SubStr(msg, 11)))
            return
        }
        if (SubStr(msg, 1, 9) = "save_bind") {
            HandleSaveBind(msg)
            return
        }
        if (SubStr(msg, 1, 9) = "save_vars") {
            HandleSaveVars(msg)
            return
        }
        if (SubStr(msg, 1, 14) = "save_profile__") {
            HandleSaveProfile(msg)
            return
        }
        if (SubStr(msg, 1, 15) = "switch_profile:") {
            SwitchProfile(Integer(SubStr(msg, 16)))
            return
        }
        if (SubStr(msg, 1, 15) = "delete_profile:") {
            HandleDeleteProfile(Integer(SubStr(msg, 16)))
            return
        }

        if (msg = "list_profile_backups") {
            ListProfileBackups()
            return
        }
        if (msg = "open_backup_folder") {
            OpenBackupFolder()
            return
        }
        if (SubStr(msg, 1, 23) = "restore_profile_backup:") {
            RestoreProfileBackup(SubStr(msg, 24))
            return
        }

        if (SubStr(msg, 1, 15) = "save_settings__") {
            HandleSaveSettings(msg)
            return
        }
        if (SubStr(msg, 1, 22) = "save_overlay_settings_") {
            HandleSaveOverlaySettings(msg)
            return
        }
        if (SubStr(msg, 1, 15) = "save_categories") {
            HandleSaveCategories(msg)
            return
        }
        if (SubStr(msg, 1, 14) = "reorder_binds:") {
            HandleReorderBinds(SubStr(msg, 15))
            return
        }

        if (SubStr(msg, 1, 11) = "set_patient") {
            parts := StrSplit(msg, ":")
            if (parts.Length >= 2) {
                ; ID цели уходит прямо в игровой чат — допускаем только 0–5 цифр (как в UI и оверлее).
                if !RegExMatch(parts[2], "^\d{0,5}$") {
                    LogLine("set_patient: отклонён некорректный ID")
                    SendNotify("ID цели должен состоять из 1–5 цифр", "warning")
                    return
                }
                STATE["targetId"] := parts[2]
                OVERLAY_CACHE["OverlayPatient"] := ""
                PushDataToHtml()
                UpdateOverlay()
                if (STATE["targetId"] != "")
                    SendNotify("ID цели: #" STATE["targetId"], "success")
                else
                    SendNotify("ID цели очищен", "info")
            }
            return
        }
    } catch as err {
        LogLine("WebMessage error: " err.Message)
        SendNotify("Не удалось выполнить действие: " err.Message, "error")
        if IsSet(msg) {
            if (SubStr(msg, 1, 22) = "save_overlay_settings_") {
                try wv.PostWebMessageAsString("overlay_settings_error:" err.Message)
            } else if (SubStr(msg, 1, 15) = "save_settings__") {
                try wv.PostWebMessageAsString("settings_error:" err.Message)
            }
        }
    }
}

; ============================================
;  ПРОФИЛИ — ФАЙЛОВАЯ СИСТЕМА
; ============================================
ProfilePath(idx) {
    global PROFILES, PROFILES_DIR
    if (idx < 1 || idx > PROFILES.Length)
        return ""
    p := PROFILES[idx]
    byId := PROFILES_DIR "\P" p["id"] ".ini"
    if FileExist(byId)
        return byId
    byIdx := PROFILES_DIR "\P" idx ".ini"
    if FileExist(byIdx)
        return byIdx
    return byId
}

ProfilePathById(id) {
    global PROFILES_DIR
    return PROFILES_DIR "\P" id ".ini"
}

ActiveProfileId() {
    global PROFILES, ACTIVE_PROFILE_IDX
    if (ACTIVE_PROFILE_IDX < 1 || ACTIVE_PROFILE_IDX > PROFILES.Length)
        return 1
    return PROFILES[ACTIVE_PROFILE_IDX]["id"]
}

ClearSlots() {
    global SLOTS
    Loop 100 {
        SLOTS[A_Index] := Map("name", "", "hotkey", "", "enabled", false,
                              "category", "", "statType", "", "lines", [], "showInOverlay", true,
                              "sortOrder", A_Index)
    }
}

ApplyProfileToState(idx) {
    global PROFILES, STATE
    if (idx < 1 || idx > PROFILES.Length)
        return
    p := PROFILES[idx]
    STATE["myName"]   := p["name"]
    STATE["organization"] := p["organization"]
    STATE["rank"]     := p["rank"]
}

SaveActiveProfileToIni(slotsValue := 0, categoriesValue := 0) {
    global SLOTS, CATEGORIES, ACTIVE_PROFILE_IDX, PROFILES
    if (ACTIVE_PROFILE_IDX < 1 || ACTIVE_PROFILE_IDX > PROFILES.Length)
        return
    slots := IsObject(slotsValue) ? slotsValue : SLOTS
    cats := IsObject(categoriesValue) ? categoriesValue : CATEGORIES
    data := Map("Categories", Map("count", cats.Length))
    for i, cat in cats {
        data["Categories"]["cat" i "_name"] := cat["name"]
        data["Categories"]["cat" i "_icon"] := cat.Has("icon") ? cat["icon"] : ""
    }
    for i, slot in slots {
        if (slot["name"] != "" || slot["lines"].Length > 0)
            data["Slot" i] := SlotIniData(slot)
    }
    WriteIniRaw(ProfilePath(ACTIVE_PROFILE_IDX), data)
}

LoadActiveProfileFromIni() {
    global SLOTS, CATEGORIES, ACTIVE_PROFILE_IDX, PROFILES

    ClearSlots()
    CATEGORIES := []

    pf := ProfilePath(ACTIVE_PROFILE_IDX)
    LogLine("LAP: idx=" ACTIVE_PROFILE_IDX " pf=" pf " exists=" (FileExist(pf) ? 1 : 0))
    if (pf = "" || !FileExist(pf)) {
        LogLine("LAP: файла нет, выходим")
        return
    }

    ini := ReadIniRaw(pf)
    LogLine("LAP: sections in file = " ini.Count)

    loadedCount := 0
    Loop 100 {
        slotIdx := A_Index
        sec := "Slot" slotIdx
        if !ini.Has(sec)
            continue
        slotData := ini[sec]

        name := ""
        hk := ""
        enabledStr := "0"
        categoryStr := ""
        statTypeStr := ""
        showOvStr := "1"
        sortStr := "0"

        ; Предзаполненные массивы на 100 строк — никаких Has()
        txtArr := []
        dlyArr := []
        Loop 100 {
            txtArr.Push("")
            dlyArr.Push(0)
        }
        maxLineIdx := 0

        ; ОДИН проход по slotData — точно работает (maxLine уже доказал)
        for k, v in slotData {
            if (k = "name")
                name := v
            else if (k = "hotkey")
                hk := v
            else if (k = "enabled")
                enabledStr := v
            else if (k = "category")
                categoryStr := v
            else if (k = "statType")
                statTypeStr := v
            else if (k = "showInOverlay")
                showOvStr := v
            else if (k = "sortOrder")
                sortStr := v
            else if (SubStr(k, 1, 4) = "line") {
                rest := SubStr(k, 5)
                usPos := InStr(rest, "_")
                if (usPos < 2)
                    continue
                numStr := SubStr(rest, 1, usPos - 1)
                suffix := SubStr(rest, usPos + 1)
                if !RegExMatch(numStr, "^\d+$")
                    continue
                idx := SafeInt(numStr, 0, 0, 101)
                if (idx < 1 || idx > 100)
                    continue
                if (suffix = "text") {
                    txtArr[idx] := v
                    if (idx > maxLineIdx)
                        maxLineIdx := idx
                } else if (suffix = "delay") {
                    dv := 0
                    try
                        dv := Integer(v)
                    catch
                        dv := 0
                    if (dv < 0) {
                        dv := 0
                    }
                    if (dv > 120000) {
                        dv := 120000
                    }
                    dlyArr[idx] := dv
                }
            }
        }

        if (name = "")
            continue
        loadedCount++

        SLOTS[slotIdx]["name"] := name
        SLOTS[slotIdx]["hotkey"] := hk
        SLOTS[slotIdx]["enabled"] := (enabledStr = "1")
        SLOTS[slotIdx]["category"] := categoryStr
        SLOTS[slotIdx]["statType"] := statTypeStr
        SLOTS[slotIdx]["showInOverlay"] := (showOvStr = "1")

        sortVal := slotIdx
        try
            sortVal := Integer(sortStr)
        catch
            sortVal := slotIdx
        SLOTS[slotIdx]["sortOrder"] := sortVal

        ; Собираем строки — только прямая индексация массива, без Has()
        linesArr := []
        li := 1
        while (li <= maxLineIdx) {
            txt := txtArr[li]
            if (txt != "") {
                if (StrLen(txt) > 4096)
                    txt := SubStr(txt, 1, 4096)
                dly := dlyArr[li]
                linesArr.Push(Map("text", txt, "delay", dly))
            }
            li++
        }
        SLOTS[slotIdx]["lines"] := linesArr
    }
    LogLine("LAP: loadedCount=" loadedCount)

    CATEGORIES := []
    if ini.Has("Categories") {
        catSec := ini["Categories"]
        cnt := 0
        try
            cnt := Integer(catSec.Has("count") ? catSec["count"] : "0")
        catch
            cnt := 0
        if (cnt > 50) {
            cnt := 50
        }
        Loop cnt {
            n := catSec.Has("cat" A_Index "_name") ? catSec["cat" A_Index "_name"] : ""
            ic := catSec.Has("cat" A_Index "_icon") ? catSec["cat" A_Index "_icon"] : ""
            if (n != "")
                CATEGORIES.Push(Map("name", n, "icon", ic))
        }
    }
    LogLine("LAP: итог CATEGORIES.Length=" CATEGORIES.Length)
    if (CATEGORIES.Length = 0)
        MigrateCategoriesFromBinds()
}

DeleteProfileData(idx) {
    global PROFILES
    pf := ProfilePath(idx)
    if (pf != "" && FileExist(pf))
        try FileDelete(pf)
}

; ============================================
;  БЭКАПЫ ПРОФИЛЕЙ
; ============================================
BackupProfileData(idx) {
    global PROFILES, BACKUP_DIR

    if (idx < 1 || idx > PROFILES.Length)
        return

    p := PROFILES[idx]
    label := p["label"]
    safeLabel := label
    for ch in ["\", "/", ":", "*", "?", '"', "'", "<", ">", "|"]
        safeLabel := StrReplace(safeLabel, ch, "_")
    safeLabel := RegExReplace(safeLabel, "[\x00-\x1F]", "_")
    safeLabel := Trim(SubStr(safeLabel, 1, 40), " .")
    if (safeLabel = "" || RegExMatch(safeLabel, "i)^(CON|PRN|AUX|NUL|COM\d|LPT\d)$"))
        safeLabel := "profile"

    ts := A_YYYY "-" A_MM "-" A_DD "_" A_Hour "-" A_Min "-" A_Sec
    bkFile := BACKUP_DIR "\Profile_" safeLabel "_" ts "_P" p["id"] "_" A_TickCount ".UniBind"

    pf := ProfilePath(idx)
    if (pf = "" || !FileExist(pf))
        throw Error("Нет файла профиля для резервной копии; удаление отменено")

    ; Читаем файл профиля через ReadIniRaw (UTF-16-safe)
    srcData := ReadIniRaw(pf)

    ; Собираем бэкап целиком
    outData := Map()

    ; Мета
    meta := Map()
    meta["id"]           := p["id"]
    meta["label"]        := p["label"]
    meta["name"]         := p["name"]
    meta["organization"] := p["organization"]
    meta["rank"]         := p["rank"]
    meta["backupTime"]   := ts
    outData["Meta"]      := meta

    ; Слоты и категории копируем как есть
    for secName, secData in srcData {
        if (SubStr(secName, 1, 4) = "Slot" || secName = "Categories")
            outData[secName] := secData
    }

    WriteIniRaw(bkFile, outData)
    CleanupOldBackups()
}

CleanupOldBackups(maxCount := 20) {
    global BACKUP_DIR
    if !DirExist(BACKUP_DIR)
        return
    files := []
    Loop Files, BACKUP_DIR "\*.UniBind" {
        files.Push({path: A_LoopFileFullPath, time: A_LoopFileTimeModified})
    }
    if (files.Length <= maxCount)
        return
    n := files.Length
    i := 2
    while (i <= n) {
        key := files[i]
        j := i - 1
        while (j >= 1 && files[j].time > key.time) {
            files[j + 1] := files[j]
            j--
        }
        files[j + 1] := key
        i++
    }
    toDelete := files.Length - maxCount
    Loop toDelete {
        try FileDelete(files[A_Index].path)
    }
}

; ============================================
;  ИНДЕКС ПРОФИЛЕЙ (settings.ini)
; ============================================
SaveProfilesToIni(profilesValue := 0, activeValue := 0) {
    global PROFILES, ACTIVE_PROFILE_IDX, CONFIG_FILE, NEXT_PROFILE_ID
    profiles := IsObject(profilesValue) ? profilesValue : PROFILES
    active := activeValue ? activeValue : ACTIVE_PROFILE_IDX
    data := ReadIniRaw(CONFIG_FILE)
    index := Map("count", profiles.Length, "active", active)
    maxId := 0
    for i, profile in profiles {
        maxId := Max(maxId, profile["id"])
        index["profile" i "_id"] := profile["id"]
        for pair in [["label", "label"], ["name", "name"], ["hospital", "organization"], ["rank", "rank"]]
            index["profile" i "_" pair[1]] := profile[pair[2]]
    }
    index["nextId"] := maxId + 1
    data["Profiles"] := index
    if (active >= 1 && active <= profiles.Length) {
        if !data.Has("Settings")
            data["Settings"] := Map()
        if !data.Has("Profile")
            data["Profile"] := Map()
        data["Settings"]["myName"] := profiles[active]["name"]
        data["Profile"]["organization"] := profiles[active]["organization"]
        data["Profile"]["rank"] := profiles[active]["rank"]
    }
    WriteIniRaw(CONFIG_FILE, data)
    NEXT_PROFILE_ID := maxId + 1
}

; ============================================================
; УНИВЕРСАЛЬНЫЙ ЧТЕНИЕ/ЗАПИСЬ INI ЧЕРЕЗ FILE API
; Не использует Windows INI-кэш → нет проблемы «затёртых» секций.
; Пишем в UTF-16 (Windows INI-API читает такие файлы корректно).
; ============================================================

ReadIniRaw(path) {
    result := Map()
    if !FileExist(path)
        return result

    enc := "CP0"
    f := FileOpen(path, "r")
    if !IsObject(f)
        throw Error("Не удалось прочитать INI: " path)
    try {
        f.Pos := 0
        header := Buffer(3, 0)
        size := f.RawRead(header, 3)
        if (size >= 2 && NumGet(header, 0, "UShort") = 0xFEFF)
            enc := "UTF-16"
        else if (size >= 3 && NumGet(header, 0, "UChar") = 0xEF && NumGet(header, 1, "UChar") = 0xBB && NumGet(header, 2, "UChar") = 0xBF)
            enc := "UTF-8"
    } finally {
        f.Close()
    }
    content := FileRead(path, enc)
    if (SubStr(content, 1, 1) = Chr(0xFEFF))
        content := SubStr(content, 2)

    curSec := ""
    for line in StrSplit(content, "`n", "`r") {
        t := Trim(line, " `t`r`n")
        if (t = "" || SubStr(t, 1, 1) = ";")
            continue
        if (SubStr(t, 1, 1) = "[") {
            endPos := InStr(t, "]")
            if (endPos > 0) {
                curSec := SubStr(t, 2, endPos - 2)
                if !result.Has(curSec)
                    result[curSec] := Map()
            }
            continue
        }
        if (curSec = "")
            continue
        eqPos := InStr(line, "=")
        if (eqPos < 2)
            continue
        k := Trim(SubStr(line, 1, eqPos - 1))
        v := SubStr(line, eqPos + 1)
        if (k != "")
            result[curSec][k] := v
    }

    return result
}

WriteIniRaw(path, data) {
    out := ""
    for secName, secData in data {
        if (secName = "" || RegExMatch(secName, "[\[\]\r\n]"))
            throw ValueError("Некорректное имя секции INI")
        out .= "[" secName "]`r`n"
        for k, v in secData {
            if (k = "" || RegExMatch(k, "[=\r\n]") || RegExMatch(v, "[\x00-\x1F]"))
                throw ValueError("Недопустимый ключ или значение INI")
            out .= k "=" v "`r`n"
        }
        out .= "`r`n"
    }
    ; Сначала полностью записываем временный файл в том же каталоге.
    ; При ошибке исходный INI не удаляется, а исключение доходит до вызывающего кода.
    temp := path ".tmp." DllCall("kernel32\GetCurrentProcessId", "UInt") "." A_TickCount
    try {
        f := FileOpen(temp, "w", "UTF-16")
        if !IsObject(f)
            throw Error("Не удалось открыть временный INI: " temp)
        try {
            f.Write(out)
        } finally {
            f.Close()
        }
        if !(FileRead(temp, "UTF-16") == out)
            throw Error("Проверка временного INI не пройдена: " path)
        if !DllCall("kernel32\MoveFileExW", "Str", temp, "Str", path, "UInt", 0x9, "Int")
            throw OSError(A_LastError, "WriteIniRaw", "Не удалось заменить " path)
    } catch as err {
        try FileDelete(temp)
        LogLine("WriteIniRaw: " err.Message)
        throw err
    }
}

IniSetSafe(path, sec, key, value) {
    data := ReadIniRaw(path)
    if !data.Has(sec)
        data[sec] := Map()
    data[sec][key] := value
    WriteIniRaw(path, data)
}

IniDeleteSafe(path, sec) {
    data := ReadIniRaw(path)
    if data.Has(sec)
        data.Delete(sec)
    WriteIniRaw(path, data)
}

IniDeleteKeySafe(path, sec, key) {
    data := ReadIniRaw(path)
    if data.Has(sec) && data[sec].Has(key)
        data[sec].Delete(key)
    WriteIniRaw(path, data)
}


SwitchProfile(idx) {
    global PROFILES, ACTIVE_PROFILE_IDX, OVERLAY_INDEX, SEND_BUSY
    if (idx < 1 || idx > PROFILES.Length || idx = ACTIVE_PROFILE_IDX)
        return
    if SEND_BUSY
        throw Error("Остановите отправку перед переключением профиля")
    SaveActiveProfileToIni()
    SaveProfilesToIni(PROFILES, idx)
    ACTIVE_PROFILE_IDX := idx
    OVERLAY_INDEX := 1
    ApplyProfileToState(idx)
    LoadActiveProfileFromIni()
    RegisterAllHotkeys()
    PushDataToHtml()
    SendNotify("👤 " PROFILES[idx]["label"], "info")
}

ListProfileBackups() {
    global BACKUP_DIR, wv
    if !DirExist(BACKUP_DIR) {
        try wv.PostWebMessageAsString('profile_backups:[]')
        return
    }
    files := []
    Loop Files, BACKUP_DIR "\*" {
        if !RegExMatch(A_LoopFileName, "i)\.(UniBind|medbind)$")
            continue
        bkData := ReadIniRaw(A_LoopFileFullPath)
        if (bkData.Has("Meta") && bkData["Meta"].Has("formatVersion"))
            continue ; a complete export is imported, not restored as one profile
        label := "Без названия"
        btime := ""
        if bkData.Has("Meta") {
            m := bkData["Meta"]
            if m.Has("label") && m["label"] != ""
                label := m["label"]
            if m.Has("backupTime")
                btime := m["backupTime"]
        }
        files.Push(Map(
            "file", A_LoopFileName,
            "label", label,
            "time", btime,
            "mtime", A_LoopFileTimeModified
        ))
    }
    n := files.Length
    i := 2
    while (i <= n) {
        key := files[i]
        j := i - 1
        while (j >= 1 && files[j]["mtime"] < key["mtime"]) {
            files[j + 1] := files[j]
            j--
        }
        files[j + 1] := key
        i++
    }

    s := "profile_backups:["
    first := true
    for f in files {
        if (!first)
            s .= ","
        first := false
        s .= '{"file":"' EscapeJson(f["file"]) '","label":"' EscapeJson(f["label"]) '","time":"' EscapeJson(f["time"]) '"}'
    }
    s .= "]"
    try wv.PostWebMessageAsString(s)
}

RestoreProfileBackup(filename) {
    global CONFIG_FILE, BACKUP_DIR, PROFILES, ACTIVE_PROFILE_IDX, NEXT_PROFILE_ID, wv

    if (filename = "")
        return
    ; Только имя файла бэкапа: без путей, дисков (C:), потоков (:ads) и без чужих расширений.
    if !RegExMatch(filename, 'i)^[^\\/:*?"<>|\x00-\x1F]{1,200}\.(UniBind|medbind)$') {
        SendNotify("Некорректное имя файла", "error")
        return
    }
    filePath := BACKUP_DIR "\" filename
    if !FileExist(filePath) {
        SendNotify("Файл бэкапа не найден", "error")
        return
    }

    if SEND_BUSY
        throw Error("Остановите отправку перед восстановлением")
    SaveActiveProfileToIni()

    if (PROFILES.Length >= 50)
        throw ValueError("Максимум 50 профилей")
    newId := AllocateProfileId()

    ; Читаем бэкап целиком через ReadIniRaw
    bkData := ReadIniRaw(filePath)
    if (bkData.Has("Meta") && bkData["Meta"].Has("formatVersion")) {
        SendNotify("Полный экспорт загружается через Конфигурация → Импорт", "warning")
        return
    }
    if !bkData.Has("Categories") && !bkData.Has("Slot1") {
        hasSlot := false
        for section in bkData {
            if RegExMatch(section, "^Slot\d+$")
                hasSlot := true
        }
        if !hasSlot {
            SendNotify("Файл не содержит данных профиля", "error")
            return
        }
    }

    ; Мета
    label := "Восстановленный"
    name_ := ""
    org_  := ""
    rank_ := ""
    if bkData.Has("Meta") {
        m := bkData["Meta"]
        label := m.Has("label")        ? m["label"]        : label
        name_ := m.Has("name")         ? m["name"]         : ""
        org_  := m.Has("organization") ? m["organization"] : (m.Has("hospital") ? m["hospital"] : "")
        rank_ := m.Has("rank")         ? m["rank"]         : ""
    }

    ; Метаданные из файла — недоверенный ввод: убираем управляющие символы и режем длину.
    label := SubStr(Trim(RegExReplace(label, "[\x00-\x1F]")), 1, 256)
    if (label = "")
        label := "Восстановленный"
    name_ := SubStr(Trim(RegExReplace(name_, "[\x00-\x1F]")), 1, 256)
    org_  := SubStr(Trim(RegExReplace(org_,  "[\x00-\x1F]")), 1, 256)
    rank_ := SubStr(Trim(RegExReplace(rank_, "[\x00-\x1F]")), 1, 256)

    p := Map(
        "id",           newId,
        "label",        label,
        "name",         name_,
        "organization", org_,
        "rank",         rank_
    )

    ; Собираем новый профиль — только слоты и категории (без Meta)
    outData := Map()
    for secName, secData in bkData {
        if (SubStr(secName, 1, 4) = "Slot" || secName = "Categories")
            outData[secName] := secData
    }

    validation := Map("Settings", Map("chatKey", "t"), "Meta", Map("formatVersion", "2027.2", "profileCount", 1),
        "Profiles", Map("profile1_id", newId))
    for sec, values in outData
        validation["P1_" sec] := values
    problem := ValidateImportData(validation)
    if (problem != "")
        throw ValueError("Резервная копия не прошла проверку: " problem)
    newProfileFile := ProfilePathById(newId)
    try WriteIniRaw(newProfileFile, outData)
    catch as err {
        SendNotify("Не удалось записать восстановленный профиль: " err.Message, "error")
        return
    }
    nextProfiles := PROFILES.Clone()
    nextProfiles.Push(p)
    try SaveProfilesToIni(nextProfiles, nextProfiles.Length)
    catch as err {
        try FileDelete(newProfileFile)
        throw err
    }
    PROFILES := nextProfiles
    ACTIVE_PROFILE_IDX := PROFILES.Length
    ApplyProfileToState(ACTIVE_PROFILE_IDX)
    LoadActiveProfileFromIni()
    RegisterAllHotkeys()
    PushDataToHtml()

    SendNotify("✓ Восстановлен профиль: " label, "success")
}

HandleDeleteProfile(idx) {
    global PROFILES, ACTIVE_PROFILE_IDX, CONFIG_FILE, SEND_BUSY
    if (idx < 1 || idx > PROFILES.Length || PROFILES.Length <= 1)
        return
    if SEND_BUSY
        throw Error("Остановите отправку перед удалением профиля")
    SaveActiveProfileToIni()
    BackupProfileData(idx)
    file := ProfilePath(idx)
    nextProfiles := PROFILES.Clone()
    nextProfiles.RemoveAt(idx)
    active := ACTIVE_PROFILE_IDX
    if (idx < active)
        active -= 1
    else if (idx = active)
        active := Min(idx, nextProfiles.Length)
    SaveProfilesToIni(nextProfiles, active)
    PROFILES := nextProfiles
    ACTIVE_PROFILE_IDX := active
    if FileExist(file) {
        try FileDelete(file)
        catch as err
            LogLine("Orphan profile retained after delete: " err.Message)
    }
    ApplyProfileToState(active)
    LoadActiveProfileFromIni()
    RegisterAllHotkeys()
    PushDataToHtml()
    SendNotify("Профиль удалён; резервная копия сохранена", "success")
}

NextSortOrder() {
    global SLOTS
    maxO := 0
    Loop 100 {
        if (SLOTS[A_Index]["name"] != "" && SLOTS[A_Index].Has("sortOrder"))
            maxO := Max(maxO, SLOTS[A_Index]["sortOrder"])
    }
    return maxO + 1
}

; ============================================
;  МИГРАЦИЯ LEGACY КОНФИГА
; ============================================
CopyIniSection(srcFile, srcSec, dstFile, dstSec) {
    src := ReadIniRaw(srcFile)
    if !src.Has(srcSec)
        return false
    dst := ReadIniRaw(dstFile)
    dst[dstSec] := src[srcSec].Clone()
    WriteIniRaw(dstFile, dst)
    return true
}

MigrateLegacyConfig() {
    global SETTINGS_FILE, LEGACY_CONFIG_FILE, LEGACY_CONFIG_ROOT, PROFILES_DIR

    if (FileExist(SETTINGS_FILE))
        return

    legacyFile := ""
    if FileExist(LEGACY_CONFIG_ROOT)
        legacyFile := LEGACY_CONFIG_ROOT
    else if FileExist(LEGACY_CONFIG_FILE)
        legacyFile := LEGACY_CONFIG_FILE
    else
        return

    LogLine("Миграция legacy конфига: " legacyFile)

    ; Глобальные секции
    for sec in ["Settings", "Profile", "Overlay", "Variables", "Stats", "Profiles"]
        CopyIniSection(legacyFile, sec, SETTINGS_FILE, sec)

    profCount := Integer(IniRead(legacyFile, "Profiles", "count", 0))

    if (profCount = 0) {
        ; Совсем старая версия — один профиль из [Slot*], [Categories]
        newId := 1
        IniWrite(1, SETTINGS_FILE, "Profiles", "count")
        IniWrite(1, SETTINGS_FILE, "Profiles", "active")
        IniWrite(2, SETTINGS_FILE, "Profiles", "nextId")
        IniWrite(newId, SETTINGS_FILE, "Profiles", "profile1_id")
        IniWrite("Основной", SETTINGS_FILE, "Profiles", "profile1_label")
        IniWrite(IniRead(legacyFile, "Settings", "myName", ""), SETTINGS_FILE, "Profiles", "profile1_name")
        IniWrite(IniRead(legacyFile, "Profile", "organization", ""), SETTINGS_FILE, "Profiles", "profile1_hospital")
        IniWrite(IniRead(legacyFile, "Profile", "rank", ""), SETTINGS_FILE, "Profiles", "profile1_rank")

        pFile := PROFILES_DIR "\P" newId ".ini"
        Loop 100
            CopyIniSection(legacyFile, "Slot" A_Index, pFile, "Slot" A_Index)
        CopyIniSection(legacyFile, "Categories", pFile, "Categories")
    } else {
        Loop profCount {
            i := A_Index
            pid := Integer(IniRead(legacyFile, "Profiles", "profile" i "_id", i))
            if (pid <= 0)
                pid := i
            pFile := PROFILES_DIR "\P" pid ".ini"
            pfx := "P" pid "_"
            Loop 100
                CopyIniSection(legacyFile, pfx "Slot" A_Index, pFile, "Slot" A_Index)
            CopyIniSection(legacyFile, pfx "Categories", pFile, "Categories")
        }
    }

    try FileCopy(legacyFile, legacyFile ".migrated", 1)
    LogLine("Миграция завершена")
}

; ============================================
;  БИНДЫ
; ============================================
HandleCreateBind() {
    global SLOTS, wv
    Loop 100 {
        if (SLOTS[A_Index]["name"] = "") {
            id := A_Index
            candidate := Map("name", "Новый бинд", "enabled", true, "hotkey", "",
                "category", "Основные", "statType", "", "showInOverlay", true,
                "lines", [Map("text", "Первая строка", "delay", 2300)], "sortOrder", NextSortOrder())
            CommitSlot(id, candidate)
            PushDataToHtml()
            try wv.PostWebMessageAsString("open_editor:" id)
            SendNotify("Создан слот " id, "success")
            return
        }
    }
    SendNotify("Нет свободных слотов!", "warning")
}

HandleDeleteBind(id) {
    global SLOTS
    if (id < 1 || id > 100) || SLOTS[id]["name"] = ""
        return
    candidate := Map("name", "", "hotkey", "", "enabled", false, "category", "",
        "statType", "", "lines", [], "showInOverlay", true, "sortOrder", id)
    CommitSlot(id, candidate)
    RegisterAllHotkeys()
    PushDataToHtml()
    SendNotify("Бинд удалён", "success")
}

HandleCopyBind(id) {
    global SLOTS
    if (id < 1 || id > 100) || SLOTS[id]["name"] = ""
        return
    Loop 100 {
        if (SLOTS[A_Index]["name"] = "") {
            candidate := SLOTS[id].Clone()
            candidate["name"] := SubStr(candidate["name"], 1, 248) " (копия)"
            candidate["hotkey"] := ""
            candidate["lines"] := []
            for line in SLOTS[id]["lines"]
                candidate["lines"].Push(line.Clone())
            candidate["sortOrder"] := NextSortOrder()
            CommitSlot(A_Index, candidate)
            RegisterAllHotkeys()
            PushDataToHtml()
            SendNotify("Бинд скопирован", "success")
            return
        }
    }
    SendNotify("Нет свободных слотов!", "warning")
}

CheckHotkeyConflict(hotkey, excludeBindId := 0, checkUtility := true) {
    global SLOTS, CFG
    if (hotkey = "")
        return ""
    vErr := ValidateHotkeyString(hotkey)
    if (vErr != "")
        return "клавиша не поддерживается: " vErr
    Loop 100 {
        if (A_Index = excludeBindId)
            continue
        slot := SLOTS[A_Index]
        if (slot["name"] != "" && slot["hotkey"] = hotkey)
            return hotkey " уже используется биндом «" slot["name"] "»"
    }
    if !checkUtility
        return ""
    if (CFG["overlayHotkey"] != "" && CFG["overlayHotkey"] = hotkey)
        return hotkey " уже используется как клавиша Overlay"
    if (CFG["stopHotkey"] != "" && CFG["stopHotkey"] = hotkey)
        return hotkey " уже используется как клавиша СТОП"
    if (CFG["idInputHotkey"] != "" && CFG["idInputHotkey"] = hotkey)
        return hotkey " уже используется как клавиша ввода ID"
    if (CFG.Has("overlayModeHotkey") && CFG["overlayModeHotkey"] != "" && CFG["overlayModeHotkey"] = hotkey)
        return hotkey " уже используется как клавиша режима Overlay"
    return ""
}


; Strict validation shared by the UI protocol and backup validator.
RequireInt(value, low, high, label) {
    text := "" value
    if !RegExMatch(text, "^-?\d{1,15}$")
        throw ValueError(label ": требуется целое число")
    number := Integer(text)
    if (number < low || number > high)
        throw ValueError(label ": допустимо " low "…" high)
    return number
}

RequireText(value, label, maxLength := 4096) {
    if (StrLen(value) > maxLength || RegExMatch(value, "[\x00-\x1F]"))
        throw ValueError(label ": превышена длина или есть управляющие символы")
    return value
}

IniValue(data, section, key, default := "") {
    return data.Has(section) && data[section].Has(key) ? data[section][key] : default
}

SlotIniData(slot) {
    data := Map()
    for key in ["name", "hotkey", "sortOrder", "category", "statType"]
        data[key] := slot[key]
    data["enabled"] := slot["enabled"] ? 1 : 0
    data["showInOverlay"] := slot["showInOverlay"] ? 1 : 0
    data["lineCount"] := slot["lines"].Length
    for i, line in slot["lines"] {
        data["line" i "_text"] := line["text"]
        data["line" i "_delay"] := line["delay"]
    }
    return data
}

CommitSlot(id, candidate) {
    global SLOTS
    ; Do not expose an uncommitted edit to an already registered hotkey.
    Critical("On")
    try {
        SaveBindToIni(id, candidate)
        SLOTS[id] := candidate
    } finally {
        Critical("Off")
    }
}

HandleSaveBind(msg) {
    global SLOTS, wv
    try {
        parts := SplitUiFields(msg)
        if (parts.Length < 9)
            throw ValueError("Неполная команда сохранения")
        id := RequireInt(parts[2], 1, 100, "Номер бинда")
        count := RequireInt(parts[8], 1, 100, "Число строк")
        if (parts.Length != 9 + count * 2)
            throw ValueError("Число строк не соответствует сообщению")
        name := RequireText(parts[3], "Название", 256)
        if (Trim(name) = "")
            throw ValueError("Введите название бинда")
        hk := RequireText(parts[4], "Горячая клавиша", 128)
        conflict := CheckHotkeyConflict(hk, id)
        if (conflict != "")
            throw ValueError("Конфликт: " conflict)
        ; Check the actual AHK key, not just the spelling of its name.
        if (hk != "" && !GetKeyVK(RegExReplace(hk, "^[\^!+#]+")) && !GetKeySC(RegExReplace(hk, "^[\^!+#]+"))) {
            if !RegExMatch(hk, "i)(LButton|RButton|MButton|XButton[12]|Wheel(Up|Down|Left|Right))$")
                throw ValueError("Неизвестная горячая клавиша")
        }
        candidate := SLOTS[id].Clone()
        candidate["name"] := name
        candidate["hotkey"] := hk
        candidate["category"] := RequireText(parts[5], "Категория", 256)
        candidate["enabled"] := RequireInt(parts[6], 0, 1, "Включение") = 1
        candidate["statType"] := RequireText(parts[7], "Счётчик", 128)
        candidate["showInOverlay"] := RequireInt(parts[9], 0, 1, "Показ в оверлее") = 1
        candidate["lines"] := []
        Loop count {
            pos := 10 + (A_Index - 1) * 2
            text := RequireText(parts[pos], "Текст строки " A_Index)
            if (text = "")
                throw ValueError("Строка " A_Index " пуста: заполните или удалите её")
            delay := RequireInt(parts[pos + 1], 0, 120000, "Задержка строки " A_Index)
            candidate["lines"].Push(Map("text", text, "delay", delay))
        }
        CommitSlot(id, candidate)
    } catch as err {
        LogLine("Save bind failed: " err.Message)
        SendNotify("Бинд не сохранён: " err.Message, "error")
        try wv.PostWebMessageAsString("bind_error:" err.Message)
        return
    }
    RegisterAllHotkeys()
    PushDataToHtml()
    SendNotify("✓ Сохранено: " candidate["name"], "success")
    try wv.PostWebMessageAsString("bind_saved:" id)
}

HandleReorderBinds(data) {
    global SLOTS, OVERLAY_VISIBLE
    if (data = "")
        return
    nextSlots := SLOTS.Clone()
    seen := Map()
    order := 0
    for text in StrSplit(data, ",") {
        id := RequireInt(text, 1, 100, "Номер бинда")
        if seen.Has(id)
            throw ValueError("Повтор номера в порядке биндов")
        seen[id] := true
        if (SLOTS[id]["name"] = "")
            continue
        order++
        nextSlots[id] := SLOTS[id].Clone()
        nextSlots[id]["sortOrder"] := order
    }
    SaveActiveProfileToIni(nextSlots)
    SLOTS := nextSlots
    PushDataToHtml()
}

; ============================================
;  КАТЕГОРИИ
; ============================================
HandleSaveCategories(msg) {
    global CATEGORIES, SLOTS, wv
    parts := SplitUiFields(msg)
    if (parts.Length < 2)
        throw ValueError("Неполные категории")
    count := RequireInt(parts[2], 0, 50, "Число категорий")
    if (parts.Length != 2 + count * 2)
        throw ValueError("Неполные категории")
    cats := [], names := Map()
    Loop count {
        pos := 3 + (A_Index - 1) * 2
        name := RequireText(parts[pos], "Название категории", 256)
        if (Trim(name) = "" || names.Has(name))
            throw ValueError("Пустое или повторное название категории")
        icon := RequireText(parts[pos + 1], "Иконка", 128)
        names[name] := true
        cats.Push(Map("name", name, "icon", icon))
    }
    nextSlots := SLOTS.Clone()
    for i, slot in SLOTS {
        if (slot["category"] != "" && !names.Has(slot["category"])) {
            nextSlots[i] := slot.Clone()
            nextSlots[i]["category"] := ""
        }
    }
    SaveActiveProfileToIni(nextSlots, cats)
    SLOTS := nextSlots
    CATEGORIES := cats
    PushDataToHtml()
    SendNotify("✓ Категории сохранены", "success")
    try wv.PostWebMessageAsString("categories_saved")
}

SaveCategoriesToIni() {
    global CATEGORIES, ACTIVE_PROFILE_IDX
    pf := ProfilePath(ACTIVE_PROFILE_IDX)
    if (pf = "")
        return
    data := ReadIniRaw(pf)
    data["Categories"] := Map()
    data["Categories"]["count"] := CATEGORIES.Length
    i := 0
    for cat in CATEGORIES {
        i++
        data["Categories"]["cat" i "_name"] := cat["name"]
        data["Categories"]["cat" i "_icon"] := cat.Has("icon") ? cat["icon"] : ""
    }
    WriteIniRaw(pf, data)
}

MigrateCategoriesFromBinds() {
    global CATEGORIES, SLOTS
    LogLine("MCB: start, текущих CATEGORIES=" CATEGORIES.Length)

    seen := Map()
    result := []
    Loop 100 {
        c := Trim(SLOTS[A_Index]["category"])
        if (c != "" && !seen.Has(c)) {
            seen[c] := true
            result.Push(c)
        }
    }
    LogLine("MCB: нашли " result.Length " категорий в слотах")

    known := Map()
    for cat in CATEGORIES
        known[cat["name"]] := true

    defaultIcons := Map(
        "Приветствие", "fa-comment",
        "RP-действия", "fa-user",
        "Основное",    "fa-star",
        "Прочее",      "fa-folder",
        "Быстрые",     "fa-bolt",
        "Утилиты",     "fa-wrench"
    )

    for name in result {
        if known.Has(name)
            continue
        icon := defaultIcons.Has(name) ? defaultIcons[name] : "fa-folder"
        CATEGORIES.Push(Map("name", name, "icon", icon))
        known[name] := true
    }

    LogLine("MCB: итог CATEGORIES=" CATEGORIES.Length)
    if (CATEGORIES.Length > 0) {
        SaveCategoriesToIni()
        LogLine("MCB: сохранили в INI")
    }
}

; ============================================
;  ПЕРЕМЕННЫЕ / ПРОФИЛЬ / НАСТРОЙКИ
; ============================================
HandleSaveVars(msg) {
    global STATE, CONFIG_FILE, wv
    parts := SplitUiFields(msg)
    if (parts.Length < 2)
        throw ValueError("Неполные переменные")
    count := RequireInt(parts[2], 0, 200, "Число переменных")
    if (parts.Length != 2 + count * 2)
        throw ValueError("Неполные переменные")
    variables := Map(), section := Map("count", count)
    Loop count {
        pos := 3 + (A_Index - 1) * 2
        name := RequireText(parts[pos], "Имя переменной", 128)
        value := RequireText(parts[pos + 1], "Значение переменной")
        if (name = "" || IsReservedVar(name) || variables.Has(name))
            throw ValueError("Пустая, зарезервированная или повторная переменная")
        if !RegExMatch(name, "^[A-Za-zА-Яа-яЁё0-9_]+$")
            throw ValueError("Имя переменной: буквы, цифры и подчёркивание")
        variables[name] := value
        section["var" A_Index "_name"] := name
        section["var" A_Index "_value"] := value
    }
    data := ReadIniRaw(CONFIG_FILE)
    data["Variables"] := section
    WriteIniRaw(CONFIG_FILE, data)
    STATE["variables"] := variables
    PushDataToHtml()
    SendNotify("✓ Переменные сохранены", "success")
    try wv.PostWebMessageAsString("vars_saved")
}

IsReservedVar(name) {
    for r in ["T", "MY", "ORG", "RANK"]
        if (StrUpper(name) = r)
            return true
    return false
}

HandleSaveProfile(msg) {
    global PROFILES, ACTIVE_PROFILE_IDX, NEXT_PROFILE_ID, wv, SEND_BUSY
    if SEND_BUSY
        throw Error("Остановите отправку перед изменением профиля")
    parts := SplitUiFields(msg)
    if (parts.Length != 7)
        throw ValueError("Неполные данные профиля")
    idx := RequireInt(parts[2], 0, PROFILES.Length, "Номер профиля")
    label := Trim(RequireText(parts[3], "Название профиля", 256))
    name := Trim(RequireText(parts[4], "Имя", 256))
    org := Trim(RequireText(parts[5], "Организация", 256))
    rank := Trim(RequireText(parts[6], "Ранг", 256))
    copyFrom := RequireInt(parts[7], 0, PROFILES.Length, "Копировать из")
    if (label = "")
        label := name != "" ? name : "Профиль"
    SaveActiveProfileToIni()
    nextProfiles := PROFILES.Clone()
    if (idx = 0) {
        if (PROFILES.Length >= 50)
            throw ValueError("Максимум 50 профилей")
        id := AllocateProfileId()
        profileData := Map("Categories", Map("count", 0))
        if copyFrom {
            source := ProfilePath(copyFrom)
            if !FileExist(source)
                throw Error("Файл исходного профиля отсутствует")
            profileData := ReadIniRaw(source)
        }
        nextProfiles.Push(Map("id", id, "label", label, "name", name, "organization", org, "rank", rank))
        idx := nextProfiles.Length
        file := ProfilePathById(id)
        WriteIniRaw(file, profileData)
        try SaveProfilesToIni(nextProfiles, idx)
        catch as err {
            try FileDelete(file)
            throw err
        }
    } else {
        candidate := PROFILES[idx].Clone()
        candidate["label"] := label
        candidate["name"] := name
        candidate["organization"] := org
        candidate["rank"] := rank
        nextProfiles[idx] := candidate
        SaveProfilesToIni(nextProfiles, idx)
    }
    PROFILES := nextProfiles
    ACTIVE_PROFILE_IDX := idx
    ApplyProfileToState(idx)
    LoadActiveProfileFromIni()
    RegisterAllHotkeys()
    PushDataToHtml()
    SendNotify("✓ Профиль сохранён", "success")
    try wv.PostWebMessageAsString("profile_saved")
}

AllocateProfileId() {
    global PROFILES, PROFILES_DIR
    used := Map()
    for profile in PROFILES
        used[profile["id"]] := true
    Loop 1000 {
        if !used.Has(A_Index) && !FileExist(PROFILES_DIR "\P" A_Index ".ini")
            return A_Index
    }
    throw Error("Не осталось свободных ID профиля")
}

HandleSaveSettings(msg) {
    global CFG, CONFIG_FILE, wv
    try {
        parts := SplitUiFields(msg)
        if (parts.Length != 8)
            throw ValueError("Неполные настройки")
        candidate := CFG.Clone()
        if !RegExMatch(parts[2], "^[A-Za-z0-9]$")
            throw ValueError("Клавиша чата: одна латинская буква или цифра")
        candidate["chatKey"] := parts[2]
        candidate["baseDelay"] := RequireInt(parts[3], 0, 60000, "Между сообщениями")
        candidate["afterChatDelay"] := RequireInt(parts[4], 0, 10000, "Открытие чата")
        candidate["afterEnterDelay"] := RequireInt(parts[5], 0, 10000, "После Enter")
        if (parts[6] != "plain" && parts[6] != "at" && parts[6] != "quote")
            throw ValueError("Неизвестный формат цели")
        candidate["patientFormat"] := parts[6]
        candidate["onlyGTA"] := RequireInt(parts[7], 0, 1, "Только GTA") = 1
        candidate["jitter"] := RequireInt(parts[8], 0, 10000, "Разброс")
        Critical("On")
        try {
            data := ReadIniRaw(CONFIG_FILE)
            if !data.Has("Settings")
                data["Settings"] := Map()
            for key in ["chatKey", "baseDelay", "afterChatDelay", "afterEnterDelay", "patientFormat", "jitter"]
                data["Settings"][key] := candidate[key]
            data["Settings"]["onlyGTA"] := candidate["onlyGTA"] ? 1 : 0
            WriteIniRaw(CONFIG_FILE, data)
            CFG := candidate
        } finally {
            Critical("Off")
        }
    } catch as err {
        LogLine("Save settings error: " err.Message)
        SendNotify("Настройки не сохранены: " err.Message, "error")
        try wv.PostWebMessageAsString("settings_error:" err.Message)
        return
    }
    RegisterAllHotkeys()
    PushDataToHtml()
    SendNotify("✓ Настройки сохранены", "success")
    try wv.PostWebMessageAsString("settings_saved")
}

HandleSaveOverlaySettings(msg) {
    global CFG, CONFIG_FILE, wv, OverlayGui, OVERLAY_VISIBLE, SLOTS
    US := "|~|"
    parts := SplitUiFields(msg)
    LogLine("SaveOverlaySettings: parts=" parts.Length)
    if (parts.Length < 13)
        return

    newEnabled       := (parts[2] = "1")
    newOverlayHk     := parts[3]
    newStopHk        := parts[4]
    newIdHk          := parts[5]
    newOpacity       := RequireInt(parts[6], 80, 255, "Непрозрачность")
    LogLine("Opacity save: raw=" parts[6] " parsed=" newOpacity)
    newWidth         := SafeInt(parts[7], 260, 260, 600)
    newX             := SafeInt(parts[8], -1)
    newY             := SafeInt(parts[9], 20)
    newShowId        := (parts[10] = "1")
    newPatientFormat := parts[11]
    if (newPatientFormat != "plain" && newPatientFormat != "at" && newPatientFormat != "quote")
        throw ValueError("Некорректный формат цели")
    newMode          := parts[12]
    if (newMode != "mini")
        newMode := "full"
    newModeHk        := parts[13]
    newHints := parts.Length >= 15 ? parts[15] : CFG["overlayHints"]
    if (newHints != "all" && newHints != "full" && newHints != "none")
        newHints := "all"
    
    LogLine("HandleSaveOverlaySettings: modeHk='" newModeHk "' overlayHk='" newOverlayHk "' mode=" newMode)
    
    newHeight := -1
    if (parts.Length >= 14)
        newHeight := SafeInt(parts[14], -1)
    if (newHeight != -1) {
        if (newHeight < 437)
            newHeight := 437
        if (newHeight > 900)
            newHeight := 900
    }

    ; Геометрию ведёт только редактор оверлея — форма настроек её не меняет,
    ; иначе устаревшие X/Y/размер из JS откатывают оверлей в дефолт.
    LogLine("HandleSaveOverlaySettings: form x=" parts[8] " y=" parts[9] " w=" parts[7]
        " | keep x=" CFG["overlayX"] " y=" CFG["overlayY"]
        " w=" CFG["overlayWidth"] " h=" CFG["overlayHeight"])
    newWidth  := CFG["overlayWidth"]
    newHeight := CFG["overlayHeight"]
    newX      := CFG["overlayX"]
    newY      := CFG["overlayY"]

    ; --- 1. Валидация формата хоткеев ---
    for pair in [["Overlay", newOverlayHk], ["СТОП", newStopHk], ["ID", newIdHk], ["Режим", newModeHk]] {
        lbl := pair[1], hk := pair[2]
        if (hk = "")
            continue
        vErr := ValidateHotkeyString(hk)
        if (vErr != "") {
            SendNotify(lbl ": " vErr, "error")
            try wv.PostWebMessageAsString("overlay_settings_error:" lbl ": " vErr)
            return
        }
    }

    ; --- 2. Конфликты со слотами биндов ---
    conflicts := []
    Loop 100 {
        slot := SLOTS[A_Index]
        if (slot["name"] = "" || slot["hotkey"] = "")
            continue
        hk := slot["hotkey"]
        if (newOverlayHk != "" && hk = newOverlayHk)
            conflicts.Push("Overlay: " hk " уже занято биндом «" slot["name"] "»")
        if (newStopHk != "" && hk = newStopHk)
            conflicts.Push("СТОП: " hk " уже занято биндом «" slot["name"] "»")
        if (newIdHk != "" && hk = newIdHk)
            conflicts.Push("ID: " hk " уже занято биндом «" slot["name"] "»")
        if (newModeHk != "" && hk = newModeHk)
            conflicts.Push("Режим: " hk " уже занято биндом «" slot["name"] "»")
    }
    if (newOverlayHk != "" && newOverlayHk = newStopHk)
        conflicts.Push("Overlay и СТОП используют одну клавишу: " newOverlayHk)
    if (newOverlayHk != "" && newOverlayHk = newIdHk)
        conflicts.Push("Overlay и ввод ID используют одну клавишу: " newOverlayHk)
    if (newOverlayHk != "" && newOverlayHk = newModeHk)
        conflicts.Push("Overlay и Режим используют одну клавишу: " newOverlayHk)
    if (newStopHk != "" && newStopHk = newIdHk)
        conflicts.Push("СТОП и ввод ID используют одну клавишу: " newStopHk)
    if (newStopHk != "" && newStopHk = newModeHk)
        conflicts.Push("СТОП и Режим используют одну клавишу: " newStopHk)
    if (newIdHk != "" && newIdHk = newModeHk)
        conflicts.Push("ID и Режим используют одну клавишу: " newIdHk)

    if (conflicts.Length > 0) {
        SendNotify("Конфликт: " conflicts[1], "error")
        try wv.PostWebMessageAsString("overlay_settings_error:" conflicts[1])
        return
    }

    ; --- 3. Снимок старого CFG и INI ---
    oldCfg := SnapshotOverlayCfg()
    iniBak := CONFIG_FILE ".pre_save"
    hadIni := FileExist(CONFIG_FILE) ? true : false
    iniSnapshotOK := false
    if hadIni {
        try {
            FileCopy(CONFIG_FILE, iniBak, 1)
            iniSnapshotOK := true
        } catch as err {
            LogLine("HandleSaveOverlaySettings: INI snapshot failed: " err.Message)
            SendNotify("Не удалось создать снимок INI — сохранение отменено", "error")
            try wv.PostWebMessageAsString("overlay_settings_error:Не удалось создать снимок конфига")
            return
        }
    } else {
        iniSnapshotOK := true
    }

    ; --- 4. Снять все старые служебные хоткеи ---
    if !UnregisterUtilityHotkeys() {
        restored := RegisterAllUtilityHotkeys(true)
        LogLine("HandleSaveOverlaySettings: unregister failed; restored=" restored)
        SendNotify("Не удалось снять старые хоткеи — перезапустите UniBind", "error")
        try wv.PostWebMessageAsString("overlay_settings_error:Не удалось снять старые хоткеи")
        return
    }

    ; --- 5. Применить новые значения ---
    CFG["overlayEnabled"]    := newEnabled
    CFG["overlayHotkey"]     := newOverlayHk
    CFG["stopHotkey"]        := newStopHk
    CFG["idInputHotkey"]     := newIdHk
    CFG["overlayOpacity"]    := newOpacity
    CFG["overlayWidth"]      := newWidth
    CFG["overlayHeight"]     := newHeight
    CFG["overlayX"]          := newX
    CFG["overlayY"]          := newY
    CFG["showIdInOverlay"]   := newShowId
    CFG["patientFormat"]     := newPatientFormat
    CFG["overlayMode"]       := newMode
    CFG["overlayModeHotkey"] := newModeHk
    CFG["overlayHints"]      := newHints

    ; --- 6. Зарегистрировать все 4 ---
    if !RegisterAllUtilityHotkeys(true) {
        rbOk := RollbackOverlaySettings(oldCfg, iniBak, iniSnapshotOK, hadIni)
        LogLine("HandleSaveOverlaySettings: rollback after reg failure; rollback_ok=" rbOk)
        PushDataToHtml()
        if rbOk {
            SendNotify("Не удалось применить хоткеи — откат выполнен", "error")
            try wv.PostWebMessageAsString("overlay_settings_error:Не удалось применить настройки хоткеев")
        } else {
            SendNotify("КРИТИЧНО: откат хоткеев не удался — проверьте настройки", "error")
            try wv.PostWebMessageAsString("overlay_settings_error:КРИТИЧНО: откат не удался")
        }
        return
    }

    ; --- 7. Запись INI ---
    iniOk := true
    try {
        data := ReadIniRaw(CONFIG_FILE)
        overlay := Map()
        for pair in [["enabled", "overlayEnabled"], ["hotkey", "overlayHotkey"], ["stopHotkey", "stopHotkey"],
            ["idInputHotkey", "idInputHotkey"], ["opacity", "overlayOpacity"], ["width", "overlayWidth"],
            ["height", "overlayHeight"], ["x", "overlayX"], ["y", "overlayY"], ["showId", "showIdInOverlay"],
            ["mode", "overlayMode"], ["modeHotkey", "overlayModeHotkey"], ["hints", "overlayHints"]]
            overlay[pair[1]] := CFG[pair[2]]
        data["Overlay"] := overlay
        if !data.Has("Settings")
            data["Settings"] := Map()
        data["Settings"]["patientFormat"] := CFG["patientFormat"]
        WriteIniRaw(CONFIG_FILE, data)
    } catch as err {
        iniOk := false
        LogLine("Save overlay settings error: " err.Message)
    }

    if !iniOk {
        rbOk := RollbackOverlaySettings(oldCfg, iniBak, iniSnapshotOK, hadIni)
        LogLine("HandleSaveOverlaySettings: rollback after INI failure; rollback_ok=" rbOk)
        PushDataToHtml()
        if rbOk {
            SendNotify("Ошибка записи настроек — откат выполнен", "error")
            try wv.PostWebMessageAsString("overlay_settings_error:Не удалось записать INI")
        } else {
            SendNotify("КРИТИЧНО: откат хоткеев не удался", "error")
            try wv.PostWebMessageAsString("overlay_settings_error:КРИТИЧНО: откат не удался")
        }
        if (iniSnapshotOK && rbOk)
            try FileDelete(iniBak)
        return
    }

    ; --- 8. Успех ---
    ClearOverlayOpacityPreview()
    LogLine("Overlay opacity saved: " CFG["overlayOpacity"])
    if iniSnapshotOK
        try FileDelete(iniBak)

    ; Пересоздаём оверлей, если он виден — чтобы применить новые размеры/координаты
    if !CFG["overlayEnabled"] && OVERLAY_VISIBLE
        HideOverlay()
    else if IsObject(OverlayGui) && OVERLAY_VISIBLE
        ShowOverlay()

    PushDataToHtml()
    SendNotify("✓ Настройки Overlay сохранены", "success")
    LogLine("Sending overlay_settings_saved")
    try {
        wv.PostWebMessageAsString("overlay_settings_saved")
        LogLine("overlay_settings_saved sent successfully")
    } catch as err {
        LogLine("Failed to send overlay_settings_saved: " err.Message)
    }
} 

SaveVariablesToIni() {
    global STATE, CONFIG_FILE
    data := ReadIniRaw(CONFIG_FILE)
    data["Variables"] := Map()
    data["Variables"]["count"] := STATE["variables"].Count
    i := 0
    for name, value in STATE["variables"] {
        i++
        data["Variables"]["var" i "_name"] := name
        data["Variables"]["var" i "_value"] := value
    }
    WriteIniRaw(CONFIG_FILE, data)
}

SaveBindToIni(slotIdx, candidate := 0) {
    global SLOTS, ACTIVE_PROFILE_IDX
    pf := ProfilePath(ACTIVE_PROFILE_IDX)
    if (pf = "")
        throw Error("Нет активного файла профиля")
    slot := IsObject(candidate) ? candidate : SLOTS[slotIdx]
    data := ReadIniRaw(pf)
    sec := "Slot" slotIdx
    if (slot["name"] = "" && slot["lines"].Length = 0) {
        if data.Has(sec)
            data.Delete(sec)
    } else {
        data[sec] := SlotIniData(slot)
    }
    WriteIniRaw(pf, data)
}

; ============================================
;  СТАТУС / OVERLAY STATE / NOTIFY
; ============================================
SendStatus() {
    global wv, BINDER_ENABLED, IS_SENDING
    if !wv
        return
    try wv.PostWebMessageAsString("status:binder=" (BINDER_ENABLED ? "1" : "0") ";sending=" (IS_SENDING ? "1" : "0"))
}

SendOverlayState() {
    global wv, OVERLAY_VISIBLE
    SendOverlayNavigationState(true)
    if !wv
        return
    try wv.PostWebMessageAsString("overlay_visible:" (OVERLAY_VISIBLE ? "1" : "0"))
}

SendNotify(text, type := "info") {
    global wv
    if !wv
        return
    try {
        t := EscapeJson(text)
        wv.PostWebMessageAsString('notify:{"text":"' t '","type":"' type '"}')
    }
}

; ============================================
;  ЗАХВАТ ХОТКЕЯ
; ============================================
StartHotkeyCapture() {
    global HK_INPUT, HK_MODS
    StopHotkeyCapture()
    HK_MODS := Map("ctrl", false, "alt", false, "shift", false, "win", false)
        HK_INPUT := InputHook("L0")
    HK_INPUT.KeyOpt("{All}", "NS")
    HK_INPUT.OnKeyDown := HotkeyCaptureKeyDown
    HK_INPUT.OnKeyUp := HotkeyCaptureKeyUp
    HK_INPUT.Start()
    SendHotkeyCaptureMods()
}
StartOverlayHotkeyCapture() {
    global HK_INPUT, HK_MODS
    StopHotkeyCapture()
    HK_MODS := Map("ctrl", false, "alt", false, "shift", false, "win", false)
        HK_INPUT := InputHook("L0")
    HK_INPUT.KeyOpt("{All}", "NS")
    HK_INPUT.OnKeyDown := OverlayHotkeyCaptureKeyDown
    HK_INPUT.OnKeyUp := HotkeyCaptureKeyUp
    HK_INPUT.Start()
    SendHotkeyCaptureMods()
}
StartStopHotkeyCapture() {
    global HK_INPUT, HK_MODS
    StopHotkeyCapture()
    HK_MODS := Map("ctrl", false, "alt", false, "shift", false, "win", false)
        HK_INPUT := InputHook("L0")
    HK_INPUT.KeyOpt("{All}", "NS")
    HK_INPUT.OnKeyDown := StopHotkeyCaptureKeyDown
    HK_INPUT.OnKeyUp := HotkeyCaptureKeyUp
    HK_INPUT.Start()
    SendHotkeyCaptureMods()
}
StartIdHotkeyCapture() {
    global HK_INPUT, HK_MODS
    StopHotkeyCapture()
    HK_MODS := Map("ctrl", false, "alt", false, "shift", false, "win", false)
        HK_INPUT := InputHook("L0")
    HK_INPUT.KeyOpt("{All}", "NS")
    HK_INPUT.OnKeyDown := IdHotkeyCaptureKeyDown
    HK_INPUT.OnKeyUp := HotkeyCaptureKeyUp
    HK_INPUT.Start()
    SendHotkeyCaptureMods()
}
StartModeHotkeyCapture() {
    global HK_INPUT, HK_MODS
    StopHotkeyCapture()
    HK_MODS := Map("ctrl", false, "alt", false, "shift", false, "win", false)
        HK_INPUT := InputHook("L0")
    HK_INPUT.KeyOpt("{All}", "NS")
    HK_INPUT.OnKeyDown := ModeHotkeyCaptureKeyDown
    HK_INPUT.OnKeyUp := HotkeyCaptureKeyUp
    HK_INPUT.Start()
    SendHotkeyCaptureMods()
}

StopHotkeyCapture() {
    global HK_INPUT, HK_MODS
    if HK_INPUT is InputHook {
        try HK_INPUT.Stop()
    }
    HK_INPUT := ""
    HK_MODS := Map("ctrl", false, "alt", false, "shift", false, "win", false)
}

HotkeyCaptureKeyDown(ih, vk, sc) {
    global HK_INPUT, HK_MODS, wv
    mod := GetModifierName(vk)
    if (mod != "") {
        HK_MODS[mod] := true
        SendHotkeyCaptureMods()
        return
    }
    if (vk = 0x1B) {
        try wv.PostWebMessageAsString("hotkey_capture_cancel")
        StopHotkeyCapture()
        return
    }
    if (vk = 0x08 || vk = 0x2E) {
        try wv.PostWebMessageAsString("hotkey_capture_clear")
        return
    }
    key := SafeGetKeyName(vk, sc)
    if !key
        return
    hotkey := BuildHotkeyStringFromState(key)
    try wv.PostWebMessageAsString("hotkey_captured:" hotkey)
    StopHotkeyCapture()
}

OverlayHotkeyCaptureKeyDown(ih, vk, sc) {
    global HK_INPUT, HK_MODS, wv
    mod := GetModifierName(vk)
    if (mod != "") {
        HK_MODS[mod] := true
        SendHotkeyCaptureMods()
        return
    }
    if (vk = 0x1B) {
        try wv.PostWebMessageAsString("overlay_hotkey_capture_cancel")
        StopHotkeyCapture()
        return
    }
    if (vk = 0x08 || vk = 0x2E) {
        try wv.PostWebMessageAsString("overlay_hotkey_capture_clear")
        return
    }
    key := SafeGetKeyName(vk, sc)
    if !key
        return
    hotkey := BuildHotkeyStringFromState(key)
    try wv.PostWebMessageAsString("overlay_hotkey_captured:" hotkey)
    StopHotkeyCapture()
}

StopHotkeyCaptureKeyDown(ih, vk, sc) {
    global HK_INPUT, HK_MODS, wv
    mod := GetModifierName(vk)
    if (mod != "") {
        HK_MODS[mod] := true
        SendHotkeyCaptureMods()
        return
    }
    if (vk = 0x1B) {
        try wv.PostWebMessageAsString("stop_hotkey_capture_cancel")
        StopHotkeyCapture()
        return
    }
    if (vk = 0x08 || vk = 0x2E) {
        try wv.PostWebMessageAsString("stop_hotkey_capture_clear")
        return
    }
    key := SafeGetKeyName(vk, sc)
    if !key
        return
    hotkey := BuildHotkeyStringFromState(key)
    try wv.PostWebMessageAsString("stop_hotkey_captured:" hotkey)
    StopHotkeyCapture()
}

IdHotkeyCaptureKeyDown(ih, vk, sc) {
    global HK_INPUT, HK_MODS, wv
    mod := GetModifierName(vk)
    if (mod != "") {
        HK_MODS[mod] := true
        SendHotkeyCaptureMods()
        return
    }
    if (vk = 0x1B) {
        try wv.PostWebMessageAsString("id_hotkey_capture_cancel")
        StopHotkeyCapture()
        return
    }
    if (vk = 0x08 || vk = 0x2E) {
        try wv.PostWebMessageAsString("id_hotkey_capture_clear")
        return
    }
    key := SafeGetKeyName(vk, sc)
    if !key
        return
    hotkey := BuildHotkeyStringFromState(key)
    try wv.PostWebMessageAsString("id_hotkey_captured:" hotkey)
    StopHotkeyCapture()
}

ModeHotkeyCaptureKeyDown(ih, vk, sc) {
    global HK_INPUT, HK_MODS, wv
    mod := GetModifierName(vk)
    if (mod != "") {
        HK_MODS[mod] := true
        SendHotkeyCaptureMods()
        return
    }
    if (vk = 0x1B) {
        try wv.PostWebMessageAsString("mode_hotkey_capture_cancel")
        StopHotkeyCapture()
        return
    }
    if (vk = 0x08 || vk = 0x2E) {
        try wv.PostWebMessageAsString("mode_hotkey_capture_clear")
        return
    }
    key := SafeGetKeyName(vk, sc)
    if !key
        return
    hotkey := BuildHotkeyStringFromState(key)
    try wv.PostWebMessageAsString("mode_hotkey_captured:" hotkey)
    StopHotkeyCapture()
}

; Собирает строку хоткея, опираясь на ФИЗИЧЕСКОЕ состояние модификаторов
; в момент нажатия клавиши. Это надёжнее, чем HK_MODS, потому что OnKeyUp
; для модификаторов иногда не срабатывает (особенно для Win, который
; перехватывается Windows раньше хука). Без этого «залипшие» true в HK_MODS
; приводят к тому, что любая клавиша превращается в Ctrl+Alt+Shift+Win+…
BuildHotkeyStringFromState(key) {
    mods := ""
    if (GetKeyState("Ctrl", "P"))
        mods .= "^"
    if (GetKeyState("Alt", "P"))
        mods .= "!"
    if (GetKeyState("Shift", "P"))
        mods .= "+"
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        mods .= "#"
    return mods . key
}

HotkeyCaptureKeyUp(ih, vk, sc) {
    global HK_MODS
    mod := GetModifierName(vk)
    if (mod != "") {
        HK_MODS[mod] := false
        SendHotkeyCaptureMods()
    }
}

GetModifierName(vk) {
    switch vk {
        case 0xA0, 0xA1, 0x10: return "shift"
        case 0xA2, 0xA3, 0x11: return "ctrl"
        case 0xA4, 0xA5, 0x12: return "alt"
        case 0x5B, 0x5C: return "win"
    }
    return ""
}

ReadHotkeyFromIni(file, sec, key, def) {
    hk := Trim(IniRead(file, sec, key, def))
    if (hk != "" && ValidateHotkeyString(hk) != "") {
        LogLine("Invalid hotkey in INI [" sec "] " key " → fallback " def)
        return def
    }
    return hk
}

; Читает хоткей оверлея из уже разобранного INI (ReadIniRaw) — без IniRead,
; который плохо дружит с UTF-16. Пусто/некорректно → значение по умолчанию.
ReadHotkeyRaw(allIni, key, def) {
    if (!allIni.Has("Overlay") || !allIni["Overlay"].Has(key))
        return def
    hk := Trim(allIni["Overlay"][key])
    if (hk != "" && ValidateHotkeyString(hk) != "") {
        LogLine("ReadHotkeyRaw: invalid [" key "] → default " def)
        return def
    }
    return hk
}

SafeGetKeyName(vk, sc := 0) {
    if (sc = 0x11C)
        return "NumpadEnter"
    ; NumLock выключен: VK совпадает со стрелками, но скан-код — другой.
    if (vk >= 0x21 && vk <= 0x2E && sc > 0 && sc < 0x100) {
        name := GetKeyName(Format("sc{:03X}", sc))
        if (SubStr(name, 1, 6) = "Numpad")
            return name
    }
    ; Буквы и цифры определяем по VK, а не через GetKeyName:
    ; в русской раскладке он возвращает «ь» и получался бы vk4D.
    if (vk >= 0x41 && vk <= 0x5A)
        return StrLower(Chr(vk))
    if (vk >= 0x30 && vk <= 0x39)
        return Chr(vk)

    ; Навигационные клавиши (стрелки, PgUp/PgDn, Home/End, Ins/Del):
    ; GetKeyName("vkXX") для них может вернуть локализованное имя или пустую
    ; строку в зависимости от раскладки — такие значения не проходят валидацию
    ; хоткея. Используем канонические имена AHK.
    if (vk >= 0x21 && vk <= 0x2E)
        return MapNavigationVk(vk)

    try {
        name := GetKeyName(Format("vk{:02X}", vk))
    } catch {
        return Format("vk{:02X}", vk)
    }
    if (name = "" || RegExMatch(name, "[^\x20-\x7E]"))
        return Format("vk{:02X}", vk)
    return name
}

MapNavigationVk(vk) {
    switch vk {
        case 0x21: return "PgUp"
        case 0x22: return "PgDn"
        case 0x23: return "End"
        case 0x24: return "Home"
        case 0x25: return "Left"
        case 0x26: return "Up"
        case 0x27: return "Right"
        case 0x28: return "Down"
        case 0x2D: return "Insert"
        case 0x2E: return "Delete"
    }
    return Format("vk{:02X}", vk)
}

; Безопасное преобразование в int.
; - Если str не число → возвращает def.
; - Если число вне [minV, maxV] → клампится.
; - Защищён от переполнения Integer() при экстремально длинных числах.
; Никогда не бросает исключений, в отличие от голого Integer().
SafeInt(str, def := 0, minV := -2147483648, maxV := 2147483647) {
    text := Trim("" . str)
    if !RegExMatch(text, "^-?[0-9]+$") {
        return def
    }
    negative := SubStr(text, 1, 1) = "-"
    digits := negative ? SubStr(text, 2) : text
    digits := LTrim(digits, "0")
    if (digits = "") {
        return Min(maxV, Max(minV, 0))
    }
    if (StrLen(digits) > 15) {
        return negative ? minV : maxV
    }
    value := Integer(digits)
    if negative {
        value := -value
    }
    return Min(maxV, Max(minV, value))
}

CheckNumericHelpers() {
    cases := [
        ["1", 0, 0, 101, 1], ["100", 0, 0, 101, 100],
        ["80", 235, 80, 255, 80], ["160", 235, 80, 255, 160],
        ["235", 235, 80, 255, 235], ["255", 235, 80, 255, 255],
        ["0", 235, 80, 255, 80], ["999", 235, 80, 255, 255],
        ["", 235, 80, 255, 235], ["bad", 235, 80, 255, 235],
        ["000160", 235, 80, 255, 160], ["-1", 20, -100, 100, -1],
        ["999999999999999999999999", 0, 0, 255, 255],
        ["-999999999999999999999999", 0, -255, 255, -255]
    ]
    for item in cases {
        actual := SafeInt(item[1], item[2], item[3], item[4])
        if !IsInteger(actual) || actual != item[5] {
            LogLine("NUMERIC SELF-CHECK FAILED: input=" item[1] " actual=" actual " expected=" item[5])
            MsgBox "Ошибка числовой самопроверки. Запуск остановлен до загрузки профиля.", "UniBind beta.1", "IconX"
            return false
        }
    }
    LogLine("BUILD 2027.10 beta.1 | NUMERIC SELF-CHECK PASS: " cases.Length)
    return true
}

; Возвращает "" если хоткей валиден для AHK v2, иначе — текст ошибки.
ValidateHotkeyString(hk) {
    if (hk = "")
        return ""

    ; Отделяем ведущие модификаторы ^ ! + #
    i := 1
    len := StrLen(hk)
    while (i <= len) {
        c := SubStr(hk, i, 1)
        if (c = "^" || c = "!" || c = "+" || c = "#")
            i++
        else
            break
    }
    key := SubStr(hk, i)
    if (key = "")
        return "только модификаторы без клавиши"

    ; vkXX / scXX — прямое указание скан-кода/виртуальной клавиши
    if RegExMatch(key, "^(vk[0-9A-Fa-f]{1,4}|sc[0-9A-Fa-f]{1,4})$")
        return ""

    ; Одиночный латинский символ или цифра
    if (StrLen(key) = 1) {
        if RegExMatch(key, "^[A-Za-z0-9]$")
            return ""
        return "одиночный символ «" key "» не поддерживается (только A-Z, 0-9)"
    }

    ; Имя клавиши. AHK v2 использует имена вида: LButton, WheelUp, NumpadDel,
    ; Launch_Mail, Browser_Back, Media_Play_Pause и т.п. Все они — латиница,
    ; цифры и подчёркивания, начинаются с буквы. Всё остальное — мусор.
    if RegExMatch(key, "^[A-Za-z][A-Za-z0-9_]{0,63}$")
        return ""

    return "недопустимая запись «" key "»"
}


SendHotkeyCaptureMods() {
    global HK_MODS, wv
    if !wv
        return
    msg := "hotkey_capture_mods:" . (HK_MODS["ctrl"] ? "1" : "0") . "," . (HK_MODS["alt"] ? "1" : "0") . "," . (HK_MODS["shift"] ? "1" : "0") . "," . (HK_MODS["win"] ? "1" : "0")
    try wv.PostWebMessageAsString(msg)
}

SnapshotOverlayCfg() {
    global CFG
    snap := Map()
    for k in ["overlayEnabled","overlayHotkey","stopHotkey","idInputHotkey",
              "overlayOpacity","overlayWidth","overlayHeight","overlayX","overlayY",
              "showIdInOverlay","patientFormat","overlayMode","overlayModeHotkey","overlayHints"]
        snap[k] := CFG[k]
    return snap
}

RestoreOverlayCfg(snap) {
    global CFG
    for k, v in snap
        CFG[k] := v
}

; ВАЖНО: вызываем все 4 безусловно, потом объединяем —
; при прямом `return a && b && c && d` короткое замыкание
; съело бы три из четырёх переустановок.
RegisterAllUtilityHotkeys(silent := false) {
    a := RegisterOverlayHotkey(silent)
    b := RegisterStopHotkey(silent)
    c := RegisterIdInputHotkey(silent)
    d := RegisterOverlayModeHotkey(silent)
    return a && b && c && d
}

; Возвращает true, если откат хоткеев прошёл целиком.
RollbackOverlaySettings(snap, iniBak, iniSnapshotOK, hadIni) {
    global CONFIG_FILE
    uOk := UnregisterUtilityHotkeys()
    if !uOk
        LogLine("RollbackOverlaySettings: unregister had partial failure — proceeding anyway")
    RestoreOverlayCfg(snap)
    rbOk := RegisterAllUtilityHotkeys(true)
    if (iniSnapshotOK && hadIni) {
        try FileCopy(iniBak, CONFIG_FILE, 1)
        catch as err {
            rbOk := false
            LogLine("Rollback INI failed: " err.Message)
        }
    } else if !hadIni {
        try FileDelete(CONFIG_FILE)
    }
    return rbOk
}


; ============================================
;  РЕГИСТРАЦИЯ ХОТКЕЕВ
; ============================================
ClearAllSlotHotkeys() {
    global ACTIVE_HOTKEYS
    HotIf(SlotHotkeyActive)
    try {
        for hk in ACTIVE_HOTKEYS
            try Hotkey(hk, "Off")
        ACTIVE_HOTKEYS := Map()
    } finally {
        HotIf()
    }
}

UnregisterUtilityHotkeys() {
    global UTILITY_HOTKEYS
    ok := true
    for key, hk in UTILITY_HOTKEYS {
        if (hk = "")
            continue
        SetUtilityHotkeyContext(key)
        try {
            Hotkey(hk, "Off")
            UTILITY_HOTKEYS[key] := ""
        } catch as err {
            ok := false
            LogLine("UnregisterUtilityHotkeys: " key " — " err.Message)
        } finally {
            HotIf()
        }
    }
    return ok
}

RegisterUtilityHotkey(key, hkStr, fn, silent := false) {
    global UTILITY_HOTKEYS, wv
    SetUtilityHotkeyContext(key)
    try {
        if (UTILITY_HOTKEYS.Has(key) && UTILITY_HOTKEYS[key] != "") {
            Hotkey(UTILITY_HOTKEYS[key], "Off")
            UTILITY_HOTKEYS[key] := ""
        }
        if (hkStr = "")
            return true
        vErr := ValidateHotkeyString(hkStr)
        if (vErr != "")
            throw ValueError(vErr)
        fullHk := "$" hkStr
        Hotkey(fullHk, fn, "On")
        UTILITY_HOTKEYS[key] := fullHk
        return true
    } catch as err {
        LogLine("Utility hotkey " key " (" hkStr "): " err.Message)
        if !silent {
            SendNotify("Не удалось назначить «" hkStr "»: " err.Message, "error")
            try wv.PostWebMessageAsString("overlay_settings_error:" err.Message)
        }
        return false
    } finally {
        HotIf()
    }
}

RegisterAllHotkeys() {
    global SLOTS, ACTIVE_HOTKEYS, BINDER_ENABLED
    ClearAllSlotHotkeys()
    UnregisterUtilityHotkeys()
    registered := 0
    if BINDER_ENABLED {
        HotIf(SlotHotkeyActive)
        try {
            Loop 100 {
                slot := SLOTS[A_Index]
                if !slot["enabled"] || slot["hotkey"] = "" || slot["lines"].Length = 0
                    continue
                hkFull := "$" slot["hotkey"]
                try {
                    Hotkey(hkFull, MakeSlotHandler(A_Index), "On")
                    ACTIVE_HOTKEYS[hkFull] := A_Index
                    registered++
                } catch as err {
                    LogLine("Slot hk fail: " slot["hotkey"] ": " err.Message)
                }
            }
        } finally {
            HotIf()
        }
    }
    LogLine("Slot hotkeys: " registered)
    RegisterAllUtilityHotkeys()
}

MakeSlotHandler(num) {
    ; Аргумент не используется — имя `_hk` вместо `ThisHotkey`,
    ; чтобы не путать с A_ThisHotkey.
    return (_hk) => SafeRunSlot(num)
}

SafeRunSlot(num) {
    global BINDER_ENABLED, CFG, IS_SENDING, SEND_BUSY
    if !BINDER_ENABLED || IS_SENDING || SEND_BUSY
        return
    if (CFG["onlyGTA"] && !WinActive("ahk_exe gta_sa.exe"))
        return
    Sleep(20)
    ; Дождаться отпускания модификаторов хоткея (Alt+1 и т.п.), чтобы они не попали в ввод.
    if (GetKeyState("Alt", "P"))
        KeyWait("Alt", "L T0.8")
    if (GetKeyState("Ctrl", "P"))
        KeyWait("Ctrl", "L T0.8")
    if (GetKeyState("Shift", "P"))
        KeyWait("Shift", "L T0.8")
    if (GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        KeyWait("LWin", "L T0.8")
    Sleep(30)
    RunSlotByNum(num, false)
}

; ============================================
;  ОТПРАВКА
; ============================================
; Активирует именно ГЛАВНОЕ окно игры. У gta_sa.exe бывают и другие окна
; (например D3DProxyWindow): активация такого окна сворачивает полноэкранную игру.
ActivateGtaWindow() {
    hwnd := WinExist("ahk_exe gta_sa.exe ahk_class Grand theft auto San Andreas")
    if !hwnd
        hwnd := WinExist("ahk_exe gta_sa.exe")
    if !hwnd
        return 0
    if (WinGetMinMax("ahk_id " hwnd) = -1)
        WinRestore("ahk_id " hwnd)
    WinActivate("ahk_id " hwnd)
    WinWaitActive("ahk_id " hwnd,, 2)
    Sleep(150)
    return WinActive("ahk_exe gta_sa.exe")
}

RunSlotByNum(num, force := false) {
    global SLOTS, STATE, IS_SENDING, SEND_BUSY, CFG, BINDER_ENABLED, OVERLAY_VISIBLE, SEND_TOKEN
    if !BINDER_ENABLED {
        SendNotify("Биндер выключен", "warning")
        return
    }
    if (num < 1 || num > 100 || SEND_BUSY)
        return
    if CFG["onlyGTA"] {
        ; У gta_sa.exe несколько окон (в т.ч. D3DProxyWindow). WinExist("ahk_exe ...")
        ; может вернуть не то окно, которое реально в фокусе, и WinActivate на нём
        ; сворачивает игру. Поэтому берём именно АКТИВНОЕ окно игры.
        hwnd := WinActive("ahk_exe gta_sa.exe")
        if !hwnd {
            if !WinExist("ahk_exe gta_sa.exe") {
                SendNotify("GTA не запущена", "warning")
                return
            }
            hwnd := ActivateGtaWindow()
        }
    } else {
        if (force && WinExist("ahk_exe gta_sa.exe"))
            ActivateGtaWindow()
        hwnd := WinExist("A")
        if MainWindowActive() {
            SendNotify("Выберите целевое окно и запускайте бинд горячей клавишей", "warning")
            return
        }
    }

    if (!hwnd || !TargetActive(hwnd)) {
        try LogLine("Target inactive: hwnd=" hwnd " fg=" WinGetProcessName("A") "/" WinGetClass("A"))
        SendNotify("Целевое окно не активно", "warning")
        return
    }
    slot := SLOTS[num]
    if !slot["enabled"] || slot["lines"].Length = 0
        return
    for line in slot["lines"] {
        if InStr(line["text"], "{T}") && STATE["targetId"] = "" {
            SendNotify("Укажите ID цели!", "warning")
            return
        }
    }
    ; Lock before hiding the overlay (which can yield to another AHK thread).
    SEND_BUSY := true
    IS_SENDING := true
    SEND_TOKEN += 1
    token := SEND_TOKEN
    sendOk := false
    try {
        if OVERLAY_VISIBLE
            HideOverlay()
        watchdogMs := 30000
        for line in slot["lines"]
            watchdogMs += Max(0, line["delay"] > 0 ? line["delay"] : CFG["baseDelay"])
                + CFG["jitter"] + CFG["afterChatDelay"] + CFG["afterEnterDelay"] + 1000
        SetTimer(() => SendWatchdog(token), -Min(watchdogMs, 2147483647))
        SendStatus()
        SendNotify("► " slot["name"], "info")
        sendOk := SendChatSequence(slot, token, hwnd)
    } catch as err {
        LogLine("Send failed: " err.Message)
        SendNotify("Отправка прервана: " err.Message, "warning")
    } finally {
        IS_SENDING := false
        SEND_BUSY := false
        try BlockInput("Off")
        SendStatus()
    }
    if sendOk {
        IncrementStat("totalSent")
        st := slot["statType"]
        if (st != "" && STATS.Has(st))
            IncrementStat(st)
        SendNotify("✓ Последовательность ввода выполнена", "success")
    }
    PushDataToHtml()
}

TargetActive(hwnd) {
    global CFG
    ; В режиме «только GTA» целью считается любое окно gta_sa.exe, а не один HWND.
    if CFG["onlyGTA"]
        return WinActive("ahk_exe gta_sa.exe") ? true : false
    return (hwnd && WinActive("ahk_id " hwnd)) ? true : false
}

CheckSendTarget(token, hwnd) {
    global IS_SENDING, SEND_TOKEN, BINDER_ENABLED
    if (!IS_SENDING || token != SEND_TOKEN || !BINDER_ENABLED)
        throw Error("отмена пользователем или таймером")
    if !TargetActive(hwnd)
        throw Error("целевое окно потеряло фокус")
}

WaitForSend(ms, token, hwnd) {
    deadline := A_TickCount + ms
    loop {
        CheckSendTarget(token, hwnd)
        left := deadline - A_TickCount
        if (left <= 0)
            return
        Sleep(Min(25, left))
    }
}

SendChatSequence(slot, token, hwnd) {
    global CFG
    for idx, line in slot["lines"] {
        CheckSendTarget(token, hwnd)
        text := ReplaceVariables(line["text"])
        if RegExMatch(text, "^\{[a-zA-Z0-9_]+\}$") {
            if !WinActive("ahk_exe gta_sa.exe")
                throw Error("команда клавиши разрешена только в GTA")
            if !IsAllowedKeyCommand(text)
                throw Error("клавиша " text " не входит в список разрешённых (Win/медиа/браузер и т.п. заблокированы)")
            CheckSendTarget(token, hwnd)
            SendInput(text)
        } else {
            SendTextToChat(text, token, hwnd)
        }
        if (idx < slot["lines"].Length) {
            waitMs := line["delay"] > 0 ? line["delay"] : CFG["baseDelay"]
            if (CFG["jitter"] > 0)
                waitMs += Random(-CFG["jitter"], CFG["jitter"])
            WaitForSend(Max(0, waitMs), token, hwnd)
        }
    }
    CheckSendTarget(token, hwnd)
    return true
}

; Белый список клавиш для строк вида {Имя}. Импортированный или чужой конфиг не должен
; уметь нажимать Win, медиа/браузерные клавиши, {Click}, {Raw}, {vkNN} и т.п.
IsAllowedKeyCommand(cmd) {
    static pattern := "i)^(F([1-9]|1[0-9]|2[0-4])|Numpad[0-9]|Numpad(Dot|Add|Sub|Mult|Div|Enter)|Enter|Esc|Escape|Space|Tab|Backspace|BS|Delete|Del|Insert|Ins|Home|End|PgUp|PgDn|Up|Down|Left|Right|[LR]?(Shift|Ctrl|Control|Alt)|[a-z0-9])$"
    name := SubStr(cmd, 2, -1)
    return RegExMatch(name, pattern) ? true : false
}

BlockInputFailsafe() {
    ; Аварийный сброс блокировки ввода. ТОЛЬКО снимает BlockInput —
    ; НЕ трогает IS_SENDING, не прерывает штатную длинную отправку.
    try BlockInput("Off")
}

SendWatchdog(token) {
    ; Сторож зависшей отправки. Срок = ожидаемая длительность + запас 30 секунд
    ; и завершает её, только если токен совпадает с текущим (т.е. новая
    ; отправка не стартовала поверх старой).
    global SEND_TOKEN, IS_SENDING
    if (token != SEND_TOKEN)
        return
    if IS_SENDING {
        IS_SENDING := false
        SendStatus()
        SendNotify("⚠ Отправка подозрительно долгая — прервано", "warning")
    }
}

SendTextToChat(text, token, hwnd) {
    global CFG
    CheckSendTarget(token, hwnd)
    if (text = "")
        throw Error("пустой текст после подстановки переменных")
    ; If the old clipboard cannot be saved, do not overwrite user data.
    oldClip := ClipboardAll()
    clipboardTouched := false
    chatOpened := false
    submitted := false
    heldKeys := []
    try {
        for key in ["w", "a", "s", "d", "shift", "ctrl", "space", "Up", "Down", "Left", "Right"] {
            if GetKeyState(key, "P") {
                heldKeys.Push(key)
                CheckSendTarget(token, hwnd)
                SendEvent("{" key " up}")
            }
        }
        WaitForSend(15, token, hwnd)
        ; Do not block the physical keyboard: Stop and Alt+Tab must remain usable.
        CheckSendTarget(token, hwnd)
        SendEvent("{" CFG["chatKey"] "}")
        chatOpened := true
        WaitForSend(CFG["afterChatDelay"], token, hwnd)
        clipboardTouched := true
        A_Clipboard := text
        deadline := A_TickCount + 500
        while !ClipWait(0.025) {
            CheckSendTarget(token, hwnd)
            if (A_TickCount >= deadline)
                throw Error("буфер обмена не готов")
        }
        CheckSendTarget(token, hwnd)
        SendEvent("^v")
        WaitForSend(60, token, hwnd)
        CheckSendTarget(token, hwnd)
        SendEvent("{Enter}")
        submitted := true
        WaitForSend(CFG["afterEnterDelay"], token, hwnd)
    } finally {
        ; Never send Escape or restore held keys into a different application.
        if (chatOpened && !submitted && TargetActive(hwnd))
            try SendEvent("{Escape}")
        if clipboardTouched
            try A_Clipboard := oldClip
        try SetTimer(BlockInputFailsafe, 0)
        try BlockInput("Off")
        if TargetActive(hwnd) {
            for key in heldKeys {
                if GetKeyState(key, "P")
                    try SendEvent("{" key " down}")
            }
        }
    }
}

ReplaceVariables(text) {
    global STATE, CFG
    tid := STATE["targetId"]
    switch CFG["patientFormat"] {
        case "at":    tid := "@" tid
        case "quote": tid := '"' tid '"'
    }
    text := StrReplace(text, "{T}", tid)
    text := StrReplace(text, "{MY}", STATE["myName"])
    text := StrReplace(text, "{ORG}", STATE["organization"])
    text := StrReplace(text, "{RANK}", STATE["rank"])
    for name, value in STATE["variables"]
        text := StrReplace(text, "{" name "}", value)
    return text
}

; ============================================
;  КОНФИГ
; ============================================
LoadConfig() {
    global SLOTS, STATE, CFG, CONFIG_FILE, STATS, BINDER_ENABLED, PROFILES, ACTIVE_PROFILE_IDX, NEXT_PROFILE_ID, FIRST_RUN

    LogLine("=== LC START ===")
    LogLine("Script: " A_ScriptFullPath)
    LogLine("Size: " FileGetSize(A_ScriptFullPath))
    LogLine("AHK: " A_AhkVersion)
    LogLine("BUILD 2027.10 beta.1 (numeric conversion and overlay opacity)")

    try MigrateLegacyConfig()
    catch as e
        LogLine("LoadConfig: migrate err: " e.Message)

    ; ===== ПЕРВЫЙ ЗАПУСК =====
    ; settings.ini не существует и legacy-конфига нет → показываем приветствие
    if !FileExist(CONFIG_FILE) {
        FIRST_RUN := true
        LogLine("LC: FIRST RUN detected — ждём выбор профиля")
        PushDataToHtml()
        return
    }

    try {
        ; Сначала читаем весь файл через File API
        allIni := ReadIniRaw(CONFIG_FILE)

        STATE["myName"]       := allIni.Has("Settings") && allIni["Settings"].Has("myName") ? allIni["Settings"]["myName"] : ""
        STATE["organization"] := allIni.Has("Profile") && allIni["Profile"].Has("organization") ? allIni["Profile"]["organization"] :
                                 (allIni.Has("Profile") && allIni["Profile"].Has("hospital") ? allIni["Profile"]["hospital"] : "")
        STATE["rank"]         := allIni.Has("Profile") && allIni["Profile"].Has("rank") ? allIni["Profile"]["rank"] : ""

        ; === Профили ===
        profSec := allIni.Has("Profiles") ? allIni["Profiles"] : Map()
        rc := profSec.Has("count") ? profSec["count"] : "0"
        ; Parse count directly: SafeInt unexpectedly returned an empty value
        ; for a valid count in some existing configurations, aborting LoadConfig.
        profCount := 0
        try {
            profCount := Integer(Trim("" . rc))
        } catch {
            profCount := 0
        }
        if (profCount < 0)
            profCount := 0
        if (profCount > 50)
            profCount := 50
        LogLine("LC: profCount=" profCount " (raw='" rc "')")

        NEXT_PROFILE_ID := 1

        if (profCount > 0) {
            Loop profCount {
                i := A_Index
                rp := profSec.Has("profile" i "_id") ? profSec["profile" i "_id"] : "0"
                ; Не используем SafeInt в критическом пути загрузки профилей:
                ; в установленной версии он возвращал пустое значение, из-за
                ; чего сравнение pid <= 0 прерывало LoadConfig.
                pid := 0
                try {
                    pidText := Trim("" . rp)
                    if RegExMatch(pidText, "^\d+$")
                        pid := Integer(pidText)
                } catch {
                    pid := 0
                }
                if (pid < 1 || pid > 1000)
                    pid := 0
                if (pid <= 0) {
                    pid := NEXT_PROFILE_ID
                    NEXT_PROFILE_ID := NEXT_PROFILE_ID + 1
                } else if (pid >= NEXT_PROFILE_ID) {
                    NEXT_PROFILE_ID := pid + 1
                }
                p := Map(
                    "id",       pid,
                    "label",    profSec.Has("profile" i "_label") ? profSec["profile" i "_label"] : ("Профиль " i),
                    "name",     profSec.Has("profile" i "_name") ? profSec["profile" i "_name"] : "",
                    "organization", profSec.Has("profile" i "_hospital") ? profSec["profile" i "_hospital"] : "",
                    "rank",     profSec.Has("profile" i "_rank") ? profSec["profile" i "_rank"] : ""
                )
                PROFILES.Push(p)
            }

            LogLine("LC: профили перенумерованы 1.." PROFILES.Length)

            ra := profSec.Has("active") ? profSec["active"] : "1"
            ACTIVE_PROFILE_IDX := 1
            try {
                activeText := Trim("" . ra)
                if RegExMatch(activeText, "^\d+$")
                    ACTIVE_PROFILE_IDX := Integer(activeText)
            } catch {
                ACTIVE_PROFILE_IDX := 1
            }
            if (ACTIVE_PROFILE_IDX < 1)
                ACTIVE_PROFILE_IDX := 1
            if (ACTIVE_PROFILE_IDX > PROFILES.Length)
                ACTIVE_PROFILE_IDX := PROFILES.Length
            LogLine("LC: active=" ACTIVE_PROFILE_IDX)
            LogLine("LC: profiles=" PROFILES.Length " active=" ACTIVE_PROFILE_IDX " pid=" PROFILES[ACTIVE_PROFILE_IDX]["id"])
            ApplyProfileToState(ACTIVE_PROFILE_IDX)
            LoadActiveProfileFromIni()
            LogLine("LC: after load slots=" SLOTS.Length " cats=" CATEGORIES.Length)
        } else {
            LogLine("LC: profCount=0 → создаём пустой профиль")
            newId := NEXT_PROFILE_ID
            NEXT_PROFILE_ID := NEXT_PROFILE_ID + 1
            p := Map(
                "id",       newId,
                "label",    (STATE["myName"] != "") ? STATE["myName"] : "Основной",
                "name",     STATE["myName"],
                "organization", STATE["organization"],
                "rank",     STATE["rank"]
            )
            PROFILES.Push(p)
            ACTIVE_PROFILE_IDX := 1
            ApplyProfileToState(ACTIVE_PROFILE_IDX)
            LoadActiveProfileFromIni()
            SaveProfilesToIni()
        }

        ; === Stats ===
        for key in ["totalSent","stat1","stat2","stat3","stat4","stat5"] {
            rs := IniRead(CONFIG_FILE, "Stats", key, "0")
            val := 0
            try
                val := Integer(rs)
            catch
                val := 0
            STATS[key] := val
        }

        ; === Settings ===
        ck := IniRead(CONFIG_FILE, "Settings", "chatKey", "t")
        if (ck = "" || StrLen(ck) > 1)
            ck := "t"
        CFG["chatKey"] := ck

        rs := IniRead(CONFIG_FILE, "Settings", "baseDelay", "2300")
        CFG["baseDelay"] := 2300
        try
            CFG["baseDelay"] := Integer(rs)
        catch
            CFG["baseDelay"] := 2300
        if (CFG["baseDelay"] < 0) {
            CFG["baseDelay"] := 0
        }
        if (CFG["baseDelay"] > 60000) {
            CFG["baseDelay"] := 60000
        }

        rs := IniRead(CONFIG_FILE, "Settings", "afterChatDelay", "300")
        CFG["afterChatDelay"] := 300
        try
            CFG["afterChatDelay"] := Integer(rs)
        catch
            CFG["afterChatDelay"] := 300
        if (CFG["afterChatDelay"] < 0) {
            CFG["afterChatDelay"] := 0
        }
        if (CFG["afterChatDelay"] > 10000) {
            CFG["afterChatDelay"] := 10000
        }

        rs := IniRead(CONFIG_FILE, "Settings", "afterEnterDelay", "400")
        CFG["afterEnterDelay"] := 400
        try
            CFG["afterEnterDelay"] := Integer(rs)
        catch
            CFG["afterEnterDelay"] := 400
        if (CFG["afterEnterDelay"] < 0) {
            CFG["afterEnterDelay"] := 0
        }
        if (CFG["afterEnterDelay"] > 10000) {
            CFG["afterEnterDelay"] := 10000
        }

        CFG["onlyGTA"]       := (IniRead(CONFIG_FILE, "Settings", "onlyGTA", "1") = "1")
        CFG["patientFormat"] := IniRead(CONFIG_FILE, "Settings", "patientFormat", "plain")

        rs := IniRead(CONFIG_FILE, "Settings", "jitter", "0")
        CFG["jitter"] := 0
        try
            CFG["jitter"] := Integer(rs)
        catch
            CFG["jitter"] := 0
        if (CFG["jitter"] < 0) {
            CFG["jitter"] := 0
        }
        if (CFG["jitter"] > 10000) {
            CFG["jitter"] := 10000
        }

        BINDER_ENABLED := (IniRead(CONFIG_FILE, "Settings", "binderEnabled", "1") = "1")

        ; === Overlay ===
        CFG["overlayEnabled"] := (IniRead(CONFIG_FILE, "Overlay", "enabled", "1") = "1")
        CFG["overlayHotkey"]  := ReadHotkeyRaw(allIni, "hotkey", "F10")
        CFG["stopHotkey"]     := ReadHotkeyRaw(allIni, "stopHotkey", "Backspace")
        CFG["idInputHotkey"]  := ReadHotkeyRaw(allIni, "idInputHotkey", "p")

        CFG["overlayOpacity"] := SafeInt(IniRead(CONFIG_FILE, "Overlay", "opacity", "235"), 235, 80, 255)
        CFG["overlayWidth"] := SafeInt(IniRead(CONFIG_FILE, "Overlay", "width", "260"), 260, 260, 600)
        height := SafeInt(IniRead(CONFIG_FILE, "Overlay", "height", "-1"), -1)
        CFG["overlayHeight"] := (height = -1) ? -1 : Min(Max(height, 100), 900)
        ; Negative coordinates are valid on monitors left/above the primary one.
        ; ResolveOverlayPos checks actual monitor intersection before showing.
        CFG["overlayX"] := SafeInt(IniRead(CONFIG_FILE, "Overlay", "x", "-1"), -1)
        CFG["overlayY"] := SafeInt(IniRead(CONFIG_FILE, "Overlay", "y", "20"), 20)

        CFG["showIdInOverlay"]   := (IniRead(CONFIG_FILE, "Overlay", "showId", "1") = "1")
        CFG["overlayHints"]      := IniRead(CONFIG_FILE, "Overlay", "hints", "all")
        if (CFG["overlayHints"] != "all" && CFG["overlayHints"] != "full" && CFG["overlayHints"] != "none")
            CFG["overlayHints"] := "all"
        CFG["overlayMode"]       := IniRead(CONFIG_FILE, "Overlay", "mode", "full")
        if (CFG["overlayMode"] != "full" && CFG["overlayMode"] != "mini")
            CFG["overlayMode"] := "full"
        CFG["overlayModeHotkey"] := ReadHotkeyRaw(allIni, "modeHotkey", "m")

        ; === Variables ===
        rv := IniRead(CONFIG_FILE, "Variables", "count", "0")
        varCount := 0
        try
            varCount := Integer(rv)
        catch
            varCount := 0
        varCount := Min(Max(varCount, 0), 200)
        Loop varCount {
            n := IniRead(CONFIG_FILE, "Variables", "var" A_Index "_name", "")
            v := IniRead(CONFIG_FILE, "Variables", "var" A_Index "_value", "")
            if (n != "")
                STATE["variables"][n] := v
        }

        LogLine("LC: hotkeys overlay=" CFG["overlayHotkey"] " stop=" CFG["stopHotkey"] " id=" CFG["idInputHotkey"] " mode=" CFG["overlayModeHotkey"])
        LogLine("LC: DONE slots=" SLOTS.Length " cats=" CATEGORIES.Length " profiles=" PROFILES.Length)
    } catch as err {
        LogLine("LoadConfig error: " err.Message " (line " err.Line ")")
    }

    ; Гарантированно пушим данные после загрузки
    LogLine("LC: вызов PushDataToHtml")
    PushDataToHtml()
    LogLine("LC: PushDataToHtml завершён")
}
PushDataToHtml() {
    global wv, CATEGORIES, SLOTS
    UpdateOverlay()
    if !wv
        return
    json := BuildJson()
    namedSlots := 0
    Loop 100
        if (SLOTS[A_Index]["name"] != "")
            namedSlots++
    LogLine("PUSH: json_len=" StrLen(json) " cats=" CATEGORIES.Length " named_slots=" namedSlots)
    ; Первые 300 символов — посмотреть, есть ли категории
    ; Profile contents are deliberately not logged in public builds.
    try wv.PostWebMessageAsString(json)
    catch as err
        LogLine("Push error: " err.Message)
}

BuildJson() {
    global SLOTS, STATE, CFG, STATS, CATEGORIES, BINDER_ENABLED, OVERLAY_VISIBLE, PROFILES, ACTIVE_PROFILE_IDX
    s := '{"profile":{"name":"' EscapeJson(STATE["myName"]) '","organization":"' EscapeJson(STATE["organization"]) '","rank":"' EscapeJson(STATE["rank"]) '","targetId":"' EscapeJson(STATE["targetId"]) '"},'
    s .= '"binderEnabled":' (BINDER_ENABLED ? "true" : "false") ','
    s .= '"profiles":{"active":' ACTIVE_PROFILE_IDX ',"list":['
    pfirst := true
    for p in PROFILES {
        if (!pfirst)
            s .= ","
        pfirst := false
        s .= '{'
        s .= '"label":"'    EscapeJson(p["label"])    '",'
        s .= '"name":"'     EscapeJson(p["name"])     '",'
        s .= '"organization":"' EscapeJson(p["organization"]) '",'
        s .= '"rank":"'     EscapeJson(p["rank"])     '"'
        s .= '}'
    }
    s .= ']},'
    s .= '"overlayVisible":' (OVERLAY_VISIBLE ? "true" : "false") ','
    s .= '"stats":{"totalSent":' STATS["totalSent"] ',"stat1":' STATS["stat1"] ',"stat2":' STATS["stat2"] ',"stat3":' STATS["stat3"] ',"stat4":' STATS["stat4"] ',"stat5":' STATS["stat5"] '},'
    s .= '"settings":{"chatKey":"' EscapeJson(CFG["chatKey"]) '","baseDelay":' CFG["baseDelay"] ',"afterChatDelay":' CFG["afterChatDelay"] ',"afterEnterDelay":' CFG["afterEnterDelay"] ',"patientFormat":"' EscapeJson(CFG["patientFormat"]) '","onlyGTA":' (CFG["onlyGTA"] ? "true" : "false") ',"jitter":' CFG["jitter"] '},'
    s .= '"overlaySettings":{"enabled":' (CFG["overlayEnabled"] ? "true" : "false") ','
    s .= '"hotkey":"' EscapeJson(CFG["overlayHotkey"]) '",'
    s .= '"stopHotkey":"' EscapeJson(CFG["stopHotkey"]) '",'
    s .= '"idInputHotkey":"' EscapeJson(CFG["idInputHotkey"]) '",'
    s .= '"opacity":' CFG["overlayOpacity"] ','
    s .= '"width":' CFG["overlayWidth"] ','
    s .= '"height":' (CFG.Has("overlayHeight") ? CFG["overlayHeight"] : -1) ','
    s .= '"x":' CFG["overlayX"] ','
    s .= '"y":' CFG["overlayY"] ','
    s .= '"screenW":' A_ScreenWidth ','
    s .= '"screenH":' A_ScreenHeight ','
    s .= '"showId":' (CFG["showIdInOverlay"] ? "true" : "false") ','
    s .= '"hints":"' EscapeJson(CFG["overlayHints"]) '",'
    s .= '"mode":"' EscapeJson(CFG["overlayMode"]) '",'
    s .= '"modeHotkey":"' EscapeJson(CFG["overlayModeHotkey"]) '",'
    s .= '"visible":' (OVERLAY_VISIBLE ? "true" : "false") '},'
    s .= '"categories":['
    cfirst := true
    for cat in CATEGORIES {
        if (!cfirst)
            s .= ","
        cfirst := false
        s .= '{"name":"' EscapeJson(cat["name"]) '","icon":"' EscapeJson(cat.Has("icon") ? cat["icon"] : "") '"}'
    }
    s .= '],'
    s .= '"variables":['
    vfirst := true
    for name, value in STATE["variables"] {
        if (!vfirst)
            s .= ","
        vfirst := false
        s .= '{"name":"' EscapeJson(name) '","value":"' EscapeJson(value) '"}'
    }
    s .= '],'
    s .= '"binds":['
    first := true
    Loop 100 {
        slot := SLOTS[A_Index]
        if (slot["name"] = "")
            continue
        if (!first)
            s .= ","
        first := false
        preview := ""
        if (slot["lines"].Length > 0)
            preview := slot["lines"][1]["text"]
        s .= '{'
        s .= '"id":' A_Index ','
        s .= '"name":"' EscapeJson(slot["name"]) '",'
        s .= '"hotkey":"' EscapeJson(slot["hotkey"]) '",'
        s .= '"enabled":' (slot["enabled"] ? "true" : "false") ','
        s .= '"category":"' EscapeJson(slot["category"]) '",'
        s .= '"statType":"' EscapeJson(slot["statType"]) '",'
        s .= '"showInOverlay":' (slot.Has("showInOverlay") && slot["showInOverlay"] ? "true" : "false") ','
        s .= '"sortOrder":' (slot.Has("sortOrder") ? slot["sortOrder"] : A_Index) ','
        s .= '"preview":"' EscapeJson(preview) '",'
        s .= '"lineCount":' slot["lines"].Length ','
        s .= '"lines":['
        lfirst := true
        for line in slot["lines"] {
            if (!lfirst)
                s .= ","
            lfirst := false
            s .= '{"text":"' EscapeJson(line["text"]) '","delay":' line["delay"] '}'
        }
        s .= ']}'
    }
    s .= ']}'
    return s
}

EscapeJson(str) {
    str := StrReplace(str, "\", "\\")
    str := StrReplace(str, '"', '\"')
    str := StrReplace(str, "`n", "\n")
    str := StrReplace(str, "`r", "\r")
    str := StrReplace(str, "`t", "\t")
    ; JSON prohibits every unescaped U+0000..U+001F, not only CR/LF/TAB.
    Loop 31 {
        code := A_Index
        if (code != 9 && code != 10 && code != 13)
            str := StrReplace(str, Chr(code), Format("\u{:04X}", code))
    }
    return str
}

OverlayKeyLabel(key) {
    if RegExMatch(key, "i)^vk([0-9A-F]{2})$", &m) {
        v := Integer("0x" m[1])
        if ((v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A))
            return Chr(v)
        switch v {
            case 0xBA: return ";"
            case 0xBB: return "="
            case 0xBC: return ","
            case 0xBD: return "-"
            case 0xBE: return "."
            case 0xBF: return "/"
            case 0xC0: return "``"
            case 0xDB: return "["
            case 0xDC: return "\"
            case 0xDD: return "]"
            case 0xDE: return "'"
        }
        return key
    }
    if (StrLen(key) = 1)
        return StrUpper(key)
    return key
}


FormatOverlayHotkey(hk) {
    if (hk = "")
        return ""
    mods := ""
    i := 1
    len := StrLen(hk)
    while (i <= len) {
        c := SubStr(hk, i, 1)
        if (c = "^") {
            mods .= "Ctrl+"
            i++
        } else if (c = "!") {
            mods .= "Alt+"
            i++
        } else if (c = "+") {
            mods .= "Shift+"
            i++
        } else if (c = "#") {
            mods .= "Win+"
            i++
        } else {
            break
        }
    }
    key := SubStr(hk, i)
    key := OverlayKeyLabel(key)
    key := StrReplace(key, "NumpadAdd",   "Num+")
    key := StrReplace(key, "NumpadSub",   "Num-")
    key := StrReplace(key, "NumpadMult",  "Num*")
    key := StrReplace(key, "NumpadDiv",   "Num/")
    key := StrReplace(key, "NumpadEnter", "NumEnter")
    key := StrReplace(key, "Numpad",      "Num")
    return mods . key
}

OvKeyLabel(cfgKey, utilKey, def) {
    global CFG, UTILITY_HOTKEYS
    hk := CFG.Has(cfgKey) ? CFG[cfgKey] : ""
    if (hk = "" && UTILITY_HOTKEYS.Has(utilKey) && UTILITY_HOTKEYS[utilKey] != "")
        hk := SubStr(UTILITY_HOTKEYS[utilKey], 2)
    hk := Trim(hk)
    if (hk = "")
        hk := def
    out := "—"
    if (hk != "") {
        mods := ""
        key := hk
        while (key != "" && InStr("^!+#", SubStr(key, 1, 1))) {
            m1 := SubStr(key, 1, 1)
            mods .= (m1 = "^") ? "Ctrl+" : (m1 = "!") ? "Alt+" : (m1 = "+") ? "Shift+" : "Win+"
            key := SubStr(key, 2)
        }
        if (StrLen(key) = 1)
            key := StrUpper(key)
        if (key != "")
            out := mods key
    }
    return out
}


HotkeyCaptureActive() {
    global HK_INPUT
    return (HK_INPUT is InputHook) && HK_INPUT.InProgress
}

MainWindowActive() {
    global MyGui
    return IsObject(MyGui) && WinActive("ahk_id " MyGui.Hwnd)
}

OverlayInteractionReady() {
    global OVERLAY_VISIBLE, OVERLAY_EDIT_MODE, OVERLAY_ID_INPUT_MODE, IS_SENDING, BINDER_ENABLED
    return OVERLAY_VISIBLE && BINDER_ENABLED && !OVERLAY_EDIT_MODE
        && !OVERLAY_ID_INPUT_MODE && !IS_SENDING && !HotkeyCaptureActive()
}

OverlayNavigationReady() {
    global CFG
    return OverlayInteractionReady() && CFG["overlayMode"] = "full"
}

OverlayNavigationActive(*) {
    ; Оверлей не активирует своё окно. Навигация доступна и на рабочем столе.
    ; В WebView клавиши маршрутизирует JS, чтобы не съедать ввод в формах.
    return OverlayNavigationReady() && !MainWindowActive()
}

OverlayUtilityActive(*) {
    global CFG, OVERLAY_PREVIEW, UI_TEXT_INPUT_ACTIVE
    if !OverlayInteractionReady()
        return false
    if MainWindowActive()
        return false
    return true
}

OverlayToggleActive(*) {
    global OVERLAY_EDIT_MODE, OVERLAY_ID_INPUT_MODE
    return !HotkeyCaptureActive() && !OVERLAY_EDIT_MODE && !OVERLAY_ID_INPUT_MODE
}

StopHotkeyActive(*) {
    global IS_SENDING
    return IS_SENDING && !HotkeyCaptureActive()
}

SlotHotkeyActive(*) {
    global BINDER_ENABLED, CFG, IS_SENDING, OVERLAY_EDIT_MODE, OVERLAY_ID_INPUT_MODE
    return BINDER_ENABLED && !IS_SENDING && !SEND_BUSY && !OVERLAY_EDIT_MODE && !OVERLAY_ID_INPUT_MODE
        && !HotkeyCaptureActive() && !MainWindowActive()
        && (!CFG["onlyGTA"] || WinActive("ahk_exe gta_sa.exe"))
}

SetUtilityHotkeyContext(key) {
    if (key = "id" || key = "mode")
        HotIf(OverlayUtilityActive)
    else if (key = "stop")
        HotIf(StopHotkeyActive)
    else
        HotIf(OverlayToggleActive)
}

; Чистые функции используются и навигацией, и встроенным самотестом.
OverlayClampIndex(index, total) {
    return total > 0 ? Min(Max(1, index), total) : 1
}

OverlayPageIndex(index, total, dir) {
    if (total < 1)
        return 1
    index := OverlayClampIndex(index, total)
    page := (index - 1) // 10 + 1
    target := Min(Max(1, page + dir), Ceil(total / 10))
    return Min(total, (target - 1) * 10 + Mod(index - 1, 10) + 1)
}

SyncOverlaySelection() {
    global OVERLAY_INDEX, OVERLAY_TOTAL, OVERLAY_PAGE, OVERLAY_SELECTED, OVERLAY_MAX_PAGES
    OVERLAY_INDEX := OverlayClampIndex(OVERLAY_INDEX, OVERLAY_TOTAL)
    OVERLAY_MAX_PAGES := Max(1, Ceil(OVERLAY_TOTAL / 10))
    OVERLAY_PAGE := (OVERLAY_INDEX - 1) // 10 + 1
    OVERLAY_SELECTED := Mod(OVERLAY_INDEX - 1, 10) + 1
}

ClearOverlayTarget() {
    global STATE, OVERLAY_CACHE
    STATE["targetId"] := ""
    OVERLAY_CACHE["OverlayPatient"] := ""
    PushDataToHtml()
    SendNotify("ID очищен", "info")
}

SendOverlayNavigationState(force := false) {
    global wv, CFG, OVERLAY_VISIBLE, OVERLAY_PAGE, OVERLAY_MAX_PAGES, OVERLAY_INDEX, OVERLAY_TOTAL, OVERLAY_BINDS
    static last := ""
    if !wv
        return
    name := OVERLAY_TOTAL > 0 && OVERLAY_INDEX <= OVERLAY_BINDS.Length ? OVERLAY_BINDS[OVERLAY_INDEX]["name"] : ""
    json := '{"visible":' (OVERLAY_VISIBLE ? "true" : "false")
    json .= ',"mode":"' CFG["overlayMode"] '"'
    json .= ',"page":' OVERLAY_PAGE
    json .= ',"pages":' OVERLAY_MAX_PAGES
    json .= ',"index":' (OVERLAY_TOTAL ? OVERLAY_INDEX : 0)
    json .= ',"total":' OVERLAY_TOTAL
    json .= ',"name":"' EscapeJson(name) '"}'
    if (force || json != last) {
        last := json
        try wv.PostWebMessageAsString("overlay_nav_state:" json)
    }
}

RunOverlaySelfTests() {
    if !CheckNumericHelpers() {
        ExitApp(1)
    }
    failures := []
    checks := 0
    Loop 101 {
        total := A_Index - 1
        Loop Max(1, total) {
            index := A_Index
            for delta in [-1, 0, 1] {
                result := OverlayClampIndex(index + delta, total)
                checks++
                if (result < 1 || result > Max(1, total))
                    failures.Push("Clamp total=" total " index=" index)
                result := OverlayPageIndex(index, total, delta)
                checks++
                if (result < 1 || result > Max(1, total))
                    failures.Push("Page total=" total " index=" index)
            }
        }
    }
    for item in [[10, 35, 1, 20], [20, 35, 1, 30], [30, 35, 1, 35], [1, 35, -1, 1], [1, 0, 1, 1]] {
        checks++
        if (OverlayPageIndex(item[1], item[2], item[3]) != item[4])
            failures.Push("Page regression " checks)
    }
    report := "UniBind 2027.10 overlay self-test`r`nChecks: " checks "`r`nFailures: " failures.Length "`r`n"
    for failure in failures
        report .= failure "`r`n"
    output := A_ScriptDir "\overlay-self-test.txt"
    try FileDelete(output)
    FileAppend(report, output, "UTF-8")
    MsgBox(report "`r`n" output, "UniBind — самотест")
    ExitApp(failures.Length ? 1 : 0)
}

; ============================================
;  ОВЕРЛЕЙ
; ============================================
ToggleOverlay() {
    global OVERLAY_VISIBLE, BINDER_ENABLED, CFG
    if OVERLAY_VISIBLE {
        HideOverlay()
        return
    }
    if !BINDER_ENABLED {
        SendNotify("Биндер выключен — включите тумблер", "warning")
        return
    }
    if !CFG["overlayEnabled"] {
        SendNotify("Overlay выключен в настройках", "warning")
        return
    }
    ShowOverlay()
}

ToggleOverlayPreview() {
    global OVERLAY_VISIBLE, BINDER_ENABLED, CFG, OVERLAY_PREVIEW
    if !BINDER_ENABLED {
        SendNotify("Биндер выключен — включите тумблер", "warning")
        return
    }
    if OVERLAY_VISIBLE {
        HideOverlay()
        return
    }
    OVERLAY_PREVIEW := true     ; показан из настроек — хоткей режима работает вне GTA
    ShowOverlay()
    PushDataToHtml()
}

SetOverlayModeLive(mode) {
    global CFG, CONFIG_FILE, OVERLAY_VISIBLE, OVERLAY_EDIT_MODE
    if OVERLAY_EDIT_MODE
        return
    if (mode != "mini")
        mode := "full"
    CFG["overlayMode"] := mode
    try IniSetSafe(CONFIG_FILE, "Overlay", "mode", mode)
    if OVERLAY_VISIBLE
        ShowOverlay()
    PushDataToHtml()
}

global OVERLAY_DRAG_MODE := ""
global OVERLAY_DRAG_START_X := 0
global OVERLAY_DRAG_START_Y := 0
global OVERLAY_DRAG_START_WX := 0
global OVERLAY_DRAG_START_WY := 0
global OVERLAY_DRAG_START_WW := 0
global OVERLAY_DRAG_START_WH := 0
global OverlayEditorToolbar := ""
global OverlayEditorReadout := ""
global OVERLAY_EDIT_MINW := 260
global OVERLAY_EDIT_MAXW := 600
global OVERLAY_EDIT_MINH := 512   ; уточняется по фактическим подсказкам при показе
global OVERLAY_EDIT_MAXH := 900

OverlayTick(*) {
    UpdateOverlay()
}

OverlayEditActive(*) {
    global OVERLAY_EDIT_MODE
    return OVERLAY_EDIT_MODE
}

StopOverlayEdit(apply := true) {
    if apply
        ApplyOverlayEdit()
    else
        CancelOverlayEdit()
}

; ---------- геометрия / экран ----------
OverlayMonitorRect(cx, cy, &l, &t, &r, &b) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        if (cx >= ml && cx < mr && cy >= mt && cy < mb) {
            l := ml
            t := mt
            r := mr
            b := mb
            return
        }
    }
    MonitorGet(MonitorGetPrimary(), &pl, &pt, &pr, &pb)
    l := pl
    t := pt
    r := pr
    b := pb
}

OverlayIsOnScreen(x, y, w, h) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &l, &t, &r, &b)
        ix := Min(x + w, r) - Max(x, l)
        iy := Min(y + h, b) - Max(y, t)
        if (ix >= 60 && iy >= 30)
            return true
    }
    return false
}

; Единое место, где решается позиция. Только ровно -1 = «авто».
; Если окно целиком вне экранов — возвращаем в правый верхний угол.
ResolveOverlayPos(W, H, &x, &y) {
    global CFG
    x := CFG["overlayX"]
    y := CFG["overlayY"]
    if (x = -1)
        x := A_ScreenWidth - W - 20
    if (y = -1)
        y := 20
    if !OverlayIsOnScreen(x, y, W, H) {
        x := A_ScreenWidth - W - 20
        y := 20
    }
}

CommitOverlayGeometry() {
    global CFG, OverlayGui, OVERLAY_EDIT_MINW, OVERLAY_EDIT_MAXW, OVERLAY_EDIT_MINH, OVERLAY_EDIT_MAXH
    if !IsObject(OverlayGui)
        return
    try {
        WinGetPos(&fx, &fy, &fw, &fh, "ahk_id " OverlayGui.Hwnd)
        if (fx = -1)
            fx := 0
        if (fy = -1)
            fy := 0
        CFG["overlayX"] := fx
        CFG["overlayY"] := fy
        CFG["overlayWidth"] := Min(Max(fw, OVERLAY_EDIT_MINW), OVERLAY_EDIT_MAXW)
        if (CFG["overlayMode"] != "mini") {
            CFG["overlayHeight"] := Min(Max(fh, OVERLAY_EDIT_MINH), OVERLAY_EDIT_MAXH)
        }
    } catch as err {
        LogLine("CommitOverlayGeometry: " err.Message)
    }
}

; ---------- визуал режима правки ----------
AddOverlayEditFrame(g, W, H) {
    t := 2
    c := "Background00D9FF"
    g.AddText("x0 y0 w" W " h" t " " c, "")
    g.AddText("x0 y" (H - t) " w" W " h" t " " c, "")
    g.AddText("x0 y0 w" t " h" H " " c, "")
    g.AddText("x" (W - t) " y0 w" t " h" H " " c, "")
    s := 10
    for cx in [0, W - s]
        for cy in [0, H - s]
            g.AddText("x" cx " y" cy " w" s " h" s " " c, "")
}

ApplyOverlayEditStyle() {
    global OverlayGui
    if !IsObject(OverlayGui)
        return
    try WinSetExStyle("-0x00000020", "ahk_id " OverlayGui.Hwnd)   ; убрать click-through
    try DllCall("SetWindowPos", "Ptr", OverlayGui.Hwnd, "Ptr", -1
        , "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0003)
}

; ---------- старт ----------
StartOverlayEdit() {
    global CFG, OVERLAY_VISIBLE, OVERLAY_EDIT_MODE, OVERLAY_EDIT_BACKUP
    global OverlayGui, OVERLAY_DRAG_MODE

    if OVERLAY_EDIT_MODE
        return

    OVERLAY_EDIT_BACKUP := Map(
        "width",      CFG["overlayWidth"],
        "height",     CFG["overlayHeight"],
        "x",          CFG["overlayX"],
        "y",          CFG["overlayY"],
        "opacity",    CFG["overlayOpacity"],
        "wasVisible", OVERLAY_VISIBLE
    )
    OVERLAY_EDIT_MODE := true
    OVERLAY_DRAG_MODE := ""

    ShowOverlay()   ; в режиме правки сам рисует рамку и снимает click-through
    if !IsObject(OverlayGui) {
        OVERLAY_EDIT_MODE := false
        return
    }

    OnMessage(0x0201, OnOverlayLButtonDown)
    OnMessage(0x0200, OnOverlayMouseMove)
    OnMessage(0x0202, OnOverlayLButtonUp)
    OnMessage(0x0020, OnOverlaySetCursor)

    CreateOverlayEditorToolbar()

    HotIf(OverlayEditActive)
    try Hotkey("$Enter",       (*) => ApplyOverlayEdit(),  "On")
    try Hotkey("$NumpadEnter", (*) => ApplyOverlayEdit(),  "On")
    try Hotkey("$Escape",      (*) => CancelOverlayEdit(), "On")
    HotIf()
}

; ---------- панель ----------
CreateOverlayEditorToolbar() {
    global OverlayEditorToolbar, OverlayEditorReadout

    if IsObject(OverlayEditorToolbar) {
        try OverlayEditorToolbar.Destroy()
        OverlayEditorToolbar := ""
    }

    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000", "UniBindOverlayTB")
    g.BackColor := "0b0f12"
    g.MarginX := 0
    g.MarginY := 0

    g.AddText("x0 y0 w360 h2 Background00d9ff", "")

    g.SetFont("s9 cA8B3BF", "Consolas")
    OverlayEditorReadout := g.AddText("x12 y6 w120 h36 BackgroundTrans", "")

    g.SetFont("s10 bold", "Segoe UI")
    bReset  := g.AddText("x136 y8 w34 h32 Center 0x200 0x100 Background0F171C cFFFFFF", "↺")
    bCancel := g.AddText("x174 y8 w80 h32 Center 0x200 0x100 Background14252D cDAE7F8", "✕ Отмена")
    bOk     := g.AddText("x258 y8 w92 h32 Center 0x200 0x100 Background00D9FF c00232B", "✓ Принять")

    bReset.OnEvent("Click",  (*) => ResetOverlayEdit())
    bCancel.OnEvent("Click", (*) => CancelOverlayEdit())
    bOk.OnEvent("Click",     (*) => ApplyOverlayEdit())

    g.Show("x0 y0 w360 h48 NoActivate")
    try WinSetRegion("0-0 w360 h48 R8-8", "ahk_id " g.Hwnd)
    OverlayEditorToolbar := g
    PlaceOverlayToolbar()
}

PlaceOverlayToolbar() {
    global OverlayEditorToolbar, OverlayEditorReadout, OverlayGui
    if !IsObject(OverlayEditorToolbar) || !IsObject(OverlayGui)
        return
    try
        WinGetPos(&ox, &oy, &ow, &oh, "ahk_id " OverlayGui.Hwnd)
    catch
        return

    tbW := 360
    tbH := 48
    OverlayMonitorRect(ox + ow // 2, oy + oh // 2, &ml, &mt, &mr, &mb)

    tx := ox + (ow - tbW) // 2
    ty := oy - tbH - 8
    if (ty < mt + 4)
        ty := oy + oh + 8
    if (ty + tbH > mb - 4)
        ty := mb - tbH - 4
    if (tx < ml + 4)
        tx := ml + 4
    if (tx + tbW > mr - 4)
        tx := mr - tbW - 4

    try DllCall("SetWindowPos", "Ptr", OverlayEditorToolbar.Hwnd, "Ptr", 0
        , "Int", tx, "Int", ty, "Int", 0, "Int", 0, "UInt", 0x0015)
    try OverlayEditorReadout.Text := ow " × " oh "`nX " ox "   Y " oy
}

; ---------- мышь ----------
OverlayRootIsOurs(hwnd) {
    global OverlayGui, OVERLAY_REBUILDING
    if OVERLAY_REBUILDING || !IsObject(OverlayGui)
        return false
    try {
        root := DllCall("GetAncestor", "Ptr", hwnd, "UInt", 2, "Ptr")
        return (root = OverlayGui.Hwnd)
    }
    return false
}

OverlayHitZone(relX, relY, w, h) {
    global CFG
    if (CFG["overlayMode"] = "mini")
        return "M"          ; мини-режим — только перемещение
    g := 8                  ; ширина боковой полосы
    c := 18                 ; размер углового квадрата
    if (relY < c && relX < c)
        return "TL"
    if (relY < c && relX >= w - c)
        return "TR"
    if (relY >= h - c && relX < c)
        return "BL"
    if (relY >= h - c && relX >= w - c)
        return "BR"
    if (relX < g)
        return "L"
    if (relX >= w - g)
        return "R"
    if (relY < g)
        return "T"
    if (relY >= h - g)
        return "B"
    return "M"
}

OverlayCursorForZone(zone) {
    switch zone {
        case "TL", "BR": return 32642   ; ↖↘
        case "TR", "BL": return 32643   ; ↗↙
        case "L", "R":   return 32644   ; ↔
        case "T", "B":   return 32645   ; ↕
        default:         return 32646   ; ✥
    }
}

OnOverlaySetCursor(wParam, lParam, msg, hwnd) {
    global OVERLAY_EDIT_MODE, OverlayGui, OVERLAY_DRAG_MODE
    if !OVERLAY_EDIT_MODE || !OverlayRootIsOurs(hwnd)
        return
    zone := OVERLAY_DRAG_MODE
    if (zone = "") {
        pt := Buffer(8)
        DllCall("GetCursorPos", "Ptr", pt)
        try
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " OverlayGui.Hwnd)
        catch
            return
        zone := OverlayHitZone(NumGet(pt, 0, "Int") - wx, NumGet(pt, 4, "Int") - wy, ww, wh)
    }
    hCur := DllCall("LoadCursor", "Ptr", 0, "Ptr", OverlayCursorForZone(zone), "Ptr")
    DllCall("SetCursor", "Ptr", hCur)
    return 1
}

OnOverlayLButtonDown(wParam, lParam, msg, hwnd) {
    global OVERLAY_EDIT_MODE, OverlayGui, OVERLAY_DRAG_MODE
    global OVERLAY_DRAG_START_X, OVERLAY_DRAG_START_Y
    global OVERLAY_DRAG_START_WX, OVERLAY_DRAG_START_WY
    global OVERLAY_DRAG_START_WW, OVERLAY_DRAG_START_WH

    if !OVERLAY_EDIT_MODE || !OverlayRootIsOurs(hwnd)
        return

    pt := Buffer(8)
    DllCall("GetCursorPos", "Ptr", pt)
    mx := NumGet(pt, 0, "Int")
    my := NumGet(pt, 4, "Int")
    try
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " OverlayGui.Hwnd)
    catch
        return

    OVERLAY_DRAG_MODE     := OverlayHitZone(mx - wx, my - wy, ww, wh)
    OVERLAY_DRAG_START_X  := mx
    OVERLAY_DRAG_START_Y  := my
    OVERLAY_DRAG_START_WX := wx
    OVERLAY_DRAG_START_WY := wy
    OVERLAY_DRAG_START_WW := ww
    OVERLAY_DRAG_START_WH := wh

    DllCall("SetCapture", "Ptr", OverlayGui.Hwnd)
    return 0
}

OnOverlayMouseMove(wParam, lParam, msg, hwnd) {
    global OVERLAY_DRAG_MODE, OVERLAY_EDIT_MODE, OverlayGui
    global OVERLAY_DRAG_START_X, OVERLAY_DRAG_START_Y
    global OVERLAY_DRAG_START_WX, OVERLAY_DRAG_START_WY
    global OVERLAY_DRAG_START_WW, OVERLAY_DRAG_START_WH
    global OVERLAY_EDIT_MINW, OVERLAY_EDIT_MAXW, OVERLAY_EDIT_MINH, OVERLAY_EDIT_MAXH

    if (OVERLAY_DRAG_MODE = "" || !OVERLAY_EDIT_MODE || !IsObject(OverlayGui))
        return
    if !GetKeyState("LButton", "P") {      ; кнопку отпустили вне окна
        OverlayEndDrag()
        return
    }

    pt := Buffer(8)
    DllCall("GetCursorPos", "Ptr", pt)
    dx := NumGet(pt, 0, "Int") - OVERLAY_DRAG_START_X
    dy := NumGet(pt, 4, "Int") - OVERLAY_DRAG_START_Y

    mode := OVERLAY_DRAG_MODE
    nx := OVERLAY_DRAG_START_WX
    ny := OVERLAY_DRAG_START_WY
    nw := OVERLAY_DRAG_START_WW
    nh := OVERLAY_DRAG_START_WH

    vx := SysGet(76)
    vy := SysGet(77)
    vr := vx + SysGet(78)
    vb := vy + SysGet(79)

    if (mode = "M") {
        nx += dx
        ny += dy

        ; прилипание к краям монитора (отступ 16, зажми Ctrl чтобы отключить)
        if !GetKeyState("Ctrl", "P") {
            OverlayMonitorRect(nx + nw // 2, ny + nh // 2, &ml, &mt, &mr, &mb)
            m := 16
            s := 12
            if (Abs(nx - (ml + m)) <= s)
                nx := ml + m
            else if (Abs(nx + nw - (mr - m)) <= s)
                nx := mr - m - nw
            if (Abs(ny - (mt + m)) <= s)
                ny := mt + m
            else if (Abs(ny + nh - (mb - m)) <= s)
                ny := mb - m - nh
        }
        ; держим окно целиком на экране — больше нельзя «потерять» оверлей
        if (nx < vx)
            nx := vx
        if (nx + nw > vr)
            nx := vr - nw
        if (ny < vy)
            ny := vy
        if (ny + nh > vb)
            ny := vb - nh
    } else {
        if InStr(mode, "L") {
            nx := OVERLAY_DRAG_START_WX + dx
            nw := OVERLAY_DRAG_START_WW - dx
        }
        if InStr(mode, "R")
            nw := OVERLAY_DRAG_START_WW + dx
        if InStr(mode, "T") {
            ny := OVERLAY_DRAG_START_WY + dy
            nh := OVERLAY_DRAG_START_WH - dy
        }
        if InStr(mode, "B")
            nh := OVERLAY_DRAG_START_WH + dy

        if (nw < OVERLAY_EDIT_MINW) {
            if InStr(mode, "L")
                nx := OVERLAY_DRAG_START_WX + OVERLAY_DRAG_START_WW - OVERLAY_EDIT_MINW
            nw := OVERLAY_EDIT_MINW
        }
        if (nw > OVERLAY_EDIT_MAXW) {
            if InStr(mode, "L")
                nx := OVERLAY_DRAG_START_WX + OVERLAY_DRAG_START_WW - OVERLAY_EDIT_MAXW
            nw := OVERLAY_EDIT_MAXW
        }
        if (nh < OVERLAY_EDIT_MINH) {
            if InStr(mode, "T")
                ny := OVERLAY_DRAG_START_WY + OVERLAY_DRAG_START_WH - OVERLAY_EDIT_MINH
            nh := OVERLAY_EDIT_MINH
        }
        if (nh > OVERLAY_EDIT_MAXH) {
            if InStr(mode, "T")
                ny := OVERLAY_DRAG_START_WY + OVERLAY_DRAG_START_WH - OVERLAY_EDIT_MAXH
            nh := OVERLAY_EDIT_MAXH
        }
        if (nx < vx) {
            nw -= (vx - nx)
            nx := vx
        }
        if (ny < vy) {
            nh -= (vy - ny)
            ny := vy
        }
        if (nx + nw > vr)
            nw := vr - nx
        if (ny + nh > vb)
            nh := vb - ny
    }

    DllCall("SetWindowPos", "Ptr", OverlayGui.Hwnd, "Ptr", 0
        , "Int", nx, "Int", ny, "Int", nw, "Int", nh, "UInt", 0x0014)
    if (mode != "M")
        try WinSetRegion("0-0 w" nw " h" nh " R10-10", "ahk_id " OverlayGui.Hwnd)
    PlaceOverlayToolbar()
    return 0
}

OnOverlayLButtonUp(wParam, lParam, msg, hwnd) {
    global OVERLAY_DRAG_MODE
    if (OVERLAY_DRAG_MODE = "")
        return
    OverlayEndDrag()
    return 0
}

OverlayEndDrag() {
    global OVERLAY_DRAG_MODE
    mode := OVERLAY_DRAG_MODE
    OVERLAY_DRAG_MODE := ""
    DllCall("ReleaseCapture")
    CommitOverlayGeometry()
    ; при изменении размера содержимое нужно перестроить под новую ширину/высоту
    if (mode != "M" && mode != "")
        SetTimer(OverlayRelayoutTick, -10)
    else
        PlaceOverlayToolbar()
}

OverlayRelayoutTick(*) {
    global OVERLAY_EDIT_MODE
    if !OVERLAY_EDIT_MODE
        return
    ShowOverlay()
    PlaceOverlayToolbar()
}

ResetOverlayEdit() {
    global CFG, OVERLAY_EDIT_MODE
    if !OVERLAY_EDIT_MODE
        return
    CFG["overlayWidth"]  := 260
    CFG["overlayHeight"] := -1
    CFG["overlayX"]      := -1
    CFG["overlayY"]      := 20
    ShowOverlay()
    PlaceOverlayToolbar()
}

; ---------- выход из режима ----------
LeaveOverlayEditMode(restoreVisibility := true) {
    global OVERLAY_EDIT_MODE, OVERLAY_EDIT_BACKUP, OVERLAY_DRAG_MODE, OverlayEditorToolbar

    OVERLAY_EDIT_MODE := false
    if (OVERLAY_DRAG_MODE != "") {
        OVERLAY_DRAG_MODE := ""
        try DllCall("ReleaseCapture")
    }

    OnMessage(0x0201, OnOverlayLButtonDown, 0)
    OnMessage(0x0200, OnOverlayMouseMove, 0)
    OnMessage(0x0202, OnOverlayLButtonUp, 0)
    OnMessage(0x0020, OnOverlaySetCursor, 0)

    HotIf(OverlayEditActive)
    try Hotkey("$Enter", "Off")
    try Hotkey("$NumpadEnter", "Off")
    try Hotkey("$Escape", "Off")
    HotIf()

    if IsObject(OverlayEditorToolbar) {
        try OverlayEditorToolbar.Destroy()
        OverlayEditorToolbar := ""
    }

    ; пересоздаём оверлей уже без рамки и с вернувшимся click-through
    wasVisible := OVERLAY_EDIT_BACKUP.Has("wasVisible") ? OVERLAY_EDIT_BACKUP["wasVisible"] : true
    if (restoreVisibility && !wasVisible)
        HideOverlay()
    else
        ShowOverlay()
}

FocusMainWindow(*) {
    global MyGui, wvc
    try {
        WinRestore("ahk_id " MyGui.Hwnd)
        WinActivate("ahk_id " MyGui.Hwnd)
    }
    try wvc.MoveFocus(0)   ; вернуть фокус клавиатуры и колеса в WebView2
}


ApplyOverlayEdit() {
    global OVERLAY_EDIT_MODE, CFG, CONFIG_FILE, wv

    if !OVERLAY_EDIT_MODE
        return

    CommitOverlayGeometry()   ; берём фактическое окно, а не то, что в CFG
    LogLine("ApplyOverlayEdit: X=" CFG["overlayX"] " Y=" CFG["overlayY"]
        " W=" CFG["overlayWidth"] " H=" CFG["overlayHeight"])

    try {
        IniSetSafe(CONFIG_FILE, "Overlay", "width",   CFG["overlayWidth"])
        IniSetSafe(CONFIG_FILE, "Overlay", "height",  CFG["overlayHeight"])
        IniSetSafe(CONFIG_FILE, "Overlay", "x",       CFG["overlayX"])
        IniSetSafe(CONFIG_FILE, "Overlay", "y",       CFG["overlayY"])
    } catch as err {
        LogLine("ApplyOverlayEdit: IniSetSafe failed: " err.Message)
    }

    LeaveOverlayEditMode()
    SendNotify("✓ Позиция и размер оверлея сохранены", "success")
    PushDataToHtml()
    if wv
        try wv.PostWebMessageAsString("overlay_edit_stopped:1:" CFG["overlayX"] "," CFG["overlayY"]
            . "," CFG["overlayWidth"] "," CFG["overlayHeight"])
    SetTimer(FocusMainWindow, -150)
}

CancelOverlayEdit() {
    global OVERLAY_EDIT_MODE, CFG, OVERLAY_EDIT_BACKUP, wv

    if !OVERLAY_EDIT_MODE
        return

    CFG["overlayWidth"]   := OVERLAY_EDIT_BACKUP["width"]
    CFG["overlayHeight"]  := OVERLAY_EDIT_BACKUP["height"]
    CFG["overlayX"]       := OVERLAY_EDIT_BACKUP["x"]
    CFG["overlayY"]       := OVERLAY_EDIT_BACKUP["y"]
    CFG["overlayOpacity"] := OVERLAY_EDIT_BACKUP["opacity"]

    LeaveOverlayEditMode()
    SendNotify("Изменения отменены", "info")
    PushDataToHtml()
    if wv
        try wv.PostWebMessageAsString("overlay_edit_stopped:0")
    SetTimer(FocusMainWindow, -150)
}


; Отображаем зарегистрированное назначение, затем CFG. Не выдумываем F10/M/P.
OverlayShortcutLabel(cfgKey, utilKey) {
    global CFG, UTILITY_HOTKEYS
    raw := ""
    if (UTILITY_HOTKEYS.Has(utilKey) && UTILITY_HOTKEYS[utilKey] != "")
        raw := RegExReplace(UTILITY_HOTKEYS[utilKey], "^[~*$]+", "")
    else if CFG.Has(cfgKey)
        raw := Trim(CFG[cfgKey])
    if (raw = "")
        return "Нет"
    label := FormatOverlayHotkey(raw)
    return label != "" ? label : raw
}

; Размеры измеряются тем же шрифтом, которым рисуются клавиши.
OverlayMeasureText(text, width := 0) {
    scale := A_ScreenDPI / 96
    dc := DllCall("user32\GetDC", "Ptr", 0, "Ptr")
    font := DllCall("gdi32\CreateFontW", "Int", -Round(8 * A_ScreenDPI / 72), "Int", 0, "Int", 0, "Int", 0, "Int", 700, "UInt", 0, "UInt", 0, "UInt", 0, "UInt", 1, "UInt", 0, "UInt", 0, "UInt", 5, "UInt", 0, "Str", "Segoe UI", "Ptr")
    if (!dc || !font) {
        if dc
            DllCall("user32\ReleaseDC", "Ptr", 0, "Ptr", dc)
        if font
            DllCall("gdi32\DeleteObject", "Ptr", font)
        return width > 0 ? 40 : StrLen(text) * 8
    }
    previous := DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", font, "Ptr")
    try {
        if (width > 0) {
            rect := Buffer(16, 0)
            NumPut("Int", Round(width * scale), rect, 8)
            DllCall("user32\DrawTextW", "Ptr", dc, "Str", text, "Int", StrLen(text), "Ptr", rect, "UInt", 0xC10)
            return Ceil(NumGet(rect, 12, "Int") / scale)
        }
        size := Buffer(8, 0)
        DllCall("gdi32\GetTextExtentPoint32W", "Ptr", dc, "Str", text, "Int", StrLen(text), "Ptr", size)
        return Ceil(NumGet(size, 0, "Int") / scale)
    } finally {
        DllCall("gdi32\SelectObject", "Ptr", dc, "Ptr", previous)
        DllCall("gdi32\DeleteObject", "Ptr", font)
        DllCall("user32\ReleaseDC", "Ptr", 0, "Ptr", dc)
    }
}

OverlayWindowExists(g) {
    try {
        return IsObject(g) && DllCall("user32\IsWindow", "Ptr", g.Hwnd, "Int")
    } catch {
        return false
    }
}

ShowOverlay() {
    global OverlayGui, OVERLAY_VISIBLE, OVERLAY_REBUILDING, OVERLAY_CACHE, CFG, OVERLAY_EDIT_MODE
    previousCritical := A_IsCritical
    Critical "On"
    if OVERLAY_REBUILDING {
        Critical previousCritical
        return false
    }
    OVERLAY_REBUILDING := true
    SetTimer(OverlayTick, 0)
    oldGui := OverlayGui
    ; Detach first: a destroyed Gui object is still IsObject(), but has no Hwnd.
    OverlayGui := ""
    OVERLAY_VISIBLE := false
    OVERLAY_CACHE := Map()
    success := false
    try {
        if (CFG["overlayMode"] = "mini")
            BuildOverlayMini()
        else
            BuildOverlayFull()
        if !OverlayWindowExists(OverlayGui)
            throw Error("Окно оверлея не создано")
        ; Populate while hidden. Geometry, opacity and rounded region are already set.
        OVERLAY_VISIBLE := true
        OVERLAY_REBUILDING := false
        if !UpdateOverlay()
            throw Error("Не удалось нарисовать первый кадр оверлея")
        OverlayGui.Show("NoActivate")
        if OVERLAY_EDIT_MODE
            ApplyOverlayEditStyle()
        success := true
    } catch as err {
        failedGui := OverlayGui
        OverlayGui := ""
        OVERLAY_VISIBLE := false
        if IsObject(failedGui)
            try failedGui.Destroy()
        LogLine("ShowOverlay error: " err.Message)
        SendNotify("Не удалось обновить оверлей. Подробности в журнале.", "error")
    } finally {
        if IsObject(oldGui)
            try oldGui.Destroy()
        OVERLAY_REBUILDING := false
        if success
            SetTimer(OverlayTick, 500)
        Critical previousCritical
    }
    SendOverlayState()
    return success
}

BuildOverlayFull() {
    NeonCreateOverlay(false)
}

BuildOverlayMini() {
    NeonCreateOverlay(true)
}

ToggleOverlayMode() {
    global CFG, OVERLAY_VISIBLE, CONFIG_FILE, OVERLAY_EDIT_MODE
    if !OVERLAY_VISIBLE || OVERLAY_EDIT_MODE
        return
    CFG["overlayMode"] := (CFG["overlayMode"] = "mini") ? "full" : "mini"
    try IniSetSafe(CONFIG_FILE, "Overlay", "mode", CFG["overlayMode"])
    ShowOverlay()
    PushDataToHtml()    ; чтобы список в настройках показывал актуальный режим
}

HideOverlay() {
    global OverlayGui, OVERLAY_VISIBLE, OVERLAY_ID_INPUT_MODE, OVERLAY_ID_HOOK, OVERLAY_ID_INPUT, OVERLAY_PREVIEW, OVERLAY_CACHE
    previousCritical := A_IsCritical
    Critical "On"
    try {
        SetTimer(OverlayTick, 0)
        OVERLAY_VISIBLE := false
        oldGui := OverlayGui
        OverlayGui := ""
        OVERLAY_CACHE := Map()
        OVERLAY_ID_INPUT_MODE := false
        OVERLAY_ID_INPUT := ""
        if OVERLAY_ID_HOOK {
            try OVERLAY_ID_HOOK.Stop()
            OVERLAY_ID_HOOK := ""
        }
        OVERLAY_PREVIEW := false
        if IsObject(oldGui)
            try oldGui.Destroy()
    } finally {
        Critical previousCritical
    }
    SendOverlayState()
}

RefreshOverlayBinds() {
    global SLOTS, OVERLAY_BINDS, OVERLAY_TOTAL
    binds := []
    Loop 100 {
        slot := SLOTS[A_Index]
        if !slot["enabled"] || slot["lines"].Length = 0
            continue
        if (slot.Has("showInOverlay") && !slot["showInOverlay"])
            continue
        item := Map("slotIdx", A_Index, "name", slot["name"], "hotkey", slot["hotkey"], "sortOrder", slot.Has("sortOrder") ? slot["sortOrder"] : A_Index)
        pos := binds.Length + 1
        while (pos > 1 && binds[pos - 1]["sortOrder"] > item["sortOrder"])
            pos--
        binds.InsertAt(pos, item)
    }
    OVERLAY_BINDS := binds
    OVERLAY_TOTAL := binds.Length
    SyncOverlaySelection()
}

GetOverlayOpacity() {
    global CFG, OVERLAY_OPACITY_PREVIEW
    return Min(255, Max(80, OVERLAY_OPACITY_PREVIEW >= 0 ? OVERLAY_OPACITY_PREVIEW : CFG["overlayOpacity"]))
}

ApplyOverlayOpacityPreview() {
    global OVERLAY_OPACITY_PREVIEW_PENDING, OVERLAY_VISIBLE
    OVERLAY_OPACITY_PREVIEW_PENDING := false
    LogLine("Opacity preview: alpha=" GetOverlayOpacity() " visible=" (OVERLAY_VISIBLE ? 1 : 0))
    UpdateOverlay()
}

ClearOverlayOpacityPreview() {
    global OVERLAY_OPACITY_PREVIEW, OVERLAY_OPACITY_PREVIEW_PENDING
    SetTimer(ApplyOverlayOpacityPreview, 0)
    OVERLAY_OPACITY_PREVIEW_PENDING := false
    OVERLAY_OPACITY_PREVIEW := -1
    UpdateOverlay()
}

UpdateOverlay() {
    global OverlayGui, STATE, OVERLAY_VISIBLE, OVERLAY_PAGE, OVERLAY_MAX_PAGES, OVERLAY_TOTAL, OVERLAY_SELECTED, OVERLAY_BINDS, CFG, OVERLAY_CACHE, OVERLAY_ID_INPUT_MODE, OVERLAY_INDEX, OVERLAY_REBUILDING, OVERLAY_ID_INPUT, BINDER_ENABLED, OVERLAY_EDIT_MODE
    previousCritical := A_IsCritical
    Critical "On"
    try {
        if OVERLAY_REBUILDING || !OVERLAY_VISIBLE
            return
        g := OverlayGui
        if !OverlayWindowExists(g) {
            ; Safe even when an old callback holds a destroyed Gui reference.
            OVERLAY_VISIBLE := false
            OverlayGui := ""
            OVERLAY_CACHE := Map()
            SetTimer(OverlayTick, 0)
            return
        }
        ; HWND access, if ever needed, belongs inside this guarded try, not above it.
        ; Do not use WM_SETREDRAW: it toggles WS_VISIBLE and flashes layered overlays.
        ; Do not invalidate or erase the complete window on a clock tick.
        frame := Map()
        if OVERLAY_ID_INPUT_MODE {
            frame["OverlayPatient"] := OVERLAY_ID_INPUT "│"
        } else {
            pid := STATE["targetId"]
            frame["OverlayPatient"] := CFG["showIdInOverlay"] ? (pid = "" ? "—" : "#" pid) : "ID скрыт"
        }
        frame["NeonOpacity"] := GetOverlayOpacity()
        frame["NeonActive"] := BINDER_ENABLED
        frame["NeonEdit"] := OVERLAY_EDIT_MODE
        frame["OverlayTargetLabel"] := OVERLAY_ID_INPUT_MODE ? "ВВОД ID" : "ЦЕЛЬ"
        frame["OverlayTime"] := FormatTime(A_Now, "HH:mm:ss")
        full := CFG["overlayMode"] != "mini"
        if full {
            RefreshOverlayBinds()
            frame["OvPage"] := Format("{:02}", OVERLAY_PAGE) " / " Format("{:02}", OVERLAY_MAX_PAGES)
            frame["NeonProgress"] := OVERLAY_TOTAL ? OVERLAY_PAGE / Max(1, OVERLAY_MAX_PAGES) : 0
            frame["OvCount"] := "БИНДЫ · " (OVERLAY_TOTAL ? OVERLAY_INDEX : 0) "/" OVERLAY_TOTAL
            frame["emptyVisible"] := OVERLAY_TOTAL = 0
            startIdx := (OVERLAY_PAGE - 1) * 10 + 1
            Loop 10 {
                i := A_Index
                idx := startIdx + i - 1
                valid := idx <= OVERLAY_TOTAL
                selected := valid && i = OVERLAY_SELECTED
                frame["OvMark" i] := selected ? "›" : ""
                frame["OvHk" i] := valid ? FormatOverlayHotkey(OVERLAY_BINDS[idx]["hotkey"]) : ""
                frame["OvName" i] := valid ? OVERLAY_BINDS[idx]["name"] : ""
                frame["rowSelected" i] := selected
                frame["rowValid" i] := valid
            }
        }
        dirty := false
        for key, value in frame {
            if (!OVERLAY_CACHE.Has(key) || !(OVERLAY_CACHE[key] == value)) {
                dirty := true
                break
            }
        }
        if !dirty {
            SendOverlayNavigationState()
            return true
        }
        ; All vector elements are composed off-screen. Publish exactly one complete frame.
        NeonPaint(g, frame)
        OVERLAY_CACHE := frame.Clone()
        SendOverlayNavigationState()
        return true
    } catch as err {
        LogLine("UpdateOverlay error: " err.Message)
        return false
    } finally {
        Critical previousCritical
    }
}

; ============================================
;  СТАТИСТИКА
; ============================================
IncrementStat(statKey) {
    global STATS, CONFIG_FILE
    if STATS.Has(statKey) {
        STATS[statKey] += 1
        try IniSetSafe(CONFIG_FILE, "Stats", statKey, STATS[statKey])
    }
}

ResetStats() {
    global STATS, CONFIG_FILE, wv
    for k, _ in STATS
        STATS[k] := 0
    for k, _ in STATS
        try IniSetSafe(CONFIG_FILE, "Stats", k, 0)
    UpdateOverlay()
    try wv.PostWebMessageAsString("stats_reset")
    SendNotify("Статистика сброшена", "success")
}

; ============================================
;  UTILITY-ХОТКЕИ
; ============================================
RegisterStopHotkey(silent := false) {
    global CFG
    return RegisterUtilityHotkey("stop", CFG["stopHotkey"], (*) => StopSending(), silent)
}
StopSending() {
    global IS_SENDING, SEND_TOKEN
    if !IS_SENDING
        return
    IS_SENDING := false
    SEND_TOKEN += 1
    try BlockInput("Off")
    SendNotify("⏹ Отправка остановлена", "warning")
    SendStatus()
}
RegisterOverlayHotkey(silent := false) {
    global CFG
    return RegisterUtilityHotkey("overlay", CFG["overlayHotkey"], (*) => ToggleOverlay(), silent)
}
RegisterIdInputHotkey(silent := false) {
    global CFG
    return RegisterUtilityHotkey("id", CFG["idInputHotkey"], (*) => StartOverlayIdInput(), silent)
}
RegisterOverlayModeHotkey(silent := false) {
    global CFG
    return RegisterUtilityHotkey("mode", CFG["overlayModeHotkey"], (*) => ToggleOverlayModeHotkey(), silent)
}

ToggleOverlayModeHotkey() {
    if OverlayUtilityActive()
        ToggleOverlayMode()
}

StartOverlayIdInput() {
    global OVERLAY_VISIBLE, OVERLAY_ID_INPUT_MODE, OVERLAY_ID_INPUT, OVERLAY_ID_HOOK, OverlayGui, OVERLAY_CACHE
    if !OverlayUtilityActive()
        return
    OVERLAY_ID_INPUT_MODE := true
    OVERLAY_ID_INPUT := ""

    OVERLAY_CACHE["OverlayPatient"] := "__input__"
    OVERLAY_CACHE["OverlayTargetLabel"] := "__input__"
    UpdateOverlay()

    if OVERLAY_ID_HOOK
        try OVERLAY_ID_HOOK.Stop()

    OVERLAY_ID_HOOK := InputHook("L0")
    OVERLAY_ID_HOOK.KeyOpt("0123456789", "NS")
    OVERLAY_ID_HOOK.KeyOpt("{Numpad0}{Numpad1}{Numpad2}{Numpad3}{Numpad4}{Numpad5}{Numpad6}{Numpad7}{Numpad8}{Numpad9}", "NS")
    OVERLAY_ID_HOOK.KeyOpt("{BackSpace}{Enter}{NumpadEnter}{Escape}", "NS")
    OVERLAY_ID_HOOK.OnKeyDown := OverlayIdInputHandler
    OVERLAY_ID_HOOK.Start()
}

; Навигационные scan codes не зависят от RU/EN и NumLock.
; При включённом NumLock Num2/Num8 остаются биндами, а не стрелками.
#HotIf OverlayNavigationActive()
*$sc148:: OverlayMoveSel(-1)   ; ↑
*$sc150:: OverlayMoveSel(1)    ; ↓
*$sc14B:: OverlayPage(-1)      ; ←
*$sc14D:: OverlayPage(1)       ; →
*$sc149:: OverlayPage(-1)      ; PgUp
*$sc151:: OverlayPage(1)       ; PgDn
*$NumpadUp:: OverlayMoveSel(-1)
*$NumpadDown:: OverlayMoveSel(1)
*$NumpadLeft:: OverlayPage(-1)
*$NumpadRight:: OverlayPage(1)
*$NumpadPgUp:: OverlayPage(-1)
*$NumpadPgDn:: OverlayPage(1)
*$sc147:: OverlaySelectBoundary(false)
*$sc14F:: OverlaySelectBoundary(true)
$Enter:: OverlayRunSelected()
$NumpadEnter:: OverlayRunSelected()
$1:: OverlayRunByNum(1)
$2:: OverlayRunByNum(2)
$3:: OverlayRunByNum(3)
$4:: OverlayRunByNum(4)
$5:: OverlayRunByNum(5)
$6:: OverlayRunByNum(6)
$7:: OverlayRunByNum(7)
$8:: OverlayRunByNum(8)
$9:: OverlayRunByNum(9)
$0:: OverlayRunByNum(10)
#HotIf OverlayUtilityActive()
$sc02E:: ClearOverlayTarget()
$Escape:: HideOverlay()
#HotIf

OverlayMoveSel(dir) {
    global OVERLAY_INDEX, OVERLAY_TOTAL
    if !OverlayNavigationReady()
        return
    RefreshOverlayBinds()
    OVERLAY_INDEX := OverlayClampIndex(OVERLAY_INDEX + dir, OVERLAY_TOTAL)
    SyncOverlaySelection()
    LogLine("OverlayMoveSel: dir=" dir " index=" OVERLAY_INDEX " total=" OVERLAY_TOTAL)
    UpdateOverlay()
}

OverlayPage(dir) {
    global OVERLAY_INDEX, OVERLAY_TOTAL
    if !OverlayNavigationReady()
        return
    RefreshOverlayBinds()
    OVERLAY_INDEX := OverlayPageIndex(OVERLAY_INDEX, OVERLAY_TOTAL, dir)
    SyncOverlaySelection()
    LogLine("OverlayPage: dir=" dir " index=" OVERLAY_INDEX " total=" OVERLAY_TOTAL)
    UpdateOverlay()
}

OverlaySelectBoundary(last) {
    global OVERLAY_INDEX, OVERLAY_TOTAL
    if !OverlayNavigationReady()
        return
    RefreshOverlayBinds()
    OVERLAY_INDEX := last ? Max(1, OVERLAY_TOTAL) : 1
    SyncOverlaySelection()
    UpdateOverlay()
}

OverlayIdInputHandler(ih, vk, sc) {
    global OVERLAY_ID_INPUT, OVERLAY_ID_INPUT_MODE, OVERLAY_ID_HOOK, STATE, OverlayGui, OVERLAY_CACHE

    if (vk = 0x0D) {
        OVERLAY_ID_INPUT_MODE := false
        try OVERLAY_ID_HOOK.Stop()
        STATE["targetId"] := OVERLAY_ID_INPUT
        OVERLAY_CACHE["OverlayPatient"] := ""
        SendNotify(STATE["targetId"] != "" ? "ID цели: #" STATE["targetId"] : "ID очищен",
                   STATE["targetId"] != "" ? "success" : "info")
        PushDataToHtml()
        UpdateOverlay()
        return
    }
    if (vk = 0x1B) {
        OVERLAY_ID_INPUT_MODE := false
        try OVERLAY_ID_HOOK.Stop()
        OVERLAY_CACHE["OverlayPatient"] := ""
        UpdateOverlay()
        return
    }
    if (vk = 0x08) {
        if (StrLen(OVERLAY_ID_INPUT) > 0) {
            OVERLAY_ID_INPUT := SubStr(OVERLAY_ID_INPUT, 1, -1)
            UpdateOverlay()
        }
        return
    }

    digit := ""
    if (vk >= 0x30 && vk <= 0x39)
        digit := Chr(vk)
    else if (vk >= 0x60 && vk <= 0x69)
        digit := Chr(vk - 0x60 + 0x30)

    if (digit != "" && StrLen(OVERLAY_ID_INPUT) < 5) {
        OVERLAY_ID_INPUT .= digit
        UpdateOverlay()
    }
}

OverlayRunSelected() {
    global OVERLAY_INDEX, OVERLAY_TOTAL, OVERLAY_BINDS, OVERLAY_PREVIEW, CFG
    if !OverlayNavigationReady()
        return
    UpdateOverlay()
    if (OVERLAY_TOTAL < 1 || OVERLAY_INDEX > OVERLAY_BINDS.Length)
        return
    if OVERLAY_PREVIEW {
        SendNotify("Предпросмотр: выбран «" OVERLAY_BINDS[OVERLAY_INDEX]["name"] "». Для отправки закройте предпросмотр и откройте оверлей горячей клавишей.", "info")
        return
    }
    if (CFG["onlyGTA"] && !WinActive("ahk_exe gta_sa.exe")) {
        SendNotify("Для запуска бинда активируйте окно GTA. Навигация доступна и без игры.", "warning")
        return
    }
    RunSlotByNum(OVERLAY_BINDS[OVERLAY_INDEX]["slotIdx"], false)
}

OverlayRunByNum(n) {
    global OVERLAY_PAGE, OVERLAY_TOTAL, OVERLAY_INDEX
    if !OverlayNavigationReady() || n < 1 || n > 10
        return
    RefreshOverlayBinds()
    index := (OVERLAY_PAGE - 1) * 10 + n
    if (index > OVERLAY_TOTAL)
        return
    OVERLAY_INDEX := index
    SyncOverlaySelection()
    UpdateOverlay()
    OverlayRunSelected()
}

PasteIntoField() {
    try SendInput("^v")
}

; ============================================
;  ЭКСПОРТ / ИМПОРТ
; ============================================
ExportConfig() {
    global CONFIG_FILE, PROFILES, MyGui
    if MyGui {
        try WinRestore("ahk_id " MyGui.Hwnd)
        try WinActivate("ahk_id " MyGui.Hwnd)
    }
    path := FileSelect("S16", "UniBind_" A_YYYY "-" A_MM "-" A_DD ".UniBind", "Экспорт UniBind", "UniBind (*.UniBind; *.ini)")
    if (path = "")
        return
    if !RegExMatch(path, "i)\.(UniBind|ini)$")
        path .= ".UniBind"
    temp := CONFIG_DIR "\_export_tmp_" A_TickCount ".ini"
    try {
        SaveActiveProfileToIni()
        SaveProfilesToIni()
        settings := ReadIniRaw(CONFIG_FILE)
        out := Map("Meta", Map("formatVersion", "2027.2", "exportedAt", A_Now, "profileCount", PROFILES.Length))
        for sec in ["Settings", "Profile", "Overlay", "Variables", "Stats", "Profiles"] {
            if settings.Has(sec)
                out[sec] := settings[sec].Clone()
        }
        for i, profile in PROFILES {
            file := ProfilePath(i)
            if !FileExist(file)
                throw Error("Нет файла профиля " i "; экспорт отменён")
            raw := ReadIniRaw(file)
            for sec, values in raw {
                if (sec = "Categories" || RegExMatch(sec, "^Slot\d+$"))
                    out["P" i "_" sec] := values.Clone()
            }
        }
        WriteIniRaw(temp, out)
        problem := ValidateImportFile(temp)
        if (problem != "")
            throw Error("Экспорт не проходит обратную проверку: " problem)
        ; Refuse to overwrite application files with an export selected by the user.
        if InStr(StrLower(path), StrLower(ROOT_DIR "\")) = 1 || InStr(StrLower(path), StrLower(DATA_DIR "\")) = 1
            throw Error("Сохраните экспорт вне папок приложения и его данных")
        WriteIniRaw(path, out)
        SendNotify("✓ Экспорт сохранён", "success")
    } catch as err {
        LogLine("Export failed: " err.Message)
        SendNotify("Экспорт не выполнен: " err.Message, "error")
    } finally {
        if FileExist(temp)
            try FileDelete(temp)
    }
}

ImportConfig() {
    global CONFIG_FILE, MyGui, PENDING_IMPORT_PATH, wv
    if MyGui {
        try WinRestore("ahk_id " MyGui.Hwnd)
        try WinActivate("ahk_id " MyGui.Hwnd)
    }
    path := FileSelect("1", , "Импорт конфигурации UniBind", "UniBind Backup (*.UniBind; *.ini)")
    if (path = "")
        return
    if !FileExist(path) {
        SendNotify("Файл не найден", "error")
        return
    }
    ; --- валидация ---
    err := ValidateImportFile(path)
    if (err != "") {
        SendNotify("Ошибка импорта: " err, "error")
        return
    }
    PENDING_IMPORT_PATH := path
    try wv.PostWebMessageAsString("import_confirm:" . path)
}

ValidateImportFile(path) {
    try return ValidateImportFileContents(path)
    catch as err {
        LogLine("ValidateImportFile: " err.Message)
        return "повреждённый конфиг или некорректные числовые значения"
    }
}

ValidateImportFileContents(path) {
    size := FileGetSize(path)
    if (size < 10 || size > 16 * 1024 * 1024)
        return "недопустимый размер файла"
    return ValidateImportData(ReadIniRaw(path))
}

ValidateImportData(data) {
    try {
        fmt := IniValue(data, "Meta", "formatVersion")
        if (fmt != "" && fmt != "2027.2")
            throw ValueError("Неизвестная версия формата")
        if !data.Has("Settings")
            throw ValueError("Нет секции Settings")
        for item in [["baseDelay", 0, 60000, 2300], ["afterChatDelay", 0, 10000, 300],
            ["afterEnterDelay", 0, 10000, 400], ["jitter", 0, 10000, 0]]
            RequireInt(IniValue(data, "Settings", item[1], item[4]), item[2], item[3], item[1])
        if !RegExMatch(IniValue(data, "Settings", "chatKey", "t"), "^[A-Za-z0-9]$")
            throw ValueError("Некорректная клавиша чата")
        RequireInt(IniValue(data, "Overlay", "opacity", 235), 80, 255, "Непрозрачность")
        RequireInt(IniValue(data, "Overlay", "width", 260), 260, 600, "Ширина")
        RequireInt(IniValue(data, "Settings", "onlyGTA", 1), 0, 1, "Только GTA")
        format := IniValue(data, "Settings", "patientFormat", "plain")
        if (format != "plain" && format != "at" && format != "quote")
            throw ValueError("Некорректный формат цели")
        for key in ["hotkey", "stopHotkey", "idInputHotkey", "modeHotkey"] {
            if (ValidateHotkeyString(IniValue(data, "Overlay", key)) != "")
                throw ValueError("Некорректная служебная клавиша")
        }
        count := fmt = "" ? 0 : RequireInt(IniValue(data, "Meta", "profileCount", 0), 1, 50, "Число профилей")
        ids := Map()
        Loop count {
            i := A_Index
            id := RequireInt(IniValue(data, "Profiles", "profile" i "_id", 0), 1, 1000, "ID профиля")
            if ids.Has(id)
                throw ValueError("Повтор ID профиля")
            ids[id] := true
            prefix := "P" i "_"
            for key in ["label", "name", "hospital", "rank"]
                RequireText(IniValue(data, "Profiles", "profile" i "_" key), "Поле профиля", 256)
            catCount := RequireInt(IniValue(data, prefix "Categories", "count", 0), 0, 50, "Категории")
            catNames := Map()
            Loop catCount {
                catName := RequireText(IniValue(data, prefix "Categories", "cat" A_Index "_name"), "Категория", 256)
                if (catName = "" || catNames.Has(catName))
                    throw ValueError("Пустая или повторная категория")
                catNames[catName] := true
                RequireText(IniValue(data, prefix "Categories", "cat" A_Index "_icon"), "Иконка", 128)
            }
            Loop 100 {
                section := prefix "Slot" A_Index
                if (IniValue(data, section, "name") = "")
                    continue
                RequireText(IniValue(data, section, "name"), "Название бинда", 256)
                RequireText(IniValue(data, section, "category"), "Категория", 256)
                hk := IniValue(data, section, "hotkey")
                if (ValidateHotkeyString(hk) != "")
                    throw ValueError("Некорректная клавиша бинда")
                lines := RequireInt(IniValue(data, section, "lineCount", 0), 1, 100, "Число строк")
                Loop lines {
                    text := RequireText(IniValue(data, section, "line" A_Index "_text"), "Текст строки")
                    if (text = "")
                        throw ValueError("Пустая строка бинда")
                    RequireInt(IniValue(data, section, "line" A_Index "_delay", 0), 0, 120000, "Задержка")
                }
            }
        }
        varCount := RequireInt(IniValue(data, "Variables", "count", 0), 0, 200, "Переменные")
        varNames := Map()
        Loop varCount {
            varName := IniValue(data, "Variables", "var" A_Index "_name")
            if (!RegExMatch(varName, "^[A-Za-zА-Яа-яЁё0-9_]{1,128}$") || IsReservedVar(varName) || varNames.Has(varName))
                throw ValueError("Некорректное или повторное имя переменной")
            varNames[varName] := true
            RequireText(IniValue(data, "Variables", "var" A_Index "_value"), "Переменная")
        }
        ; Block line/section injection even in fields unknown to this version.
        for sec, values in data {
            if RegExMatch(sec, "[\[\]\r\n]")
                throw ValueError("Некорректная секция INI")
            for key, value in values {
                if RegExMatch(key, "[=\r\n]")
                    throw ValueError("Некорректный ключ INI")
                RequireText(value, "Значение INI", 4096)
            }
        }
        return ""
    } catch as err {
        return err.Message
    }
}

ApplyImportSnapshot(data) {
    global CONFIG_FILE, PROFILES_DIR, CONFIG_DIR, SKIP_PROFILE_SAVE_ON_EXIT
    problem := ValidateImportData(data)
    if (problem != "")
        throw ValueError(problem)
    base := CONFIG_DIR "\_import_sandbox_" A_Now "_" A_TickCount
    sandbox := base
    suffix := 0
    while DirExist(sandbox) {
        suffix++
        sandbox := base "_" suffix
    }
    DirCreate(sandbox)
    hadSettings := FileExist(CONFIG_FILE) ? true : false
    DirCreate(sandbox "\profiles")
    if hadSettings
        FileCopy(CONFIG_FILE, sandbox "\settings.ini.bak", 1)
    Loop Files, PROFILES_DIR "\*.ini"
        FileCopy(A_LoopFileFullPath, sandbox "\profiles\" A_LoopFileName, 1)
    try {
        if (IniValue(data, "Meta", "formatVersion") = "") {
            WriteIniRaw(CONFIG_FILE, data)
        } else {
            count := Integer(IniValue(data, "Meta", "profileCount"))
            settings := Map()
            for sec in ["Settings", "Profile", "Overlay", "Variables", "Stats", "Profiles"] {
                if data.Has(sec)
                    settings[sec] := data[sec].Clone()
            }
            settings["Profiles"]["count"] := count
            settings["Profiles"]["active"] := 1
            maxId := 0
            Loop count {
                i := A_Index
                id := Integer(IniValue(data, "Profiles", "profile" i "_id"))
                maxId := Max(maxId, id)
                raw := Map("Categories", Map("count", 0))
                for sec, values in data {
                    prefix := "P" i "_"
                    if (SubStr(sec, 1, StrLen(prefix)) = prefix) {
                        bare := SubStr(sec, StrLen(prefix) + 1)
                        if (bare = "Categories" || RegExMatch(bare, "^Slot\d+$"))
                            raw[bare] := values.Clone()
                    }
                }
                WriteIniRaw(PROFILES_DIR "\P" id ".ini", raw)
            }
            settings["Profiles"]["nextId"] := maxId + 1
            ; Profile files are durable before the index is switched.
            WriteIniRaw(CONFIG_FILE, settings)
            ; Old unindexed profiles remain as recovery data, not silently deleted.
        }
    } catch as err {
        rollbackOK := true
        try {
            if hadSettings
                FileCopy(sandbox "\settings.ini.bak", CONFIG_FILE, 1)
            else if FileExist(CONFIG_FILE)
                FileDelete(CONFIG_FILE)
            Loop Files, PROFILES_DIR "\*.ini"
                FileDelete(A_LoopFileFullPath)
            Loop Files, sandbox "\profiles\*.ini"
                FileCopy(A_LoopFileFullPath, PROFILES_DIR "\" A_LoopFileName, 1)
        } catch as rollbackError {
            rollbackOK := false
            LogLine("Import rollback failed: " rollbackError.Message)
        }
        if !rollbackOK
            SKIP_PROFILE_SAVE_ON_EXIT := true
        throw Error(err.Message "`nСнимок: " sandbox "`nОткат: " (rollbackOK ? "выполнен" : "НЕ ПОЛНЫЙ — восстановите вручную"))
    }
    return sandbox
}

ImportConfigConfirmed() {
    global PENDING_IMPORT_PATH, SKIP_PROFILE_SAVE_ON_EXIT, SEND_BUSY, CFG
    path := PENDING_IMPORT_PATH
    PENDING_IMPORT_PATH := ""
    if (path = "")
        return
    if SEND_BUSY {
        SendNotify("Остановите отправку перед импортом", "warning")
        return
    }
    try {
        ; Read and validate once: the reviewed snapshot is the applied snapshot.
        size := FileGetSize(path)
        if (size < 10 || size > 16 * 1024 * 1024)
            throw ValueError("Недопустимый размер файла")
        data := ReadIniRaw(path)
        ; Чужой файл не должен молча снимать защиту «биндер работает только в GTA».
        if (CFG["onlyGTA"] && data.Has("Settings") && IniValue(data, "Settings", "onlyGTA", "1") = "0") {
            data["Settings"]["onlyGTA"] := "1"
            LogLine("Import: onlyGTA=0 из файла проигнорировано, режим «только GTA» сохранён")
        }
        Critical("On")
        try {
            SaveActiveProfileToIni()
            SaveProfilesToIni()
            ApplyImportSnapshot(data)
            SKIP_PROFILE_SAVE_ON_EXIT := true
        } finally {
            Critical("Off")
        }
        Reload()
    } catch as err {
        LogLine("Import failed: " err.Message)
        MsgBox("Импорт не выполнен. " err.Message, "UniBind — импорт", "IconX")
    }
}

ImportConfigCancelled() {
    global PENDING_IMPORT_PATH
    PENDING_IMPORT_PATH := ""
}

; ============================================
;  ГЛОБАЛЬНЫЕ ХОТКЕИ
; ============================================
; Escape в главном окне обрабатывает ui.html: сначала закрываются диалоги.


^!q::ExitApp()


ValidateUiBuild() {
    global HTML_FILE
    try {
        if (NeonBuildVersion() != "2027.10")
            throw Error("Обновите lib\UniBindNeon.ahk до версии 2027.10")
        html := FileRead(HTML_FILE, "UTF-8")
        if InStr(html, 'name="unibind-ui-build" content="2027.10"')
            return true
        message := "UniBind: AHK и интерфейс разных версий."
        message .= "`nЗамените UniBind.ahk, ui\ui.html и lib\UniBindNeon.ahk из архива 2027.10."
        message .= "`n`nПроверенный путь: " HTML_FILE
        MsgBox(message, "UniBind — обновите интерфейс", "Icon!")
    } catch as err {
        MsgBox("Не удалось прочитать интерфейс: " err.Message, "UniBind", "Iconx")
    }
    return false
}


RunOverlayGuiSmokeTests() {
    global CFG, SLOTS, STATE, OverlayGui, OVERLAY_VISIBLE
    failures := []
    checks := 0
    STATE["targetId"] := "42"
    Loop 35 {
        SLOTS[A_Index]["enabled"] := true
        SLOTS[A_Index]["name"] := "Тест " A_Index
        SLOTS[A_Index]["hotkey"] := "!" Mod(A_Index, 10)
        SLOTS[A_Index]["lines"] := [Map("text", "test", "delay", 0)]
    }
    try {
        Loop 3 {
            for mode in ["full", "mini"] {
                for hints in ["all", "full", "none"] {
                    CFG["overlayMode"] := mode
                    CFG["overlayHints"] := hints
                    checks++
                    if !ShowOverlay() || !OverlayWindowExists(OverlayGui)
                        failures.Push("Create " mode "/" hints)
                    UpdateOverlay()
                    if (mode = "full") {
                        OverlayPage(1)
                        OverlayMoveSel(-1)
                    }
                    stale := OverlayGui
                    HideOverlay()
                    UpdateOverlay()
                    checks++
                    if OVERLAY_VISIBLE || OverlayWindowExists(stale)
                        failures.Push("Destroy " mode "/" hints)
                    ; Regression: simulate the precise destroyed-but-IsObject state.
                    OverlayGui := stale
                    OVERLAY_VISIBLE := true
                    UpdateOverlay()
                    checks++
                    if OVERLAY_VISIBLE || IsObject(OverlayGui)
                        failures.Push("Stale reference " mode "/" hints)
                }
            }
        }
    } catch as err {
        failures.Push(err.Message)
    } finally {
        HideOverlay()
    }
    report := "UniBind 2027.10 native GUI lifecycle test`r`nChecks: " checks "`r`nFailures: " failures.Length "`r`n"
    for failure in failures
        report .= failure "`r`n"
    path := A_ScriptDir "\overlay-gui-test.txt"
    try FileDelete(path)
    FileAppend(report, path, "UTF-8")
    MsgBox(report "`r`n" path, "UniBind — тест окна")
    ExitApp(failures.Length ? 1 : 0)
}


RunDataSelfTests() {
    global CONFIG_FILE, CONFIG_DIR, PROFILES_DIR, PROFILES, ACTIVE_PROFILE_IDX, SLOTS
    checks := 0, failures := []
    temp := A_Temp "\UniBind_data_test_" DllCall("kernel32\GetCurrentProcessId", "UInt") "_" A_TickCount
    oldConfig := CONFIG_FILE, oldConfigDir := CONFIG_DIR, oldProfilesDir := PROFILES_DIR
    oldProfiles := PROFILES, oldActive := ACTIVE_PROFILE_IDX, oldSlots := SLOTS
    DirCreate(temp)
    try {
        CONFIG_DIR := temp
        CONFIG_FILE := temp "\settings.ini"
        PROFILES_DIR := temp "\profiles"
        DirCreate(PROFILES_DIR)
        PROFILES := [Map("id", 1, "label", "Тест", "name", "", "organization", "", "rank", "")]
        ACTIVE_PROFILE_IDX := 1
        for item in [["0", 0], ["1", 1], ["120000", 120000]] {
            checks++
            if (RequireInt(item[1], 0, 120000, "test") != item[2])
                failures.Push("Integer " item[1])
        }
        for value in ["-1", "120001", "1.5", "", "NaN", "1e2"] {
            rejected := false
            try RequireInt(value, 0, 120000, "test")
            catch
                rejected := true
            checks++
            if !rejected
                failures.Push("Must reject integer: " value)
        }
        sample := "  Кириллица " Chr(34) "кавычки" Chr(34) " |~| %7C ~ub2~ = " Chr(59) "  "
        raw := Map("Section", Map("text", sample))
        file := temp "\roundtrip.ini"
        WriteIniRaw(file, raw)
        checks++
        if !(IniValue(ReadIniRaw(file), "Section", "text") == sample)
            failures.Push("UTF16 exact roundtrip")
        before := FileRead(file, "UTF-16")
        try WriteIniRaw(file, Map("Section", Map("text", "bad`nnew=value")))
        catch {
        }
        checks++
        if !(FileRead(file, "UTF-16") == before)
            failures.Push("Invalid input changed original file")
        draft := Map("name", "Тест", "hotkey", "", "sortOrder", 1, "category", "", "statType", "",
            "enabled", true, "showInOverlay", true, "lines", [Map("text", sample, "delay", 120000)])
        SLOTS := [draft]
        SaveBindToIni(1)
        settings := Map("Settings", Map("chatKey", "t", "baseDelay", 2300),
            "Profiles", Map("count", 1, "active", 1, "profile1_id", 1, "profile1_label", "Тест"))
        WriteIniRaw(CONFIG_FILE, settings)
        exported := settings.Clone()
        exported["Meta"] := Map("formatVersion", "2027.2", "profileCount", 1)
        exported["P1_Slot1"] := SlotIniData(draft)
        exported["P1_Categories"] := Map("count", 0)
        checks++
        if (ValidateImportData(exported) != "")
            failures.Push("Valid export rejected: " ValidateImportData(exported))
        for pair in [["lineCount", 101], ["line1_delay", -1], ["line1_delay", 120001],
            ["line1_text", StrReplace(Format("{:4097}", "x"), " ", "x")]] {
            bad := exported.Clone()
            bad["P1_Slot1"] := exported["P1_Slot1"].Clone()
            bad["P1_Slot1"][pair[1]] := pair[2]
            checks++
            if (ValidateImportData(bad) = "")
                failures.Push("Invalid export accepted: " pair[1])
        }
        ApplyImportSnapshot(exported)
        checks++
        if !(IniValue(ReadIniRaw(PROFILES_DIR "\P1.ini"), "Slot1", "line1_text") == sample)
            failures.Push("Import text changed")
        savedDir := PROFILES_DIR
        PROFILES_DIR := temp "\missing\profiles"
        candidate := draft.Clone()
        candidate["name"] := "Should not commit"
        rejected := false
        try CommitSlot(1, candidate)
        catch
            rejected := true
        checks++
        if (!rejected || SLOTS[1]["name"] != "Тест")
            failures.Push("Failed write changed RAM")
        PROFILES_DIR := savedDir
        beforeText := IniValue(ReadIniRaw(PROFILES_DIR "\P1.ini"), "Slot1", "line1_text")
        badImport := exported.Clone()
        badImport["Meta"] := Map("formatVersion", "2027.2", "profileCount", 2)
        badImport["Profiles"] := exported["Profiles"].Clone()
        badImport["Profiles"]["profile2_id"] := 2
        badImport["P1_Slot1"] := exported["P1_Slot1"].Clone()
        badImport["P1_Slot1"]["line1_text"] := "Temporary uncommitted text"
        badImport["P2_Categories"] := Map("count", 0)
        DirCreate(PROFILES_DIR "\P2.ini")
        rejected := false
        try ApplyImportSnapshot(badImport)
        catch
            rejected := true
        checks++
        if (!rejected || !(IniValue(ReadIniRaw(PROFILES_DIR "\P1.ini"), "Slot1", "line1_text") == beforeText))
            failures.Push("Import rollback failed")
    } catch as err {
        failures.Push("Unexpected: " err.Message " line " err.Line)
    } finally {
        CONFIG_FILE := oldConfig
        CONFIG_DIR := oldConfigDir
        PROFILES_DIR := oldProfilesDir
        PROFILES := oldProfiles
        ACTIVE_PROFILE_IDX := oldActive
        SLOTS := oldSlots
        try DirDelete(temp, true)
    }
    report := "UniBind Beta 1 data self-test`r`nChecks: " checks "`r`nFailures: " failures.Length "`r`n"
    for failure in failures
        report .= failure "`r`n"
    file := A_ScriptDir "\data-self-test.txt"
    if FileExist(file)
        FileDelete(file)
    FileAppend(report, file, "UTF-8")
    MsgBox(report, "UniBind — data self-test")
    ExitApp(failures.Length ? 1 : 0)
}
