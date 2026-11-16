#!/usr/bin/env python3
"""Build a SimpleDu v1 reading package from reviewed content and local images."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--content', required=True, type=Path)
parser.add_argument('--assets', required=True, type=Path, help='Root containing paths such as images/photo.jpg')
parser.add_argument('--batch-id', required=True)
parser.add_argument('--revision', required=True, type=int)
parser.add_argument('--title', required=True)
parser.add_argument('--markdown', type=Path, help='Optional reviewed parent Markdown')
parser.add_argument('--words', type=Path, help='Optional reviewed textbook word list')
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', args.batch_id) or not 1 <= args.revision <= 1000000:
    parser.error('A stable batch ID and a positive revision are required.')
if args.output.exists():
    parser.error('Output already exists; use a new filename. Existing files are never overwritten.')
content_bytes = args.content.read_bytes()
content = json.loads(content_bytes)
if not 1 <= len(content['articles']) <= 30 or len(content_bytes) > 2 * 1024 * 1024:
    parser.error('Content exceeds v1 limits.')
files = {'content.json': content_bytes}
asset_root = args.assets.resolve()
for image in content['images']:
    name = image['path']
    parts = name.split('/')
    if (not name.startswith('images/') or any(part in ['', '.', '..'] for part in parts)
            or '\\' in name or ':' in name or len(name.encode()) >= 240):
        parser.error(f'Unsafe image path: {name}')
    path = args.assets / name
    if path.is_symlink() or not path.resolve().is_relative_to(asset_root):
        parser.error(f'Image must be a regular local asset: {name}')
    files[name] = path.read_bytes()
if args.markdown:
    files['parent/reading.md'] = args.markdown.read_bytes()
if args.words:
    files['parent/words.txt'] = args.words.read_bytes()
if any(len(data) > 16 * 1024 * 1024 for data in files.values()) or sum(map(len, files.values())) > 96 * 1024 * 1024:
    parser.error('Assets exceed v1 size limits.')
manifest = dict(format='SimpleDu', schemaVersion=1, batchID=args.batch_id, revision=args.revision,
                title=args.title, files={name: hashlib.sha256(data).hexdigest() for name, data in files.items()})
files['manifest.json'] = json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True).encode()
args.output.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(prefix='.simpledu-', suffix='.tmp', dir=args.output.parent, delete=False) as tmp:
    temp_path = Path(tmp.name)
try:
    with zipfile.ZipFile(temp_path, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for name, data in sorted(files.items()):
            archive.writestr(name, data)
    if temp_path.stat().st_size > 64 * 1024 * 1024:
        parser.error('Compressed package exceeds 64 MiB.')
    # Link a complete file into place atomically without replacing an existing output.
    os.link(temp_path, args.output)
finally:
    temp_path.unlink(missing_ok=True)
print(f'Created {args.output.resolve()} ({len(content["articles"])} articles)')
print('The app validates the complete schema, images, answers and checksums during import.')
