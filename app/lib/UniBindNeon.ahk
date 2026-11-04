; UniBind 2027.10 — native, single-surface GDI+ overlay.
; Hotfix 2027.10.1: position lookup works for the initially hidden HWND.
; One off-screen bitmap is submitted atomically via UpdateLayeredWindow.
; No WebView2 instance, child-label repaint, WM_SETREDRAW or full-window erase.

NeonGdipStart() {
    static token := 0, module := 0
    if token
        return token
    module := DllCall("kernel32\LoadLibraryW", "Str", "gdiplus.dll", "Ptr")
    if !module
        throw Error("Не удалось загрузить gdiplus.dll: " A_LastError)
    input := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("UInt", 1, input, 0)
    status := DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", input, "Ptr", 0, "UInt")
    if status {
        DllCall("kernel32\FreeLibrary", "Ptr", module)
        module := 0
        throw Error("GDI+ startup: " status)
    }
    LogLine("NEON PATCH 2027.10.1 (hidden HWND positioning)")
    OnExit((*) => NeonGdipShutdown(token, module))
    return token
}

NeonGdipShutdown(token, module) {
    try DllCall("gdiplus\GdiplusShutdown", "UPtr", token)
    finally DllCall("kernel32\FreeLibrary", "Ptr", module)
}

NeonCheck(status, label) {
    if status
        throw Error(label ": " status)
}

NeonMeasure(text, size := 11) {
    ; Conservative Segoe UI bold measurement shared with the existing hint helper.
    return Ceil(OverlayMeasureText(text) * size / (8 * 96 / 72))
}

NeonWrapKey(key, width) {
    result := "", line := ""
    for part in StrSplit(key, "+") {
        next := line = "" ? part : line "+" part
        if (line != "" && NeonMeasure(next) > width) {
            result .= (result = "" ? "" : "`n") line "+"
            line := part
        } else {
            line := next
        }
    }
    return result (result = "" ? "" : "`n") line
}

NeonAddHint(items, x, y, w, key, caption) {
    keyW := Max(34, NeonMeasure(key) + 14)
    if (keyW + NeonMeasure(caption) + 10 <= w) {
        items.Push(Map("x", x, "y", y, "w", w, "keyW", keyW, "keyH", 22, "key", key, "caption", caption, "stacked", false))
        return 26
    }
    wrapped := NeonWrapKey(key, w - 14)
    lines := StrSplit(wrapped, "`n").Length
    keyH := Max(22, lines * 14 + 6)
    items.Push(Map("x", x, "y", y, "w", w, "keyW", w, "keyH", keyH, "key", wrapped, "caption", caption, "stacked", true))
    return 17 + keyH + 5
}

NeonHintPair(items, bw, y, left, right) {
    inner := bw - 48
    col := (inner - 20) / 2
    needL := Max(34, NeonMeasure(left[1]) + 14) + NeonMeasure(left[2]) + 10
    needR := Max(34, NeonMeasure(right[1]) + 14) + NeonMeasure(right[2]) + 10
    if (needL <= col && needR <= col) {
        h1 := NeonAddHint(items, 24, y, col, left[1], left[2])
        h2 := NeonAddHint(items, 24 + col + 20, y, col, right[1], right[2])
        return y + Max(h1, h2)
    }
    y += NeonAddHint(items, 24, y, inner, left[1], left[2])
    y += NeonAddHint(items, 24, y, inner, right[1], right[2])
    return y
}

NeonCreateOverlay(mini := false) {
    global OverlayGui, CFG, NEON_LAYOUT, OVERLAY_EDIT_MINH
    NeonGdipStart()
    W := Min(Max(CFG["overlayWidth"], 260), 600)
    unit := Min(W / 360, 1.25)
    bw := W / unit
    hints := []
    y := mini ? 118 : 456
    visibleHints := CFG["overlayHints"] != "none" && !(mini && CFG["overlayHints"] = "full")
    if visibleHints {
        if !mini {
            y := NeonHintPair(hints, bw, y, ["↑↓", "Выбор"], ["←→", "Листать"])
            y := NeonHintPair(hints, bw, y, ["Enter", "Запуск"], ["1–0", "Быстро"])
        }
        y := NeonHintPair(hints, bw, y, [OverlayShortcutLabel("idInputHotkey", "id"), "ID цели"], ["C", "Сброс"])
        y := NeonHintPair(hints, bw, y, [OverlayShortcutLabel("overlayModeHotkey", "mode"), mini ? "Полный" : "Режим"], [OverlayShortcutLabel("overlayHotkey", "overlay"), "Скрыть"])
        bh := y + 14
    } else {
        bh := mini ? 116 : 446
    }
    natH := Ceil(bh * unit)
    H := natH
    if (!mini && CFG.Has("overlayHeight") && CFG["overlayHeight"] > natH)
        H := Min(CFG["overlayHeight"], 900)
    OVERLAY_EDIT_MINH := natH
    NEON_LAYOUT := Map("w", W, "h", H, "bw", bw, "bh", H / unit, "mini", mini, "hints", hints, "showHints", visibleHints)
    OverlayGui := Gui("+AlwaysOnTop -Caption -DPIScale +ToolWindow +E0x08080020", "UniBindNeonOverlay")
    OverlayGui.MarginX := 0
    OverlayGui.MarginY := 0
    ResolveOverlayPos(W, H, &xPos, &yPos)
    OverlayGui.Show("x" xPos " y" yPos " w" W " h" H " Hide")
}

NeonPath(x, y, w, h, r) {
    path := 0
    NeonCheck(DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &path), "CreatePath")
    try {
        d := Min(r * 2, w, h)
        for arc in [[x, y, 180], [x + w - d, y, 270], [x + w - d, y + h - d, 0], [x, y + h - d, 90]]
            NeonCheck(DllCall("gdiplus\GdipAddPathArc", "Ptr", path, "Float", arc[1], "Float", arc[2], "Float", d, "Float", d, "Float", arc[3], "Float", 90), "PathArc")
        NeonCheck(DllCall("gdiplus\GdipClosePathFigure", "Ptr", path), "ClosePath")
        return path
    } catch as err {
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
        throw err
    }
}

NeonRound(g, x, y, w, h, r, fill := 0, stroke := 0, thickness := 1) {
    path := NeonPath(x, y, w, h, r)
    brush := 0, pen := 0
    try {
        if fill {
            if (fill is Array) {
                rect := Buffer(16, 0)
                NumPut("Float", x, "Float", y, "Float", w, "Float", h, rect)
                NeonCheck(DllCall("gdiplus\GdipCreateLineBrushFromRect", "Ptr", rect, "UInt", fill[1], "UInt", fill[2], "Int", 1, "Int", 3, "Ptr*", &brush), "GradientBrush")
            } else {
                NeonCheck(DllCall("gdiplus\GdipCreateSolidFill", "UInt", fill, "Ptr*", &brush), "CreateBrush")
            }
            DllCall("gdiplus\GdipFillPath", "Ptr", g, "Ptr", brush, "Ptr", path)
        }
        if stroke {
            NeonCheck(DllCall("gdiplus\GdipCreatePen1", "UInt", stroke, "Float", thickness, "Int", 2, "Ptr*", &pen), "CreatePen")
            DllCall("gdiplus\GdipDrawPath", "Ptr", g, "Ptr", pen, "Ptr", path)
        }
    } finally {
        if pen
            DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
        if brush
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
        DllCall("gdiplus\GdipDeletePath", "Ptr", path)
    }
}

NeonLine(g, x1, y1, x2, y2, color, width := 1) {
    pen := 0
    NeonCheck(DllCall("gdiplus\GdipCreatePen1", "UInt", color, "Float", width, "Int", 2, "Ptr*", &pen), "LinePen")
    try DllCall("gdiplus\GdipDrawLine", "Ptr", g, "Ptr", pen, "Float", x1, "Float", y1, "Float", x2, "Float", y2)
    finally DllCall("gdiplus\GdipDeletePen", "Ptr", pen)
}

NeonCircle(g, x, y, r, color, width := 1, filled := false) {
    resource := 0
    try {
        if filled {
            NeonCheck(DllCall("gdiplus\GdipCreateSolidFill", "UInt", color, "Ptr*", &resource), "CircleBrush")
            DllCall("gdiplus\GdipFillEllipse", "Ptr", g, "Ptr", resource, "Float", x-r, "Float", y-r, "Float", r*2, "Float", r*2)
        } else {
            NeonCheck(DllCall("gdiplus\GdipCreatePen1", "UInt", color, "Float", width, "Int", 2, "Ptr*", &resource), "CirclePen")
            DllCall("gdiplus\GdipDrawEllipse", "Ptr", g, "Ptr", resource, "Float", x-r, "Float", y-r, "Float", r*2, "Float", r*2)
        }
    } finally {
        if resource
            DllCall(filled ? "gdiplus\GdipDeleteBrush" : "gdiplus\GdipDeletePen", "Ptr", resource)
    }
}

NeonPoly(g, points, color) {
    data := Buffer(points.Length * 8, 0), brush := 0
    for i, point in points {
        NumPut("Float", point[1], data, (i - 1) * 8)
        NumPut("Float", point[2], data, (i - 1) * 8 + 4)
    }
    NeonCheck(DllCall("gdiplus\GdipCreateSolidFill", "UInt", color, "Ptr*", &brush), "PolyBrush")
    try DllCall("gdiplus\GdipFillPolygon", "Ptr", g, "Ptr", brush, "Ptr", data, "Int", points.Length, "Int", 0)
    finally DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
}

NeonText(g, text, x, y, w, h, size, color := 0xFFBCD0E1, bold := false, align := 0, mono := false, wrap := false) {
    family := 0, font := 0, format := 0, brush := 0
    rect := Buffer(16, 0)
    NumPut("Float", x, "Float", y, "Float", w, "Float", h, rect)
    try {
        NeonCheck(DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", mono ? "Consolas" : "Segoe UI", "Ptr", 0, "Ptr*", &family), "FontFamily")
        NeonCheck(DllCall("gdiplus\GdipCreateFont", "Ptr", family, "Float", size, "Int", bold ? 1 : 0, "Int", 2, "Ptr*", &font), "CreateFont")
        NeonCheck(DllCall("gdiplus\GdipStringFormatGetGenericTypographic", "Ptr*", &format), "StringFormat")
        DllCall("gdiplus\GdipSetStringFormatFlags", "Ptr", format, "Int", wrap ? 0 : 0x1000)
        DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", format, "Int", align)
        DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", format, "Int", 1)
        DllCall("gdiplus\GdipSetStringFormatTrimming", "Ptr", format, "Int", 3)
        NeonCheck(DllCall("gdiplus\GdipCreateSolidFill", "UInt", color, "Ptr*", &brush), "TextBrush")
        NeonCheck(DllCall("gdiplus\GdipDrawString", "Ptr", g, "WStr", text, "Int", -1, "Ptr", font, "Ptr", rect, "Ptr", format, "Ptr", brush), "DrawString")
    } finally {
        if brush
            DllCall("gdiplus\GdipDeleteBrush", "Ptr", brush)
        if format
            DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", format)
        if font
            DllCall("gdiplus\GdipDeleteFont", "Ptr", font)
        if family
            DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", family)
    }
}

NeonTargetIcon(g, x, y) {
    NeonCircle(g, x, y, 10, 0xFF00D9FF, 1.8)
    for line in [[x-14,y,x-7,y],[x+7,y,x+14,y],[x,y-14,x,y-7],[x,y+7,x,y+14]]
        NeonLine(g, line[1],line[2],line[3],line[4],0xFF00D9FF,1.8)
}

NeonClockIcon(g, x, y) {
    NeonCircle(g, x, y, 12, 0xFF00D9FF, 1.8)
    NeonLine(g,x,y-6,x,y+1,0xFF00D9FF,1.8)
    NeonLine(g,x,y+1,x+5,y+5,0xFF00D9FF,1.8)
    NeonLine(g,x,y-12,x,y-16,0xFF00D9FF,1.8)
    NeonLine(g,x-3,y-16,x+3,y-16,0xFF00D9FF,1.8)
}

NeonDrawFrame(g, frame, layout) {
    bw := layout["bw"], bh := layout["bh"], mini := layout["mini"]
    ; Opaque panel base; the slider alone controls whole-panel opacity.
    ; Antialiased rounded corners and the outer glow intentionally remain translucent.
    ; Layered vector glow. Every stroke is composited into the off-screen surface.
    NeonRound(g,6,6,bw-12,bh-12,20,0,0x0C00DDFF,10)
    NeonRound(g,6,6,bw-12,bh-12,20,0,0x1600DDFF,5)
    NeonRound(g,6,6,bw-12,bh-12,20,[0xFF0B131C,0xFF060B11],0xB300CFE8,1)
    NeonRound(g,6,6,bw-12,bh-12,20,0,0x163CF4FF,2)
    NeonCircle(g,28,28,10,0x0A00D9FF,1,true)
    NeonCircle(g,28,28,8,0x1800D9FF,1,true)
    NeonCircle(g,28,28,6,0xFF00DDF4,1,true)
    NeonText(g,"UniBind",47,12,90,31,22,0xFFF3F8FE,true)
    active := frame["NeonActive"]
    NeonRound(g,139,21,49,16,5,active ? 0x1600E5AE : 0x182D3C49,active ? 0xE000DDB0 : 0x807A8D9B,.8)
    NeonText(g,active ? "АКТИВЕН" : "ПАУЗА",141,21,45,16,8,active ? 0xFF00E5BE : 0xFFB4C1CD,true,1)
    NeonRound(g,bw-106,16,85,24,7,0x30101C27,0x60203C4B,.8)
    NeonText(g,mini ? "МИНИ" : "СПИСОК",bw-103,16,60,24,10,0xFF9BB6CC,false,1)
    Loop 3 {
        yy := 22 + (A_Index-1)*5
        NeonLine(g,bw-35,yy,bw-24,yy,0xFF00D9FF,1.5)
        NeonCircle(g,bw-39,yy,.8,0xFF00D9FF,1,true)
    }
    cardW := (bw-52)/2
    NeonRound(g,20,50,cardW,52,10,[0xD0142937,0xB30B1720],0xFF204757,.9)
    NeonRound(g,32+cardW,50,cardW,52,10,[0xD0142937,0xB30B1720],0xFF204757,.9)
    NeonTargetIcon(g,47,76)
    NeonClockIcon(g,59+cardW,77)
    NeonText(g,frame["OverlayTargetLabel"],77,55,cardW-64,18,10,0xFFC0D3E4)
    NeonText(g,frame["OverlayPatient"],77,74,cardW-64,24,17,0xFF00D9FF,true,0,true)
    NeonText(g,"ВРЕМЯ",89+cardW,55,cardW-64,18,10,0xFFC0D3E4)
    NeonText(g,frame["OverlayTime"],89+cardW,74,cardW-64,24,17,0xFFDCF4FF,true,0,true)
    if !mini {
        NeonPoly(g,[[24,119],[32,115],[40,119],[32,123]],0xFF00D9FF)
        NeonLine(g,24,123,32,127,0xFF00D9FF,1.8)
        NeonLine(g,32,127,40,123,0xFF00D9FF,1.8)
        NeonLine(g,24,127,32,131,0xFF00D9FF,1.8)
        NeonLine(g,32,131,40,127,0xFF00D9FF,1.8)
        NeonText(g,frame["OvCount"],50,110,bw-145,26,14,0xFFBBD0E3,true)
        NeonText(g,frame["OvPage"],bw-91,110,68,26,14,0xFFACC8E0,false,2)
        NeonRound(g,22,138,bw-44,6,3,0xFF10232F)
        NeonRound(g,22,138,Max(6,(bw-44)*frame["NeonProgress"]),6,3,0xFF00D9ED)
        Loop 10 {
            i := A_Index
            if !frame["rowValid" i]
                continue
            y := 158+(i-1)*28
            selected := frame["rowSelected" i]
            if selected {
                NeonRound(g,15,y-1,bw-28,27,6,0x4500BDD6,0xBE00DDEE,.8)
                NeonRound(g,13,y-3,6,32,3,0x3000D9FF,0x1000D9FF,4)
                NeonRound(g,14,y-2,5,30,2.5,0xFF00EDF0)
                NeonPoly(g,[[bw-30,y+7],[bw-23,y+13],[bw-30,y+19]],0xFF00D9ED)
            }
            NeonRound(g,27,y+1,79,24,6,selected ? [0x8000515C,0x6000212C] : [0x50002D38,0x4007151D],0x80215A61,.8)
            key := frame["OvHk" i]
            keySize := Min(15, Max(8, 15*66/Max(1,NeonMeasure(key,15))))
            NeonText(g,key,31,y+1,71,24,keySize,0xFF00DFEF,true,1,true)
            NeonText(g,frame["OvName" i],131,y,bw-(selected ? 171 : 155),27,15,selected ? 0xFFE0F9FE : 0xFFB9CBDD,selected)
            if !selected
                NeonLine(g,115,y+27,bw-24,y+27,0xA0132631,.6)
        }
        if frame["emptyVisible"]
            NeonText(g,"Нет доступных биндов",28,239,bw-56,52,14,0xFF9BB6CB,false,1)
    }
    if layout["showHints"] {
        if !mini
            NeonLine(g,22,448,bw-22,448,0xA0008C9E,.8)
        for hint in layout["hints"] {
            x:=hint["x"], y:=hint["y"], kw:=hint["keyW"], kh:=hint["keyH"]
            if hint["stacked"] {
                NeonText(g,hint["caption"],x,y,hint["w"],16,11,0xFFACC4DC)
                ky:=y+17
            } else {
                NeonText(g,hint["caption"],x+kw+10,y,hint["w"]-kw-10,22,11,0xFFACC4DC)
                ky:=y
            }
            NeonRound(g,x,ky,kw,kh,5,0xD0142A38,0xB0214758,.8)
            NeonText(g,hint["key"],x+4,ky,kw-8,kh,11,0xFFECF7FF,true,1,false,hint["stacked"])
        }
    }
    if frame["NeonEdit"]
        NeonRound(g,7,7,bw-14,bh-14,19,0,0xFF00E4FF,1.7)
}

NeonPaint(window, frame) {
    global NEON_LAYOUT, CFG
    screen:=0, dc:=0, bitmap:=0, oldBitmap:=0, graphics:=0
    try {
        hwnd := window.Hwnd
        rect := Buffer(16,0)
        if !DllCall("user32\GetClientRect","Ptr",hwnd,"Ptr",rect)
            throw Error("GetClientRect failed")
        pw:=NumGet(rect,8,"Int"), ph:=NumGet(rect,12,"Int")
        if (pw<1 || ph<1)
            throw Error("Empty overlay surface")
        screen:=DllCall("user32\GetDC","Ptr",0,"Ptr")
        dc:=DllCall("gdi32\CreateCompatibleDC","Ptr",screen,"Ptr")
        info:=Buffer(40,0), bits:=0
        NumPut("UInt",40,"Int",pw,"Int",-ph,"UShort",1,"UShort",32,info)
        bitmap:=DllCall("gdi32\CreateDIBSection","Ptr",screen,"Ptr",info,"UInt",0,"Ptr*",&bits,"Ptr",0,"UInt",0,"Ptr")
        if (!screen || !dc || !bitmap)
            throw Error("CreateDIBSection failed")
        oldBitmap:=DllCall("gdi32\SelectObject","Ptr",dc,"Ptr",bitmap,"Ptr")
        NeonCheck(DllCall("gdiplus\GdipCreateFromHDC","Ptr",dc,"Ptr*",&graphics),"CreateGraphics")
        DllCall("gdiplus\GdipGraphicsClear","Ptr",graphics,"UInt",0)
        DllCall("gdiplus\GdipSetSmoothingMode","Ptr",graphics,"Int",4)
        DllCall("gdiplus\GdipSetTextRenderingHint","Ptr",graphics,"Int",4)
        factor:=pw/NEON_LAYOUT["bw"]
        NeonCheck(DllCall("gdiplus\GdipScaleWorldTransform","Ptr",graphics,"Float",factor,"Float",factor,"Int",0),"ScaleGraphics")
        NeonDrawFrame(graphics,frame,NEON_LAYOUT)
        ; GDI+ must finish before the complete premultiplied surface is published.
        NeonCheck(DllCall("gdiplus\GdipFlush","Ptr",graphics,"Int",1),"FlushGraphics")
        ; The first frame is rendered before Show(). AHK title-based lookups
        ; skip hidden windows unless DetectHiddenWindows is enabled. Query the
        ; existing HWND directly; do not change the process/thread search setting.
        bounds := Buffer(16, 0)
        if !DllCall("user32\GetWindowRect", "Ptr", hwnd, "Ptr", bounds, "Int")
            throw Error("GetWindowRect failed: " A_LastError)
        x := NumGet(bounds, 0, "Int")
        y := NumGet(bounds, 4, "Int")
        pos:=Buffer(8,0), size:=Buffer(8,0), origin:=Buffer(8,0), blend:=Buffer(4,0)
        NumPut("Int",x,"Int",y,pos)
        NumPut("Int",pw,"Int",ph,size)
        NumPut("UChar",frame["NeonOpacity"],blend,2)
        NumPut("UChar",1,blend,3)
        if !DllCall("user32\UpdateLayeredWindow","Ptr",hwnd,"Ptr",screen,"Ptr",pos,"Ptr",size,"Ptr",dc,"Ptr",origin,"UInt",0,"Ptr",blend,"UInt",2)
            throw Error("UpdateLayeredWindow failed: " A_LastError)
    } finally {
        if graphics
            DllCall("gdiplus\GdipDeleteGraphics","Ptr",graphics)
        if oldBitmap
            DllCall("gdi32\SelectObject","Ptr",dc,"Ptr",oldBitmap)
        if bitmap
            DllCall("gdi32\DeleteObject","Ptr",bitmap)
        if dc
            DllCall("gdi32\DeleteDC","Ptr",dc)
        if screen
            DllCall("user32\ReleaseDC","Ptr",0,"Ptr",screen)
    }
}

NeonBuildVersion() {
    return "2027.10"
}
