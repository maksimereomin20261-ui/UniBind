import os
import sys
import json
import time
import shutil
import zipfile
import tempfile
import threading
import subprocess
import urllib.request
import urllib.error
from pathlib import Path
import tkinter as tk
from tkinter import messagebox

# Replace this after creating the GitHub repository:
GITHUB_REPOSITORY = "maksimereomin20261-ui/UniBind"
ASSET_NAME = "UniBind_Payload.zip"
APP_NAME = "UniBind"
INSTALL_DIR = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "Programs" / APP_NAME
BG = "#0B0B12"
PANEL = "#13131F"
PURPLE = "#8B5CF6"
PURPLE_BRIGHT = "#A78BFA"
TEXT = "#F4F1FF"
MUTED = "#9692A8"

class Launcher:
    def __init__(self, root):
        self.root = root
        self.root.title("UniBind Setup")
        self.root.geometry("520x350")
        self.root.resizable(False, False)
        self.root.configure(bg=BG)
        self.root.protocol("WM_DELETE_WINDOW", self.close_requested)
        self.busy = False
        self.cancel = False

        self.canvas = tk.Canvas(root, width=520, height=350, bg=BG, highlightthickness=0)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.create_oval(330, -160, 650, 160, fill="#171329", outline="")
        self.canvas.create_oval(-170, 230, 150, 550, fill="#151126", outline="")

        self.panel = tk.Frame(root, bg=PANEL, highlightbackground="#29243D", highlightthickness=1)
        self.panel.place(x=28, y=24, width=464, height=302)

        logo = tk.Label(self.panel, text="U", font=("Segoe UI", 30, "bold"),
                        fg=PURPLE_BRIGHT, bg="#211936", width=2, height=1)
        logo.place(x=28, y=25)
        tk.Label(self.panel, text="UniBind", font=("Segoe UI", 22, "bold"),
                 fg=TEXT, bg=PANEL).place(x=112, y=27)
        tk.Label(self.panel, text="TEXT AUTOMATION", font=("Segoe UI", 8, "bold"),
                 fg=PURPLE_BRIGHT, bg=PANEL).place(x=114, y=61)

        self.title = tk.Label(self.panel, text="Установка UniBind",
                              font=("Segoe UI", 15, "bold"), fg=TEXT, bg=PANEL)
        self.title.place(x=30, y=112)
        self.status = tk.Label(self.panel, text="Нажмите кнопку, чтобы загрузить последнюю версию",
                               font=("Segoe UI", 9), fg=MUTED, bg=PANEL, anchor="w")
        self.status.place(x=30, y=145, width=400)

        self.track = tk.Canvas(self.panel, width=402, height=8, bg="#292638", highlightthickness=0)
        self.track.place(x=30, y=190)
        self.bar = self.track.create_rectangle(0, 0, 0, 8, fill=PURPLE, outline="")
        self.percent = tk.Label(self.panel, text="ГОТОВ К УСТАНОВКЕ",
                                font=("Segoe UI", 8, "bold"), fg=PURPLE_BRIGHT, bg=PANEL)
        self.percent.place(x=30, y=210)

        self.action = tk.Button(self.panel, text="УСТАНОВИТЬ UNIBIND",
                                command=self.start, bg=PURPLE, fg="white",
                                activebackground="#7545D6", activeforeground="white",
                                relief="flat", bd=0, cursor="hand2",
                                font=("Segoe UI", 10, "bold"))
        self.action.place(x=30, y=244, width=402, height=38)

        tk.Label(self.panel, text="Официальная загрузка • GitHub Releases",
                 font=("Segoe UI", 8), fg="#6E687F", bg=PANEL).place(x=30, y=285)

    def set_status(self, title=None, status=None, pct=None, button=None):
        def update():
            if title: self.title.config(text=title)
            if status: self.status.config(text=status)
            if pct is not None:
                pct = max(0, min(100, int(pct)))
                self.track.coords(self.bar, 0, 0, 402 * pct / 100, 8)
                self.percent.config(text=f"{pct}%")
            if button: self.action.config(text=button)
        self.root.after(0, update)

    def start(self):
        if self.busy: return
        if "YOUR_GITHUB_USERNAME" in GITHUB_REPOSITORY:
            messagebox.showerror("Настройка загрузчика",
                "Сначала укажите имя GitHub-аккаунта в launcher.py и пересоберите установщик.")
            return
        self.busy = True
        self.action.config(state="disabled", text="ВЫПОЛНЯЕТСЯ...")
        threading.Thread(target=self.install, daemon=True).start()

    def download(self, url, destination, stage):
        req = urllib.request.Request(url, headers={"User-Agent": "UniBind-Setup"})
        with urllib.request.urlopen(req, timeout=30) as response, open(destination, "wb") as out:
            total = int(response.headers.get("Content-Length", "0") or 0)
            done = 0
            while True:
                chunk = response.read(128 * 1024)
                if not chunk: break
                out.write(chunk)
                done += len(chunk)
                pct = (done * 100 / total) if total else 0
                self.set_status(status=f"{stage}: {done // (1024*1024)} МБ", pct=pct if total else 0)

    def safe_extract(self, archive, destination):
        dest = destination.resolve()
        with zipfile.ZipFile(archive) as z:
            for member in z.infolist():
                target = (destination / member.filename).resolve()
                if target != dest and dest not in target.parents:
                    raise RuntimeError("Архив содержит недопустимый путь.")
            z.extractall(destination)

    def install(self):
        tmp = Path(tempfile.mkdtemp(prefix="unibind_setup_"))
        try:
            self.set_status(title="Загрузка UniBind", status="Подключаемся к GitHub Releases...", pct=0)
            url = f"https://github.com/{GITHUB_REPOSITORY}/releases/latest/download/{ASSET_NAME}"
            archive = tmp / ASSET_NAME
            self.download(url, archive, "Загрузка файлов")
            self.set_status(title="Установка UniBind", status="Распаковываем приложение...", pct=75)
            INSTALL_DIR.mkdir(parents=True, exist_ok=True)
            self.safe_extract(archive, INSTALL_DIR)
            exe = INSTALL_DIR / "UniBind.exe"
            if not exe.exists():
                raise RuntimeError("В загруженном архиве не найден UniBind.exe.")
            self.set_status(status="Создаём ярлык на рабочем столе...", pct=92)
            self.create_shortcut(exe)
            self.set_status(title="UniBind готов!", status="Установка завершена. Можно запускать программу.", pct=100)
            self.root.after(0, lambda: self.action.config(state="normal", text="ЗАПУСТИТЬ UNIBIND", command=self.launch))
        except urllib.error.HTTPError as e:
            self.fail(f"GitHub вернул ошибку {e.code}. Проверьте, что Release опубликован и файл {ASSET_NAME} прикреплён.")
        except Exception as e:
            self.fail(str(e))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
            self.busy = False

    def create_shortcut(self, exe):
        desktop = Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Desktop"
        desktop.mkdir(parents=True, exist_ok=True)
        shortcut = desktop / "UniBind.lnk"
        ps = (
            "$w=New-Object -ComObject WScript.Shell;"
            f"$s=$w.CreateShortcut('{str(shortcut).replace(chr(39), chr(39)*2)}');"
            f"$s.TargetPath='{str(exe).replace(chr(39), chr(39)*2)}';"
            f"$s.WorkingDirectory='{str(INSTALL_DIR).replace(chr(39), chr(39)*2)}';"
            "$s.Save()"
        )
        subprocess.run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
                       check=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))

    def fail(self, message):
        self.set_status(title="Не удалось установить", status=message, pct=0)
        self.root.after(0, lambda: self.action.config(state="normal", text="ПОВТОРИТЬ", command=self.start))
        self.root.after(0, lambda: messagebox.showerror("UniBind Setup", message))

    def launch(self):
        exe = INSTALL_DIR / "UniBind.exe"
        if exe.exists():
            subprocess.Popen([str(exe)], cwd=str(INSTALL_DIR))
            self.root.destroy()
        else:
            messagebox.showerror("UniBind", "Файл приложения не найден. Переустановите программу.")

    def close_requested(self):
        if self.busy:
            if not messagebox.askyesno("Выход", "Загрузка ещё выполняется. Закрыть установщик?"):
                return
        self.root.destroy()

if __name__ == "__main__":
    root = tk.Tk()
    Launcher(root)
    root.mainloop()
