import hashlib
import importlib.util
import io
import os
import tempfile
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

try:
    import tkinter
except ModuleNotFoundError:
    tk = types.ModuleType('tkinter'); tk.messagebox = types.ModuleType('tkinter.messagebox')
    sys.modules['tkinter'] = tk; sys.modules['tkinter.messagebox'] = tk.messagebox

spec = importlib.util.spec_from_file_location('launcher_compact_test', Path(__file__).with_name('launcher.py'))
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class DownloadProgress(unittest.TestCase):
    def test_percent_comes_from_actual_downloaded_bytes(self):
        payload = b'a' * 300_000
        class Response(io.BytesIO):
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
        samples = []
        with tempfile.TemporaryDirectory() as d, patch.object(m.urllib.request, 'urlopen', return_value=Response(payload)):
            digest = m.download('https://example.org/file', Path(d)/'app.zip', len(payload), lambda n,t:samples.append((n,t)))
            self.assertEqual(digest, hashlib.sha256(payload).hexdigest())
            self.assertEqual((Path(d)/'app.zip').stat().st_size, len(payload))
        self.assertEqual(samples, [(131072,300000), (262144,300000), (300000,300000)])

@unittest.skipUnless(os.name == 'nt', 'Windows UI test')
class WindowsUI(unittest.TestCase):
    def make_window(self, scale=1.0):
        with patch.object(m.Window, 'system_scale', return_value=scale):
            w = m.Window(autostart=False, run_loop=False)
        w.root.update()
        self.addCleanup(lambda: self.destroy(w))
        return w

    @staticmethod
    def destroy(w):
        try:
            for callback in w.root.tk.call('after', 'info'):
                w.root.after_cancel(callback)
            w.root.destroy()
        except m.tk.TclError: pass

    def test_center_and_fixed_dimensions_at_three_scales(self):
        for scale in (1.0,1.25,1.5):
            with self.subTest(scale=scale):
                w=self.make_window(scale)
                width,height=round(500*scale),round(310*scale)
                self.assertEqual((w.root.winfo_width(),w.root.winfo_height()),(width,height))
                self.assertEqual(w.root.winfo_x(),max(0,(w.root.winfo_screenwidth()-width)//2))
                self.assertEqual(w.root.winfo_y(),max(0,(w.root.winfo_screenheight()-height)//2))
                self.assertEqual(w.root.resizable(),(0,0))
                self.destroy(w)

    def test_progress_unknown_to_real_and_status_transitions(self):
        w=self.make_window()
        self.assertTrue(all(w.canvas.itemcget(part,'state') == 'hidden' for part in w.bar_parts))
        w.emit('heading','Загрузка UniBind'); w.emit('status','Загрузка файла…'); w.emit('progress',0.68); w.poll()
        self.assertEqual(w.canvas.itemcget(w.percent,'text'),'68%')
        self.assertAlmostEqual(w.actual_progress,0.68)
        self.assertEqual(w.canvas.itemcget(w.heading,'text'),'Загрузка UniBind')
        self.assertEqual(w.canvas.itemcget(w.status,'text'),'Загрузка файла…')
        for _ in range(60): w.animate()
        self.assertAlmostEqual(w.display_progress,0.68,places=2)
        self.assertTrue(any(w.canvas.itemcget(part,'state') == 'normal' for part in w.bar_parts))
        w.emit('heading','Установка UniBind'); w.emit('status','Распаковываем файлы…'); w.emit('indeterminate',None); w.poll(); w.animate()
        self.assertEqual(w.canvas.itemcget(w.percent,'text'),'')
        self.assertFalse(w.determinate)
        self.assertTrue(all(w.canvas.itemcget(part,'state') == 'hidden' for part in w.bar_parts))
        self.assertEqual(w.canvas.itemcget(w.heading,'text'),'Установка UniBind')
        w.emit('heading','Готово'); w.emit('status','Открываем UniBind…'); w.poll()
        self.assertEqual(w.canvas.itemcget(w.heading,'text'),'Готово')

    def test_window_controls_and_error(self):
        w=self.make_window()
        with patch.object(m.messagebox,'showinfo') as info:
            w.canvas.event_generate('<Button-1>',x=w.p(478),y=w.p(19)); w.root.update()
            info.assert_called_once()
        w.canvas.event_generate('<Button-1>',x=w.p(444),y=w.p(19)); w.root.update()
        self.assertEqual(w.root.state(),'iconic')
        w.root.deiconify(); w.root.update()
        self.assertEqual(w.root.state(),'normal')
        self.assertTrue(w.root.overrideredirect())
        with patch.object(m.messagebox,'showerror') as error:
            w.emit('error','Проверочная ошибка'); w.poll()
            error.assert_called_once()

if __name__ == '__main__': unittest.main(verbosity=2)
