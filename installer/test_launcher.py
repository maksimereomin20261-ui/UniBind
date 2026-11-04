import hashlib
import importlib.util
import tempfile
import sys
import types
import unittest
import zipfile
from pathlib import Path

try:
    import tkinter
except ModuleNotFoundError:
    tk=types.ModuleType('tkinter'); tk.messagebox=types.ModuleType('tkinter.messagebox')
    sys.modules['tkinter']=tk; sys.modules['tkinter.messagebox']=tk.messagebox

spec=importlib.util.spec_from_file_location('launcher',Path(__file__).with_name('launcher.py'))
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=Path(self.tmp.name)
        self.required={'UniBind.exe':b'exe', 'ui/ui.html':b'ui', 'lib/WebView2/64bit/WebView2Loader.dll':b'dll', 'lib/templates/medical_profile.ini':b'profile'}
    def tearDown(self): self.tmp.cleanup()
    def make(self, entries):
        path=self.root/'package.zip'
        with zipfile.ZipFile(path,'w') as z:
            for name,content in entries: z.writestr(name,content)
        return path
    def test_switch_keeps_old_version_and_failed_install_preserves_state(self):
        old_root,old_versions,old_state=m.ROOT,m.VERSIONS,m.STATE
        try:
            m.ROOT=self.root; m.VERSIONS=self.root/'versions'; m.STATE=self.root/'current.json'
            a='a'*64; b='b'*64
            first=m.commit_version(self.make(self.required.items()),a,'v-first')
            self.assertEqual(m.current(),first)
            with self.assertRaises(ValueError):
                m.commit_version(self.make([('UniBind.exe',b'x')]),b,'v-broken')
            self.assertEqual(m.current(),first)
            second=m.commit_version(self.make(self.required.items()),b,'v-second')
            self.assertEqual(m.current(),second)
            self.assertTrue(first.is_file())
        finally:
            m.ROOT,m.VERSIONS,m.STATE=old_root,old_versions,old_state
    def test_valid(self):
        m.extract_package(self.make(self.required.items()),self.root/'out')
        self.assertTrue((self.root/'out/UniBind.exe').is_file())
    def test_traversal_and_data_rejected(self):
        for bad in ['../escape','ui/../../escape','C:/bad','ui\\evil','config/settings.ini']:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                m.extract_package(self.make([*self.required.items(), (bad,b'x')]),self.root/'out')
    def test_missing_file_rejected(self):
        with self.assertRaises(ValueError): m.extract_package(self.make([('UniBind.exe',b'x')]),self.root/'out')
    def test_duplicate_case_rejected(self):
        with self.assertRaises(ValueError): m.extract_package(self.make([*self.required.items(),('UI/UI.HTML',b'x')]),self.root/'out')

if __name__=='__main__': unittest.main()
