; Кастомное меню значка в системном трее. Команды остаются в основном приложении.
global TRAY_POPUP_GUI := 0, TRAY_POPUP_CTRL := 0, TRAY_POPUP_VIEW := 0
global TRAY_POPUP_VISIBLE := false, TRAY_POPUP_BUSY := false

TrayPopup_OnNotify(wParam, lParam, msg, hwnd) {
    ; AutoHotkey использует собственное уведомление значка 0x404. ЛКМ остаётся штатным.
    if (hwnd = A_ScriptHwnd && lParam = 0x0205) { ; WM_RBUTTONUP
        SetTimer(TrayPopup_Show, -1)
        return 0
    }
}

TrayPopup_Create() {
    global TRAY_POPUP_GUI, TRAY_POPUP_CTRL, TRAY_POPUP_VIEW, ROOT_DIR, UI_DIR
    if IsObject(TRAY_POPUP_GUI)
        return
    html := FileRead(UI_DIR "\tray.html", "UTF-8")
    try LogLine("Tray HTML characters: " StrLen(html))
    trayGui := Gui("-Caption +ToolWindow +AlwaysOnTop -DPIScale", "UniBind tray")
    trayGui.BackColor := "0C0719"
    trayGui.MarginX := 0
    trayGui.MarginY := 0
    try {
        trayGui.OnEvent("Escape", (*) => TrayPopup_Hide())
        trayGui.Show("Hide w350 h415")
        loader := ROOT_DIR "\lib\WebView2\" (A_PtrSize * 8) "bit\WebView2Loader.dll"
        userData := A_AppData "\..\Local\UniBind\WebView2"
        ctrl := WebView2.CreateControllerAsync(trayGui.Hwnd, 0, userData, "", loader).await2()
        view := ctrl.CoreWebView2
        try ctrl.DefaultBackgroundColor := 0xFF19070C
        try view.Settings.AreBrowserAcceleratorKeysEnabled := false
        try view.Settings.AreDefaultContextMenusEnabled := false
        try view.Settings.AreDevToolsEnabled := false
        try view.Settings.AreHostObjectsAllowed := false
        try view.Settings.IsStatusBarEnabled := false
        try view.Settings.IsZoomControlEnabled := false
        view.add_WebMessageReceived(TrayPopup_Message)
        view.add_NavigationStarting(TrayPopup_Navigation)
        view.add_NewWindowRequested(TrayPopup_NewWindow)
        view.add_NavigationCompleted(TrayPopup_Ready)
        TRAY_POPUP_GUI := trayGui, TRAY_POPUP_CTRL := ctrl, TRAY_POPUP_VIEW := view
        ctrl.Fill()
        ctrl.IsVisible := 1
        view.NavigateToString(html)
    } catch as err {
        try trayGui.Destroy()
        TRAY_POPUP_GUI := 0, TRAY_POPUP_CTRL := 0, TRAY_POPUP_VIEW := 0
        throw err
    }
}

TrayPopup_Show() {
    global TRAY_POPUP_GUI, TRAY_POPUP_CTRL, TRAY_POPUP_VIEW, TRAY_POPUP_VISIBLE, TRAY_POPUP_BUSY
    if TRAY_POPUP_BUSY
        return
    if TRAY_POPUP_VISIBLE {
        TrayPopup_Hide()
        return
    }
    TRAY_POPUP_BUSY := true
    try {
        TrayPopup_Create()
        pt := Buffer(8, 0)
        DllCall("user32\GetCursorPos", "Ptr", pt)
        mx := NumGet(pt, 0, "Int"), my := NumGet(pt, 4, "Int")
        mon := DllCall("user32\MonitorFromPoint", "Int64", NumGet(pt, 0, "Int64"), "UInt", 2, "Ptr")
        mi := Buffer(40, 0), NumPut("UInt", 40, mi, 0)
        if !DllCall("user32\GetMonitorInfoW", "Ptr", mon, "Ptr", mi)
            throw Error("Не удалось определить границы экрана")
        left := NumGet(mi, 20, "Int"), top := NumGet(mi, 24, "Int")
        right := NumGet(mi, 28, "Int"), bottom := NumGet(mi, 32, "Int")
        dpiX := 96, dpiY := 96
        try DllCall("shcore\GetDpiForMonitor", "Ptr", mon, "Int", 0, "UInt*", &dpiX, "UInt*", &dpiY)
        if (dpiX < 72 || dpiX > 480)
            dpiX := 96
        width := Min(Round(350 * dpiX / 96), right - left)
        height := Min(Round(415 * dpiX / 96), bottom - top)
        x := Min(Max(mx - width + Round(28 * dpiX / 96), left), right - width)
        y := my - height - Round(8 * dpiX / 96)
        if (y < top)
            y := my + Round(12 * dpiX / 96)
        y := Min(Max(y, top), bottom - height)
        TRAY_POPUP_GUI.Show("x" x " y" y " w" width " h" height)
        try WinSetRegion("0-0 w" width " h" height " R" Round(13*dpiX/96) "-" Round(13*dpiX/96), "ahk_id " TRAY_POPUP_GUI.Hwnd)
        TRAY_POPUP_CTRL.Fill()
        WinActivate("ahk_id " TRAY_POPUP_GUI.Hwnd)
        try TRAY_POPUP_CTRL.MoveFocus(0)
        TRAY_POPUP_VISIBLE := true
        try TRAY_POPUP_VIEW.PostWebMessageAsString(A_IsSuspended ? "suspended" : "active")
        SetTimer(TrayPopup_CheckFocus, 200)
    } catch as err {
        try LogLine("Tray popup: " err.Message)
        try TrayPopup_Hide()
        ; Если новый интерфейс недоступен, сохраняем штатное рабочее меню.
        try A_TrayMenu.Show()
    } finally {
        TRAY_POPUP_BUSY := false
    }
}

TrayPopup_Hide() {
    global TRAY_POPUP_GUI, TRAY_POPUP_VISIBLE
    SetTimer(TrayPopup_CheckFocus, 0)
    TRAY_POPUP_VISIBLE := false
    if IsObject(TRAY_POPUP_GUI)
        try TRAY_POPUP_GUI.Hide()
}
TrayPopup_CheckFocus() {
    global TRAY_POPUP_GUI, TRAY_POPUP_VISIBLE
    if TRAY_POPUP_VISIBLE && !WinActive("ahk_id " TRAY_POPUP_GUI.Hwnd)
        TrayPopup_Hide()
}
TrayPopup_Ready(sender, args) {
    global TRAY_POPUP_VIEW
    try LogLine("Tray navigation complete: " args.IsSuccess " error=" args.WebErrorStatus)
    try TRAY_POPUP_VIEW.PostWebMessageAsString(A_IsSuspended ? "suspended" : "active")
}
TrayPopup_Navigation(sender, args) {
    try {
        LogLine("Tray navigation URI: " args.Uri)
        if (args.Uri != "about:blank")
            args.Cancel := true
    }
}
TrayPopup_NewWindow(sender, args) {
    try args.Handled := true
}
TrayPopup_Message(sender, args) {
    try {
        if (args.Source != "about:blank")
            return
        action := args.TryGetWebMessageAsString()
        TrayPopup_Dispatch(action)
    } catch as err {
        try LogLine("Tray action: " err.Message)
    }
}
TrayPopup_Dispatch(action) {
    switch action {
        case "dismiss": TrayPopup_Hide()
        case "open": TrayPopup_Hide(), ShowMainGui()
        case "settings": TrayPopup_Hide(), OpenSettingsFromTray()
        case "profile": TrayPopup_Hide(), OpenProfileFromTray()
        case "variables": TrayPopup_Hide(), OpenVarsFromTray()
        case "binds": TrayPopup_Hide(), TrayPopup_OpenBindsFolder()
        case "overlay": TrayPopup_Hide(), ToggleOverlay()
        case "overlay-settings": TrayPopup_Hide(), OpenOverlaySettingsFromTray()
        case "reload": TrayPopup_Hide(), Reload()
        case "suspend": TrayPopup_Hide(), ToggleSuspend()
        case "exit": TrayPopup_Hide(), ExitApp()
    }
}
TrayPopup_OpenBindsFolder() {
    global PROFILES_DIR
    try {
        if !DirExist(PROFILES_DIR)
            DirCreate(PROFILES_DIR)
        Run('"' PROFILES_DIR '"')
    } catch as err {
        MsgBox("Не удалось открыть папку биндов: " err.Message, "UniBind", "IconX")
    }
}
