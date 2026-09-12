#!/bin/sh
set -eu
mkdir -p /tmp/a10-output /tmp/a10-qa
python3 - <<'PY'
import json
from pathlib import Path
job = json.loads(Path('/app/fixtures/max-input-job.json').read_text())
job['source_snapshot']['previously_approved'] = True
Path('/tmp/a10-output/job.json').write_text(json.dumps(job, ensure_ascii=False))
PY
renderer_status=0
python3 /app/renderer.py --job /tmp/a10-output/job.json --output-pdf /tmp/a10-output/post-approval.pdf \
  --output-docx /tmp/a10-output/post-approval.docx --qa-dir /tmp/a10-qa \
  >/tmp/a10-output/result.json 2>/tmp/a10-output/render-error.txt || renderer_status=$?
cp -R /tmp/a10-qa/. /tmp/a10-output/
if [ "$renderer_status" -ne 0 ]; then exit "$renderer_status"; fi
python3 - <<'PY'
import zipfile
from xml.etree import ElementTree as ET
with zipfile.ZipFile('/tmp/a10-output/post-approval.docx') as archive:
    doc = ET.fromstring(archive.read('word/document.xml'))
    w = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
    assert not doc.findall(f'.//{w}strike'), 'approved change must not be struck out'
    assert sum((node.text or '').count('（変更）') for node in doc.findall(f'.//{w}t')) == 2
PY
test "$(pdfinfo /tmp/a10-output/post-approval.pdf | awk '/^Pages:/ {print $2}')" = 1
pdffonts /tmp/a10-output/post-approval.pdf > /tmp/a10-output/pdffonts.txt
pdftotext -raw /tmp/a10-output/post-approval.pdf - | tr -d '[:space:]' | grep -F '（変更）'
