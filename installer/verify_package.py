"""Verify the exact release ZIP using the launcher's extractor, without installing."""
import argparse
import tempfile
from pathlib import Path

from launcher import extract_package

REQUIRED = (
    'UniBind.exe', 'ui/ui.html', 'ui/tray.html',
    'lib/WebView2/64bit/WebView2Loader.dll',
    'lib/templates/medical_profile.ini',
)


def verify(archive):
    with tempfile.TemporaryDirectory(prefix='unibind-package-check-') as tmp:
        extract_package(Path(archive), tmp)
        for name in REQUIRED:
            p = Path(tmp) / name
            if not p.is_file() or not p.stat().st_size:
                raise ValueError('Отсутствует или пуст необходимый файл: ' + name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    verify(args.archive)
    print('Пакет прошёл проверку установщиком.')
