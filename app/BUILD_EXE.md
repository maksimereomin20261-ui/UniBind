# Сборка и проверка EXE на Windows x64

EXE в исходном ZIP отсутствует. Сборка в Linux не выполнялась; сценарии PowerShell и нативные тесты ещё должны пройти проверку на Windows. Не называйте EXE проверенным, пока не получите реальные результаты.

## Подготовка
1. Закройте UniBind и создайте отдельную тестовую копию. Нужны Windows, AutoHotkey v2 x64, WebView2 Runtime и официальный Ahk2Exe.
2. Ahk2Exe: https://github.com/AutoHotkey/Ahk2Exe/releases
3. WebView2: https://developer.microsoft.com/microsoft-edge/webview2/
4. Не используйте UPX, MPRESS, обфускаторы, отключение защиты или антивирусные исключения.

## Сначала — AHK
В PowerShell из папки UniBind, подставив свои пути:

```powershell
& '.\tools\Test-Windows.ps1' -AutoHotkey 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe'
```

Сценарий копирует исходники/ресурсы в отдельную временную папку и запускает три режима: --self-test, --overlay-gui-test, --data-self-test. В диалогах отчёта нажимайте OK. В каждом отчёте требуется Failures: 0 и код процесса 0. Результаты сохраняются отдельно в windows-test-results. Самотесты не отправляют сообщения в GTA.

При ошибке разбора AHK или другом сбое не продолжайте сборку: сохраните точный текст ошибки и файл отчёта. Не обходите ошибки изменением политик безопасности.

Если политика PowerShell запрещает запуск, используйте разрешённый организацией способ или ручной вариант ниже; не отключайте её ради этой сборки.

## Сборка, тестирование AHK и EXE, ZIP и SHA256

```powershell
& '.\tools\Build-Release.ps1' `
  -Ahk2Exe 'C:\Tools\Ahk2Exe\Ahk2Exe.exe' `
  -AutoHotkey 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' `
  -OutputDirectory 'C:\UniBind-builds'
```

Сценарий не скачивает установщики, компилирует x64 EXE, проверяет три режима в AHK и EXE, собирает чистый ZIP и создаёт SHA256SUMS.txt и внешнюю .sha256 для ZIP. Настройки и логи не копируются. Сохраните доступ к исходникам проекта и выполните применимые условия AutoHotkey до распространения скомпилированной базы.

Дополнительный параметр **-ScanWithDefender** запускает доступный Start-MpScan. Завершение команды не доказывает отсутствия угроз: проверьте журнал защиты и карантин. Если команда недоступна, выполните проверку Windows Security вручную и не отмечайте её как пройденную автоматически.

## Ручной вариант
Откройте Ahk2Exe: Source — UniBind.ahk, Base — AutoHotkey v2 64-bit (AutoHotkey64.exe), Destination — UniBind.exe рядом с исходником. Компилятор встраивает AHK-зависимости, но не ui, шрифты, DLL и шаблон. Распространяйте папку целиком.

В PowerShell последовательно запустите из тестовой копии (каждый раз дождитесь закрытия отчёта):

```powershell
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' '.\UniBind.ahk' --self-test
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' '.\UniBind.ahk' --overlay-gui-test
& 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe' '.\UniBind.ahk' --data-self-test
& '.\UniBind.exe' --self-test
& '.\UniBind.exe' --overlay-gui-test
& '.\UniBind.exe' --data-self-test
```

Тесты создают overlay-self-test.txt, overlay-gui-test.txt и data-self-test.txt. Требуется Failures: 0. Затем пройдите ручной чек-лист, чистую Windows без AutoHotkey, GTA, DPI и Windows Security. Скомпилированному EXE AutoHotkey для запуска не нужен; WebView2 Runtime нужен.
