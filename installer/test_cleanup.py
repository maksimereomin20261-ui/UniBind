import importlib.util,sys,types,tempfile,unittest,json
from pathlib import Path
from unittest.mock import patch
try:
 import tkinter
except ModuleNotFoundError:
 tk=types.ModuleType('tkinter');tk.messagebox=types.ModuleType('tkinter.messagebox');sys.modules['tkinter']=tk;sys.modules['tkinter.messagebox']=tk.messagebox
spec=importlib.util.spec_from_file_location('launcher_cleanup_test',Path(__file__).with_name('launcher.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Cleanup(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
  self.patch=patch.multiple(m,ROOT=self.root,VERSIONS=self.root/'versions',STATE=self.root/'current.json',DATA=self.root/'data');self.patch.start();self.addCleanup(self.patch.stop)
  m.VERSIONS.mkdir();m.DATA.mkdir();(m.DATA/'binds.ini').write_text('my binds')
  self.a='a'*64; self.b='b'*64;self.c='c'*64
  self.active=m.VERSIONS/self.a;self.active.mkdir()
  for name in m.REQUIRED_FILES:
   f=self.active/name;f.parent.mkdir(parents=True,exist_ok=True);f.write_text('current')
  m.STATE.write_text(json.dumps({'digest':self.a,'tag':'test'}))
  for digest in (self.b,self.c):
   p=m.VERSIONS/digest;p.mkdir();(p/'UniBind.exe').write_text('old')
  (m.VERSIONS/'other').mkdir();(m.VERSIONS/'other'/'keep').write_text('x')
 def test_only_old_hash_directories_removed(self):
  self.assertEqual(m.cleanup_old_versions(self.active/'UniBind.exe'),[])
  self.assertTrue((self.active/'UniBind.exe').exists())
  self.assertFalse((m.VERSIONS/self.b).exists());self.assertFalse((m.VERSIONS/self.c).exists())
  self.assertEqual((m.DATA/'binds.ini').read_text(),'my binds');self.assertTrue((m.VERSIONS/'other'/'keep').exists())
 def test_old_version_with_personal_files_is_preserved(self):
  old=m.VERSIONS/self.b
  (old/'config').mkdir();(old/'config'/'settings.ini').write_text('personal')
  self.assertEqual(m.cleanup_old_versions(self.active/'UniBind.exe'),[self.b])
  self.assertEqual((old/'config'/'settings.ini').read_text(),'personal')
  self.assertFalse((m.VERSIONS/self.c).exists())
  self.assertEqual((m.DATA/'binds.ini').read_text(),'my binds')
 def test_no_cleanup_if_active_missing_or_different(self):
  (self.active/'UniBind.exe').unlink();self.assertEqual(m.cleanup_old_versions(self.active/'UniBind.exe'),[])
  self.assertTrue((m.VERSIONS/self.b).exists())
 def test_failure_is_reported_and_other_versions_can_be_removed(self):
  real=m.shutil.rmtree
  def remove(path):
   if path.name==self.b:raise PermissionError('locked')
   return real(path)
  with patch.object(m.shutil,'rmtree',side_effect=remove):self.assertEqual(m.cleanup_old_versions(self.active/'UniBind.exe'),[self.b])
  self.assertTrue((m.VERSIONS/self.b).exists());self.assertFalse((m.VERSIONS/self.c).exists())
if __name__=='__main__':unittest.main(verbosity=2)
