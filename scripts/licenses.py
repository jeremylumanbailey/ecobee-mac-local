"""Preserve third-party license and package metadata in the standalone bundle."""
from importlib.metadata import distributions
from pathlib import Path
import shutil
import sys

destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
for dist in distributions():
    name = dist.metadata['Name']
    folder = destination / name
    folder.mkdir(exist_ok=True)
    metadata = dist.read_text('METADATA') or dist.read_text('PKG-INFO') or ''
    (folder / 'PACKAGE.txt').write_text(f"{name} {dist.version}\n\n" + metadata, encoding='utf8')
    for file in dist.files or []:
        if any(word in str(file).lower() for word in ('license', 'copying', 'notice')):
            source = Path(dist.locate_file(file))
            if source.is_file():
                target = folder / str(file).replace('/', '_')
                shutil.copyfile(source, target)
python_license = Path(sys.base_prefix) / 'lib' / f'python{sys.version_info.major}.{sys.version_info.minor}' / 'LICENSE.txt'
if python_license.exists(): shutil.copyfile(python_license, destination / 'Python-LICENSE.txt')
