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


class Window:
    def __init__(self):
        self.root=tk.Tk(); self.root.title('UniBind'); self.root.geometry('510x310'); self.root.resizable(False,False)
        self.root.configure(bg='#0c0b13'); self.root.protocol('WM_DELETE_WINDOW', self.close)
        box=tk.Frame(self.root,bg='#171421',highlightbackground='#342c47',highlightthickness=1)
        box.place(x=22,y=22,width=466,height=266)
        tk.Label(box,text='U',font=('Segoe UI',24,'bold'),fg='#b59cff',bg='#29203f',width=2).place(x=27,y=24)
        tk.Label(box,text='UniBind',font=('Segoe UI',21,'bold'),fg='#f6f3ff',bg='#171421').place(x=102,y=24)
        tk.Label(box,text='УСТАНОВКА И ОБНОВЛЕНИЕ',font=('Segoe UI',8,'bold'),fg='#a78bfa',bg='#171421').place(x=104,y=60)
        self.heading=tk.Label(box,text='Подготовка',font=('Segoe UI',14,'bold'),fg='#f6f3ff',bg='#171421',anchor='w')
        self.heading.place(x=28,y=111,width=405)
        self.status=tk.Label(box,text='Проверяем последнюю версию…',font=('Segoe UI',9),fg='#a9a4b6',bg='#171421',anchor='w',wraplength=400,justify='left')
        self.status.place(x=28,y=148,width=405,height=40)
        self.canvas=tk.Canvas(box,width=404,height=7,bg='#302b3b',highlightthickness=0); self.canvas.place(x=28,y=205)
        self.bar=self.canvas.create_rectangle(0,0,0,7,fill='#a78bfa',outline='')
        self.caption=tk.Label(box,text='Не закрывайте окно',font=('Segoe UI',8),fg='#a9a4b6',bg='#171421',anchor='w')
        self.caption.place(x=28,y=221,width=400)
        self.events=queue.Queue(); self.done=False
        self.root.after(100,self.poll); threading.Thread(target=self.worker,daemon=True).start()
        self.root.mainloop()
    def close(self):
        if self.done: self.root.destroy()
        else: messagebox.showinfo('UniBind','Дождитесь завершения установки или проверки обновления.')
    def emit(self, kind, value): self.events.put((kind,value))
    def poll(self):
        try:
            while True:
                kind,value=self.events.get_nowait()
                if kind=='status': self.status.config(text=value)
                elif kind=='heading': self.heading.config(text=value)
                elif kind=='progress': self.canvas.coords(self.bar,0,0,404*value,7)
                elif kind=='warning': messagebox.showwarning('UniBind',value)
                elif kind=='error':
                    self.done=True; messagebox.showerror('UniBind',value); self.root.destroy(); return
                elif kind=='launched': self.done=True; self.root.withdraw()
                elif kind=='exit': self.root.destroy(); return
        except queue.Empty: pass
        self.root.after(100,self.poll)
    def worker(self):
        try:
            ROOT.mkdir(parents=True,exist_ok=True); DATA.mkdir(parents=True,exist_ok=True)
            old=current(); chosen=old
            try:
                self.emit('status','Проверяем последнюю версию на GitHub…')
                tag,url,digest,size=release_metadata()
                if old is None or old.parent.name != digest:
                    self.emit('heading','Загрузка UniBind')
                    with tempfile.TemporaryDirectory(prefix='unibind-') as tmp:
                        archive=Path(tmp)/ASSET
                        def progress(done,total):
                            self.emit('status',f'Загружено {done//1024//1024} из {(total+1024*1024-1)//1024//1024} МБ')
                            self.emit('progress', min(done/total,1))
                        actual=download(url,archive,size,progress)
                        if actual != digest: raise ValueError('Контрольная сумма пакета не совпадает')
                        self.emit('heading','Установка UniBind'); self.emit('status','Проверяем и распаковываем файлы…')
                        chosen=commit_version(archive,digest,tag)
            except Exception as exc:
                if old is None: raise RuntimeError(f'Не удалось получить UniBind: {exc}') from exc
                chosen=old
                self.emit('warning','Не удалось проверить или установить обновление. Запускается ранее установленная версия.\n\n'+str(exc))
            if not getattr(sys,'frozen',False): raise RuntimeError('Для установки требуется собранный EXE загрузчика')
            if Path(sys.executable).resolve()!=LAUNCHER.resolve():
                # Keep existing launcher if a new setup is launched during an existing installation.
                if not LAUNCHER.exists(): shutil.copy2(sys.executable,LAUNCHER)
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
