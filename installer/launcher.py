"""UniBind bootstrapper. Needs Windows; release payloads are always kept separate from data."""
import ctypes
import hashlib
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath
import tkinter as tk
from tkinter import messagebox

REPO = 'maksimereomin20261-ui/UniBind'
ASSET = 'UniBind-App.zip'
MAX_ARCHIVE = 100 * 1024 * 1024
MAX_EXPANDED = 300 * 1024 * 1024
ROOT = Path(os.environ.get('LOCALAPPDATA', str(Path.home()))) / 'UniBind'
VERSIONS = ROOT / 'versions'
DATA = ROOT / 'data'
STATE = ROOT / 'current.json'
LAUNCHER = ROOT / 'UniBind Launcher.exe'
HEADERS = {'User-Agent':'UniBind-Launcher/1', 'Accept':'application/vnd.github+json'}


def release_metadata():
    url = f'https://api.github.com/repos/{REPO}/releases/latest'
    with urllib.request.urlopen(urllib.request.Request(url, headers=HEADERS), timeout=8) as r:
        payload = r.read(2_000_001)
    if len(payload) > 2_000_000:
        raise ValueError('Слишком большой ответ GitHub')
    data = json.loads(payload)
    asset = next((a for a in data.get('assets', []) if a.get('name') == ASSET), None)
    if not asset:
        raise ValueError('В последнем релизе пока нет нового пакета UniBind-App.zip')
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-fA-F]{64}', digest):
        raise ValueError('GitHub не предоставил SHA-256 пакета')
    url = asset.get('browser_download_url','')
    if not url.startswith(f'https://github.com/{REPO}/releases/download/'):
        raise ValueError('Недопустимый адрес пакета')
    if not isinstance(asset.get('size'), int) or not 0 < asset['size'] <= MAX_ARCHIVE:
        raise ValueError('Недопустимый размер пакета')
    return data.get('tag_name', ''), url, digest[7:].lower(), asset['size']


def download(url, output, expected_size, progress):
    request = urllib.request.Request(url, headers={'User-Agent': HEADERS['User-Agent']})
    digest = hashlib.sha256(); size = 0
    with urllib.request.urlopen(request, timeout=20) as response, open(output, 'wb') as out:
        while chunk := response.read(128 * 1024):
            size += len(chunk)
            if size > expected_size or size > MAX_ARCHIVE:
                raise ValueError('Размер загрузки превышает ожидаемый')
            digest.update(chunk); out.write(chunk); progress(size, expected_size)
    if size != expected_size:
        raise ValueError('Загрузка завершилась не полностью')
    return digest.hexdigest()


def extract_package(archive, destination):
    allowed = {'UniBind.exe', 'ui', 'lib', 'THIRD_PARTY_NOTICES.md', 'LICENSE-AutoHotkey.txt'}
    destination = Path(destination)
    with zipfile.ZipFile(archive) as z:
        seen = set(); expanded = 0
        for item in z.infolist():
            name = item.filename
            parts = PurePosixPath(name).parts
            if (not parts or name.startswith('/') or '\\' in name or any(x in ('.','..') or ':' in x for x in parts)
                    or parts[0] not in allowed or item.flag_bits & 1):
                raise ValueError('Недопустимый путь внутри пакета')
            key = name.rstrip('/').casefold()
            if key in seen:
                raise ValueError('Повторяющиеся имена в пакете')
            seen.add(key)
            if (item.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError('Ссылки в пакете не допускаются')
            expanded += item.file_size
            if expanded > MAX_EXPANDED or len(seen) > 5000:
                raise ValueError('Пакет слишком большой')
        z.extractall(destination)
    for relative in ('UniBind.exe','ui/ui.html','lib/WebView2/64bit/WebView2Loader.dll','lib/templates/medical_profile.ini'):
        if not (destination / relative).is_file():
            raise ValueError('В пакете отсутствует необходимый файл: ' + relative)


def current():
    try:
        info = json.loads(STATE.read_text('utf-8'))
        digest = info['digest']
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            return None
        exe = VERSIONS / digest / 'UniBind.exe'
        return exe if exe.is_file() else None
    except (ValueError, KeyError, OSError, TypeError):
        return None


def commit_version(archive, digest, tag):
    VERSIONS.mkdir(parents=True, exist_ok=True)
    final = VERSIONS / digest
    if not final.exists():
        stage = Path(tempfile.mkdtemp(prefix='.stage-', dir=VERSIONS))
        try:
            extract_package(archive, stage)
            stage.rename(final)
        finally:
            if stage.exists(): shutil.rmtree(stage, ignore_errors=True)
    if not (final / 'UniBind.exe').is_file():
        raise ValueError('Папка версии повреждена')
    temp = ROOT / 'current.json.tmp'
    temp.write_text(json.dumps({'digest':digest, 'tag':tag}, ensure_ascii=False), 'utf-8')
    os.replace(temp, STATE)
    return final / 'UniBind.exe'


def create_shortcut():
    # Windows resolves redirected/OneDrive Desktop via WScript, not USERPROFILE/Desktop.
    script = r'''$w=New-Object -ComObject WScript.Shell
$p=Join-Path $w.SpecialFolders.Item('Desktop') 'UniBind.lnk'
$s=$w.CreateShortcut($p)
$s.TargetPath=$env:UNIBIND_SHORTCUT_TARGET
$s.WorkingDirectory=$env:UNIBIND_SHORTCUT_DIR
$s.Description='UniBind'
$s.Save()'''
    env = dict(os.environ, UNIBIND_SHORTCUT_TARGET=str(LAUNCHER), UNIBIND_SHORTCUT_DIR=str(ROOT))
    subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',script],
                   env=env, check=True, timeout=20, creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))


def webview_installed():
    # Check common Evergreen Runtime installations without changing the system.
    for base in [os.environ.get('PROGRAMFILES(X86)',''), os.environ.get('PROGRAMFILES',''), os.environ.get('LOCALAPPDATA','')]:
        if base and list((Path(base)/'Microsoft/EdgeWebView/Application').glob('*/msedgewebview2.exe')):
            return True
    return False


def ensure_launcher_installed():
    if not getattr(sys, 'frozen', False):
        raise RuntimeError('Для установки требуется собранный EXE загрузчика')
    if Path(sys.executable).resolve() != LAUNCHER.resolve():
        # The mutex ensures another UniBind launcher is not running during replacement.
        replacement = ROOT / 'UniBind Launcher.new.exe'
        try:
            shutil.copy2(sys.executable, replacement)
            os.replace(replacement, LAUNCHER)
        finally:
            if replacement.exists():
                replacement.unlink()


class Window:
    """Installer screen inspired by UniBind's dark-violet interface."""
    VERSION = '2027.10 · Beta 1 HF2'
    def __init__(self):
        self.root = tk.Tk()
        self.root.title('UniBind — установка и обновление')
        self.root.geometry('1020x580')
        self.root.resizable(False, False)
        self.root.configure(bg='#0c0a19')
        self.root.protocol('WM_DELETE_WINDOW', self.close)
        self.root.bind('<Escape>', lambda _event: self.close())
        self.canvas = tk.Canvas(self.root, width=1020, height=580, bg='#0c0a19',
                                highlightthickness=0, bd=0)
        self.canvas.pack(fill='both', expand=True)
        self.events = queue.Queue()
        self.done = False
        self.determinate = False
        self.spinner_angle = 0
        self.draw_ui()
        self.root.after(100, self.poll)
        self.root.after(80, self.animate)
        threading.Thread(target=self.worker, daemon=True).start()
        self.root.mainloop()

    def rounded(self, x1, y1, x2, y2, radius, fill, outline=None, width=1):
        points = (x1+radius,y1, x2-radius,y1, x2,y1, x2,y1+radius,
                  x2,y2-radius, x2,y2, x2-radius,y2, x1+radius,y2,
                  x1,y2, x1,y2-radius, x1,y1+radius, x1,y1)
        return self.canvas.create_polygon(points, smooth=True, splinesteps=24,
                                          fill=fill, outline=outline or fill, width=width)

    def label(self, x, y, text, size, color, weight='normal', **kwargs):
        return self.canvas.create_text(x, y, text=text, fill=color, anchor='nw',
                                       font=('Segoe UI', -size, weight), **kwargs)

    def draw_ui(self):
        c = self.canvas
        # Structural surfaces and restrained decorative violet ribbons.
        c.create_rectangle(0, 0, 1020, 580, fill='#0b0918', outline='')
        c.create_polygon(700,0,1020,0,1020,255,965,245,900,232,845,205,770,158,
                         fill='#130e2c', outline='', smooth=True)
        c.create_polygon(1020,95,1020,219,940,212,870,246,808,284,745,300,800,260,
                         fill='#21104c', outline='', smooth=True)
        c.create_rectangle(0, 0, 1020, 63, fill='#100d20', outline='')
        c.create_line(0, 63, 1020, 63, fill='#292044')
        c.create_rectangle(0, 64, 196, 580, fill='#100d20', outline='')
        c.create_line(196, 64, 196, 580, fill='#292044')
        self.label(27, 14, 'U', 30, '#9b68ff', 'bold')
        self.label(63, 20, 'UniBind', 21, '#f8f5ff', 'bold')
        self.label(760, 25, 'УСТАНОВКА И ОБНОВЛЕНИЕ', 11, '#a49abc', 'bold')
        # Static sidebar entries match the reference but do not imitate controls.
        self.rounded(14, 93, 181, 139, 10, '#32206c')
        c.create_rectangle(14, 94, 18, 138, fill='#a479ff', outline='')
        c.create_line(31, 116, 43, 104, 55, 116, fill='#f9f7ff', width=2)
        c.create_line(34, 114, 34, 126, 52, 126, 52, 114, fill='#f9f7ff', width=2)
        self.label(64, 106, 'Главная', 16, '#f8f6ff', 'bold')
        c.create_oval(35, 162, 51, 178, outline='#aaa1c3', width=2)
        c.create_oval(41, 168, 45, 172, fill='#aaa1c3', outline='')
        for dx, dy in ((0,-11),(0,11),(-11,0),(11,0),(-8,-8),(8,-8),(-8,8),(8,8)):
            c.create_line(43+dx*0.7, 170+dy*0.7, 43+dx, 170+dy, fill='#aaa1c3', width=2)
        self.label(64, 164, 'Настройки', 15, '#aaa1c3')
        for gx, gy in ((33,216),(44,216),(33,227),(44,227)):
            c.create_rectangle(gx, gy, gx+7, gy+7, outline='#aaa1c3', width=2)
        self.label(64, 219, 'Бинды', 15, '#aaa1c3')
        c.create_oval(33, 278, 51, 296, outline='#aaa1c3', width=2)
        c.create_text(42, 287, text='i', fill='#c1b4d8', font=('Segoe UI', -12, 'bold'))
        about = tk.Button(self.root, text='О программе', command=self.show_about,
                          font=('Segoe UI', -15), fg='#ddd4f2', bg='#100d20',
                          activeforeground='#ffffff', activebackground='#24194a',
                          relief='flat', bd=0, cursor='hand2', anchor='w',
                          highlightthickness=1, highlightbackground='#100d20')
        c.create_window(61, 268, window=about, anchor='nw', width=115, height=38)
        self.label(25, 329, 'Настройки и бинды\nдоступны в приложении', 11, '#aaa1c3',
                   width=150, justify='left')
        c.create_line(24, 491, 171, 491, fill='#302447')
        self.net_dot = c.create_oval(25, 513, 35, 523, fill='#aba0c2', outline='')
        self.net_text = self.label(44, 509, 'Проверяем связь', 13, '#cfc7de')
        self.label(25, 541, 'Версия ' + self.VERSION, 11, '#aaa1c3')
        # Brand mark and heading.
        self.rounded(235, 103, 333, 201, 17, '#201045', '#52339d')
        c.create_text(284, 152, text='U', fill='#ac82ff', font=('Segoe UI', -70, 'bold'))
        self.label(364, 105, 'UniBind', 50, '#f6f1ff', 'bold')
        self.label(367, 171, 'Установка и обновление', 23, '#b2a5d6')
        self.rounded(222, 252, 995, 476, 19, '#171329', '#30234d', 2)
        c.create_oval(252, 289, 328, 365, outline='#30245a', width=8)
        self.ring = c.create_arc(252, 289, 328, 365, start=45, extent=270,
                                 style='arc', outline='#9863ff', width=8)
        self.heading = self.label(352, 291, 'Подготовка к установке…', 22, '#f8f5ff', 'bold', width=590)
        self.status = self.label(352, 327, 'Проверяем последнюю версию на GitHub', 16, '#b5a9d0', width=590)
        self.rounded(255, 392, 907, 404, 6, '#2b2441')
        self.bar = c.create_rectangle(255, 392, 255, 404, fill='#9560ff', outline='')
        self.percent = self.label(925, 384, '—', 17, '#ae83ff', 'bold')
        c.create_oval(256, 428, 276, 448, outline='#aa9aca', width=2)
        c.create_text(266, 438, text='i', fill='#c1b4d8', font=('Segoe UI', -13, 'bold'))
        self.label(288, 429, 'Не закрывайте окно', 14, '#b8adc9')
        self.label(225, 512, 'Ваши настройки и бинды сохраняются отдельно от обновлений',
                   13, '#b8adc9', width=760)

    def show_about(self):
        messagebox.showinfo('О программе',
            'UniBind ' + self.VERSION + '\n\nУстановка и обновление через GitHub.\n'
            'Разделы «Настройки» и «Бинды» доступны в самой программе.')

    def animate(self):
        if not self.done:
            if not self.determinate:
                self.spinner_angle = (self.spinner_angle - 18) % 360
                self.canvas.itemconfigure(self.ring, start=self.spinner_angle, extent=270)
            self.root.after(80, self.animate)

    def close(self):
        if self.done:
            self.root.destroy()
        else:
            messagebox.showinfo('UniBind', 'Дождитесь завершения установки или проверки обновления.')

    def emit(self, kind, value):
        self.events.put((kind, value))

    def poll(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == 'status':
                    self.canvas.itemconfigure(self.status, text=value)
                elif kind == 'heading':
                    self.canvas.itemconfigure(self.heading, text=value)
                elif kind == 'connection':
                    color, text = ('#34d883', 'Связь с GitHub есть') if value else ('#e3a960', 'Ошибка проверки')
                    self.canvas.itemconfigure(self.net_dot, fill=color)
                    self.canvas.itemconfigure(self.net_text, text=text)
                elif kind == 'indeterminate':
                    self.determinate = False
                    self.canvas.coords(self.bar, 255, 392, 255, 404)
                    self.canvas.itemconfigure(self.percent, text='—')
                elif kind == 'progress':
                    value = max(0.0, min(1.0, value))
                    self.determinate = True
                    self.canvas.coords(self.bar, 255, 392, 255 + 652 * value, 404)
                    self.canvas.itemconfigure(self.percent, text=f'{round(value * 100)}%')
                    self.canvas.itemconfigure(self.ring, start=90, extent=-359 * value)
                elif kind == 'warning':
                    messagebox.showwarning('UniBind', value)
                elif kind == 'error':
                    self.done = True
                    messagebox.showerror('UniBind', value)
                    self.root.destroy()
                    return
                elif kind == 'launched':
                    self.done = True
                    self.root.withdraw()
                elif kind == 'exit':
                    self.root.destroy()
                    return
        except queue.Empty:
            pass
        self.root.after(100, self.poll)
    def worker(self):
        try:
            ROOT.mkdir(parents=True,exist_ok=True); DATA.mkdir(parents=True,exist_ok=True)
            old=current(); chosen=old
            try:
                self.emit('status','Проверяем последнюю версию на GitHub…')
                tag,url,digest,size=release_metadata()
                self.emit('connection', True)
                if old is None or old.parent.name != digest:
                    self.emit('heading','Загрузка UniBind')
                    with tempfile.TemporaryDirectory(prefix='unibind-') as tmp:
                        archive=Path(tmp)/ASSET
                        def progress(done,total):
                            self.emit('status',f'Загружено {done//1024//1024} из {(total+1024*1024-1)//1024//1024} МБ')
                            self.emit('progress', min(done/total,1))
                        actual=download(url,archive,size,progress)
                        if actual != digest: raise ValueError('Контрольная сумма пакета не совпадает')
                        self.emit('heading','Установка UniBind'); self.emit('status','Проверяем и распаковываем файлы…'); self.emit('indeterminate', None)
                        chosen=commit_version(archive,digest,tag)
            except Exception as exc:
                self.emit('connection', False)
                if old is None: raise RuntimeError(f'Не удалось получить UniBind: {exc}') from exc
                chosen=old
                self.emit('warning','Не удалось проверить или установить обновление. Запускается ранее установленная версия.\n\n'+str(exc))
            ensure_launcher_installed()
            try: create_shortcut()
            except Exception as e: self.emit('warning','Программа установлена, но ярлык не создан: '+str(e))
            if not webview_installed():
                self.emit('warning','Не найден Microsoft Edge WebView2 Runtime. Если UniBind не откроется, установите Runtime с официального сайта: https://developer.microsoft.com/microsoft-edge/webview2/')
            self.emit('heading','Готово'); self.emit('status','Открываем UniBind…'); self.emit('progress',1)
            env=dict(os.environ,UNIBIND_DATA_DIR=str(DATA))
            proc=subprocess.Popen([str(chosen)],cwd=str(chosen.parent),env=env)
            self.emit('launched',None); proc.wait(); self.emit('exit',None)
        except Exception as exc: self.emit('error',str(exc))


def main():
    if os.name != 'nt': raise RuntimeError('UniBind предназначен для Windows')
    kernel=ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes=[ctypes.c_void_p,ctypes.c_bool,ctypes.c_wchar_p]; kernel.CreateMutexW.restype=ctypes.c_void_p
    handle=kernel.CreateMutexW(None,False,'Local\\UniBindLauncherSingleton')
    if not handle: raise ctypes.WinError(ctypes.get_last_error())
    if ctypes.get_last_error()==183:
        messagebox.showinfo('UniBind','UniBind уже запущен. Закройте его перед обновлением.')
        return
    Window()

if __name__=='__main__': main()
