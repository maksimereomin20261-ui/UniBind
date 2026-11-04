; Подключается только во временную копию приложения при тесте GitHub Actions.
TrayTest_Log(text) {
    FileAppend(text "`n", EnvGet("UNIBIND_TRAY_TEST_DIR") "\result.txt", "UTF-8")
}
TrayTest_Assert(condition, message) {
    if !condition
        throw Error(message)
    TrayTest_Log("PASS " message)
}
TrayTest_JS(view, script) {
    return view.ExecuteScriptAsync(script).await2(5000)
}
TrayTest_Click(action) {
    global TRAY_POPUP_VISIBLE, TRAY_POPUP_VIEW, TRAY_POPUP_READY
    if TRAY_POPUP_VISIBLE
        TrayPopup_Hide()
    TrayPopup_Show()
    Loop 40 {
        if TRAY_POPUP_READY
            break
        Sleep(200)
    }
    TrayTest_Assert(TRAY_POPUP_VISIBLE && TRAY_POPUP_READY, "menu ready: " action)
    TrayTest_JS(TRAY_POPUP_VIEW, "document.querySelector('[data-action=" action "]').click()")
    Sleep(600)
    TrayTest_Assert(!TRAY_POPUP_VISIBLE, "menu closes: " action)
}
TrayTest_OnExit(reason, code) {
    testDir := EnvGet("UNIBIND_TRAY_TEST_DIR")
    TrayTest_Log("Exit reason=" reason " code=" code)
    if FileExist(testDir "\expect-exit") && !FileExist(testDir "\failed") && reason = "Exit"
        FileAppend("ok", testDir "\done", "UTF-8")
}
TrayIntegrationTests() {
    global wv, MyGui, TRAY_POPUP_GUI, TRAY_POPUP_VISIBLE, TRAY_POPUP_HAS_ANCHOR, TRAY_POPUP_CLICK_X, TRAY_POPUP_CLICK_Y
    global CFG, BINDER_ENABLED, OVERLAY_VISIBLE, OverlayGui, PROFILES_DIR
    testDir := EnvGet("UNIBIND_TRAY_TEST_DIR")
    OnExit(TrayTest_OnExit)
    try {
        if FileExist(testDir "\expect-reload") {
            TrayTest_Log("PASS app restarted after reload")
            FileAppend("ok", testDir "\expect-exit", "UTF-8")
            TrayTest_Click("exit")
            throw Error("Exit action returned without terminating the app")
        }
        Sleep(2000)
        TrayTest_Assert(IsObject(wv) && IsObject(MyGui), "real app started")
        ; Simulate the same Windows notification delivered by a right click.
        DllCall("user32\PostMessageW", "Ptr", A_ScriptHwnd, "UInt", 0x404, "UPtr", 0x404, "Ptr", 0x205)
        Sleep(3500)
        TrayTest_Assert(TRAY_POPUP_VISIBLE && TRAY_POPUP_READY, "right-click opens menu")
        TrayPopup_Hide()
        ; On the available monitor, simulate clicks at the four work-area corners.
        mi := Buffer(40, 0), NumPut("UInt", 40, mi, 0)
        mon := DllCall("user32\MonitorFromWindow", "Ptr", MyGui.Hwnd, "UInt", 2, "Ptr")
        TrayTest_Assert(DllCall("user32\GetMonitorInfoW", "Ptr", mon, "Ptr", mi), "work area available")
        l := NumGet(mi,20,"Int"), t := NumGet(mi,24,"Int"), r := NumGet(mi,28,"Int"), b := NumGet(mi,32,"Int")
        for point in [[l,t],[r-1,t],[l,b-1],[r-1,b-1]] {
            TRAY_POPUP_CLICK_X := point[1], TRAY_POPUP_CLICK_Y := point[2], TRAY_POPUP_HAS_ANCHOR := true
            TrayPopup_Show()
            WinGetPos(&x, &y, &width, &height, "ahk_id " TRAY_POPUP_GUI.Hwnd)
            TrayTest_Assert(x >= l && y >= t && x+width <= r && y+height <= b, "menu remains inside work area")
            TrayPopup_Hide()
        }
        WinMinimize("ahk_id " MyGui.Hwnd)
        TrayTest_Click("open")
        TrayTest_Assert(WinGetMinMax("ahk_id " MyGui.Hwnd) != -1, "open restores real app")
        TrayTest_Click("settings")
        TrayTest_Assert(TrayTest_JS(wv,"document.querySelector('#unifiedSettingsModal').classList.contains('active') && document.querySelector('#settingsPanel-binder').classList.contains('active')") = "true", "settings opens binder tab")
        TrayTest_JS(wv,"closeUnifiedSettings()")
        TrayTest_Click("profile")
        TrayTest_Assert(TrayTest_JS(wv,"document.querySelector('#profileModal').classList.contains('active')") = "true", "profile opens")
        TrayTest_JS(wv,"closeProfileModal()")
        TrayTest_Click("variables")
        TrayTest_Assert(TrayTest_JS(wv,"document.querySelector('#varsModal').classList.contains('active')") = "true", "variables opens")
        TrayTest_JS(wv,"closeVarsEditor()")
        TrayTest_Click("binds")
        opened := false
        Loop 30 {
            try {
                for window in ComObject("Shell.Application").Windows {
                    try {
                        if (StrLower(window.Document.Folder.Self.Path) = StrLower(PROFILES_DIR)) {
                            opened := true
                            window.Quit()
                            break
                        }
                    }
                }
            }
            if opened
                break
            Sleep(200)
        }
        TrayTest_Assert(opened, "binds folder opens in Explorer")
        CFG["overlayEnabled"] := true, BINDER_ENABLED := true
        TrayTest_Click("overlay")
        TrayTest_Assert(OVERLAY_VISIBLE && OverlayWindowExists(OverlayGui), "overlay opens")
        TrayTest_Click("overlay")
        TrayTest_Assert(!OVERLAY_VISIBLE, "overlay closes")
        TrayTest_Click("overlay-settings")
        TrayTest_Assert(TrayTest_JS(wv,"document.querySelector('#unifiedSettingsModal').classList.contains('active') && document.querySelector('#settingsPanel-overlay').classList.contains('active')") = "true", "overlay settings opens")
        TrayTest_JS(wv,"closeUnifiedSettings()")
        TrayTest_Click("suspend")
        TrayTest_Assert(A_IsSuspended, "hotkeys suspended")
        TrayTest_Click("suspend")
        TrayTest_Assert(!A_IsSuspended, "hotkeys resumed")
        FileAppend("ok", testDir "\expect-reload", "UTF-8")
        TrayTest_Click("reload")
        Sleep(5000)
        throw Error("Reload action returned without restarting the app")
    } catch as err {
        TrayTest_Log("FAIL " err.Message " at " err.File ":" err.Line)
        FileAppend(err.Message, testDir "\failed", "UTF-8")
        ExitApp(1)
    }
}
