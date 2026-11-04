import importlib.util,sys,types,tempfile,unittest
from pathlib import Path
m1=types.ModuleType('tkinter');m1.messagebox=types.ModuleType('tkinter.messagebox');sys.modules['tkinter']=m1;sys.modules['tkinter.messagebox']=m1.messagebox
spec=importlib.util.spec_from_file_location('launcher',Path(__file__).with_name('launcher.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Upgrade(unittest.TestCase):
 def test_new_installer_replaces_old(self):
  with tempfile.TemporaryDirectory() as t:
   root=Path(t); src=root/'downloaded.exe';src.write_bytes(b'new'); installed=root/'UniBind Launcher.exe';installed.write_bytes(b'old')
   saved=(m.ROOT,m.LAUNCHER,sys.executable,getattr(sys,'frozen',None))
   try:
    m.ROOT=root;m.LAUNCHER=installed;sys.executable=str(src);sys.frozen=True;m.ensure_launcher_installed()
    self.assertEqual(installed.read_bytes(),b'new');self.assertFalse((root/'UniBind Launcher.new.exe').exists())
   finally:
    m.ROOT,m.LAUNCHER,sys.executable=saved[:3]
    if saved[3] is None: del sys.frozen
    else: sys.frozen=saved[3]
 def test_unfrozen_rejected(self):
  with self.assertRaises(RuntimeError):m.ensure_launcher_installed()
if __name__=='__main__':unittest.main()
