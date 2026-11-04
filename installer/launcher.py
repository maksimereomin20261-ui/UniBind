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
    """Compact installer UI; worker and on-disk update logic remain unchanged."""
    VERSION = '2027.10 · Beta 1 HF2'
    WIDTH, HEIGHT = 500, 310

    def __init__(self, autostart=True, run_loop=True):
        self.root = tk.Tk()
        self.root.withdraw()
        self.root.title('UniBind — установка и обновление')
        self.root.resizable(False, False)
        self.root.overrideredirect(True)
        self.root.configure(bg='#010203')
        # The unique colour only appears outside the rounded window silhouette.
        try:
            self.root.wm_attributes('-transparentcolor', '#010203')
        except tk.TclError:
            pass
        self.scale = self.system_scale()
        w, h = self.p(self.WIDTH), self.p(self.HEIGHT)
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        x, y = max(0, (sw-w)//2), max(0, (sh-h)//2)
        self.root.geometry(f'{w}x{h}+{x}+{y}')
        self.canvas = tk.Canvas(self.root, width=w, height=h, bg='#010203',
                                highlightthickness=0, bd=0)
        self.canvas.pack(fill='both', expand=True)
        self.root.protocol('WM_DELETE_WINDOW', self.close)
        self.root.bind('<Escape>', lambda _event: self.close())
        self.root.bind('<Map>', self.on_map)
        self.events = queue.Queue()
        self.done = False
        self.determinate = False
        self.actual_progress = 0.0
        self.display_progress = 0.0
        self.spinner_angle = 0
        self.minimized = False
        self.text_fades = {}
        self.draw_ui()
        self.root.deiconify()
        self.root.after(50, self.poll)
        self.root.after(40, self.animate)
        if autostart:
            threading.Thread(target=self.worker, daemon=True).start()
        if run_loop:
            self.root.mainloop()

    @staticmethod
    def system_scale():
        if os.name == 'nt':
            try:
                return min(2.5, max(1.0, ctypes.windll.user32.GetDpiForSystem() / 96.0))
            except (AttributeError, OSError):
                pass
        return 1.0

    def p(self, value):
        return round(value * self.scale)

    def shape(self, coords):
        return tuple(self.p(v) for v in coords)

    def rounded(self, x1, y1, x2, y2, r, fill, outline=None, width=1, **kw):
        points = (x1+r,y1, x2-r,y1, x2,y1, x2,y1+r, x2,y2-r, x2,y2,
                  x2-r,y2, x1+r,y2, x1,y2, x1,y2-r, x1,y1+r, x1,y1)
        return self.canvas.create_polygon(*self.shape(points), smooth=True, splinesteps=24,
                                          fill=fill, outline=outline or fill, width=self.p(width), **kw)

    def text(self, x, y, value, size, color, weight='normal', **kw):
        return self.canvas.create_text(self.p(x), self.p(y), text=value, fill=color,
                                       font=('Segoe UI', -self.p(size), weight), **kw)

    def draw_ui(self):
        c = self.canvas
        self.rounded(1, 1, 499, 309, 12, '#0b081c', '#56319a', 1)
        # Understated, clipped-at-the-edges dark violet curves, matching the reference.
        c.create_polygon(*self.shape((2,39,130,39,112,52,91,72,62,90,2,107)),
                         fill='#110b29', outline='', smooth=True)
        c.create_polygon(*self.shape((499,63,499,178,445,168,405,184,370,207,394,169,433,134,464,105)),
                         fill='#150b33', outline='', smooth=True)
        c.create_line(*self.shape((2,38,498,38)), fill='#231a3c')
        self.text(19, 19, 'U', 24, '#9b63ff', 'bold')
        self.text(41, 19, 'UniBind', 15, '#f6f3ff', 'bold', anchor='w')
        # Canvas buttons are real, focusable controls with generous click targets.
        for name, x in [('minimize', 444), ('close', 478)]:
            c.create_rectangle(*self.shape((x-16,3,x+16,35)), fill='#0b081c', outline='', tags=(name,))
        c.create_line(*self.shape((439,19,449,19)), fill='#ddd3f3', width=self.p(1), tags=('minimize',))
        c.create_line(*self.shape((473,14,483,24)), fill='#ddd3f3', width=self.p(1), tags=('close',))
        c.create_line(*self.shape((483,14,473,24)), fill='#ddd3f3', width=self.p(1), tags=('close',))
        c.tag_bind('minimize', '<Button-1>', lambda _e: self.minimize())
        c.tag_bind('close', '<Button-1>', lambda _e: self.close())
        c.tag_bind('minimize', '<Enter>', lambda _e: c.configure(cursor='hand2'))
        c.tag_bind('close', '<Enter>', lambda _e: c.configure(cursor='hand2'))
        c.tag_bind('minimize', '<Leave>', lambda _e: c.configure(cursor=''))
        c.tag_bind('close', '<Leave>', lambda _e: c.configure(cursor=''))
        self.rounded(211, 52, 289, 130, 16, '#171032')
        self.rounded(214, 55, 286, 127, 14, '#0a0719', '#6330b9')
        self.text(250, 91, 'U', 46, '#9556ff', 'bold')
        self.text(250, 148, 'UniBind', 34, '#e5dbfc', 'bold')
        self.heading = self.text(250, 180, 'Подготовка к установке…', 16, '#b6a5d9', width=self.p(450))
        # Soft glow and a slim track. Segment colours create a restrained gradient.
        self.rounded(41, 205, 423, 217, 6, '#21113e')
        self.rounded(43, 207, 421, 215, 4, '#211738', '#2a1b4c')
        self.bar_parts = []
        for i in range(42):
            t=i/41
            color = '#%02x%02x%02x' % (int(105+57*t), int(49+40*t), 246+int(9*t))
            part=c.create_rectangle(self.p(44),self.p(208),self.p(44),self.p(214), fill=color, outline='')
            self.bar_parts.append(part)
        self.percent = self.text(451, 211, '', 15, '#a975ff', 'bold')
        # Spinner is a true indeterminate activity indicator, not a progress gauge.
        c.create_oval(*self.shape((151, 235, 165, 249)), outline='#35245e', width=self.p(2))
        self.ring = c.create_arc(*self.shape((151, 235, 165, 249)), start=20, extent=100,
                                 style='arc', outline='#a063ff', width=self.p(2))
        self.status = self.text(176, 242, 'Проверяем версию на GitHub…', 13, '#b9a9d5', anchor='w', width=self.p(290))
        c.create_line(*self.shape((2,269,498,269)), fill='#20172e')
        c.create_oval(*self.shape((142,282,154,294)), outline='#9f88c6', width=self.p(1))
        self.text(148, 288, 'i', 9, '#b7a4d3', 'bold')
        self.text(166, 288, 'Пожалуйста, не закрывайте окно', 12, '#a998c6', anchor='w')

    def on_map(self, _event):
        if self.minimized and self.root.state() == 'normal':
            self.minimized = False
            self.root.overrideredirect(True)

    def minimize(self):
        # Tk requires a window-manager frame while iconifying. Restore our frameless
        # window as soon as it is mapped again.
        self.minimized = True
        self.root.overrideredirect(False)
        self.root.iconify()

    def set_text(self, item, value, target):
        # New strings fade in from the dark background; pending updates coalesce.
        self.canvas.itemconfigure(item, text=value, fill='#44375e')
        self.text_fades[item] = (0, target)

    def animate(self):
        if not self.done:
            self.spinner_angle = (self.spinner_angle - 16) % 360
            self.canvas.itemconfigure(self.ring, start=self.spinner_angle)
            self.display_progress += (self.actual_progress-self.display_progress)*0.24
            if abs(self.actual_progress-self.display_progress)<0.001:
                self.display_progress=self.actual_progress
            for i, part in enumerate(self.bar_parts):
                left = 44+376*i/42
                right = min(44+376*(i+1)/42,44+376*self.display_progress)
                self.canvas.coords(part, self.p(left),self.p(208),self.p(max(left,right)),self.p(214))
            for item, (step, target) in list(self.text_fades.items()):
                step += 1
                fraction = min(1, step/5)
                rgb0 = (68,55,94); rgb1 = tuple(int(target[i:i+2],16) for i in (1,3,5))
                color = '#'+''.join(f'{round(a+(b-a)*fraction):02x}' for a,b in zip(rgb0,rgb1))
                self.canvas.itemconfigure(item, fill=color)
                if fraction >= 1: del self.text_fades[item]
                else: self.text_fades[item] = (step,target)
            self.root.after(40, self.animate)

    def close(self):
        if self.done:
            self.root.destroy()
        else:
            messagebox.showinfo('UniBind', 'Дождитесь завершения установки или проверки обновления.', parent=self.root)

    def emit(self, kind, value):
        self.events.put((kind, value))

    def poll(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == 'status':
                    self.set_text(self.status, value, '#b9a9d5')
                elif kind == 'heading':
                    self.set_text(self.heading, value, '#b6a5d9')
                elif kind == 'indeterminate':
                    self.determinate = False
                    self.actual_progress = 0
                    self.display_progress = 0
                    self.canvas.itemconfigure(self.percent, text='')
                elif kind == 'progress':
                    self.determinate = True
                    self.actual_progress = max(0.0, min(1.0, value))
                    self.canvas.itemconfigure(self.percent, text=f'{int(self.actual_progress*100)}%')
                elif kind == 'warning':
                    messagebox.showwarning('UniBind', value, parent=self.root)
                elif kind == 'error':
                    self.done = True
                    messagebox.showerror('UniBind', value, parent=self.root)
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
        self.root.after(50, self.poll)
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
            self.emit('heading','Готово'); self.emit('status','Открываем UniBind…'); self.emit('indeterminate',None)
            env=dict(os.environ,UNIBIND_DATA_DIR=str(DATA))
            proc=subprocess.Popen([str(chosen)],cwd=str(chosen.parent),env=env)
            self.emit('launched',None); proc.wait(); self.emit('exit',None)
        except Exception as exc: self.emit('error',str(exc))


def main():
    if os.name != 'nt': raise RuntimeError('UniBind предназначен для Windows')
    # Per-monitor DPI awareness is set before creating any Tk windows.
    try:
        ctypes.windll.user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4 & ((1 << (ctypes.sizeof(ctypes.c_void_p)*8)) - 1)))
    except (AttributeError, OSError):
        pass
    kernel=ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.argtypes=[ctypes.c_void_p,ctypes.c_bool,ctypes.c_wchar_p]; kernel.CreateMutexW.restype=ctypes.c_void_p
    handle=kernel.CreateMutexW(None,False,'Local\\UniBindLauncherSingleton')
    if not handle: raise ctypes.WinError(ctypes.get_last_error())
    if ctypes.get_last_error()==183:
        messagebox.showinfo('UniBind','UniBind уже запущен. Закройте его перед обновлением.')
        return
    Window()

if __name__=='__main__': main()
