# UniBind — GitHub Releases starter

## Что здесь находится
- `launcher.py` — исходник кастомного загрузчика UniBind.
- `BUILD_LAUNCHER.bat` — сборка `UniBind_Setup.exe` через PyInstaller.
- `UniBind.ico` — иконка.
- `release-assets/UniBind_Payload.zip` — архив приложения для GitHub Release.

## Важно перед сборкой
В `launcher.py` замени:
`YOUR_GITHUB_USERNAME/UniBind`
на адрес репозитория в формате `имя_аккаунта/UniBind`.

## Публикация на GitHub
1. Создай публичный репозиторий с именем `UniBind`.
2. Загрузи `launcher.py`, `BUILD_LAUNCHER.bat`, `requirements-build.txt`, `UniBind.ico`.
3. Создай Release с тегом `v1.0.0`.
4. Прикрепи к Release файл `release-assets/UniBind_Payload.zip`.
5. Опубликуй Release (Publish release).

## Сборка загрузчика на Windows
1. Установи Python 3.11+ и отметь Add Python to PATH.
2. Запусти `BUILD_LAUNCHER.bat`.
3. Готовый файл появится в `dist\UniBind_Setup.exe`.

Пользователю в итоге нужен только `UniBind_Setup.exe`. Он скачивает архив из последнего GitHub Release и устанавливает программу в `%LOCALAPPDATA%\Programs\UniBind`.

## Ограничения текущей заготовки
- Ссылка на GitHub пока содержит YOUR_GITHUB_USERNAME — её нужно заменить на реальное имя аккаунта.
- Этот первый прототип не устанавливает WebView2 автоматически. Это добавим и проверим отдельно после привязки репозитория и теста скачивания.
