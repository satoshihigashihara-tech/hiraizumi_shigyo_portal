#!/bin/sh
set -eu
rm -rf /tmp/a8-qa /tmp/a8-output
mkdir -p /tmp/a8-qa /tmp/a8-output
renderer_status=0
python3 /app/renderer.py \
  --job /app/fixtures/max-input-job.json \
  --output-pdf /tmp/a8-output/max-input.pdf \
  --output-docx /tmp/a8-output/max-input.docx \
  --qa-dir /tmp/a8-qa >/tmp/a8-output/result.json 2>/tmp/a8-output/render-error.txt || renderer_status=$?
if [ -f /tmp/a8-qa/page-1.png ]; then cp /tmp/a8-qa/page-1.png /tmp/a8-output/page-1.png; fi
if [ -f /tmp/a8-qa/page-2.png ]; then cp /tmp/a8-qa/page-2.png /tmp/a8-output/page-2.png; fi
if [ -f /tmp/a8-qa/extracted.txt ]; then cp /tmp/a8-qa/extracted.txt /tmp/a8-output/extracted.txt; fi
if [ -f /tmp/a8-qa/layout.txt ]; then cp /tmp/a8-qa/layout.txt /tmp/a8-output/layout.txt; fi
if [ "$renderer_status" -ne 0 ]; then exit "$renderer_status"; fi
test "$(pdfinfo /tmp/a8-output/max-input.pdf | awk '/^Pages:/ {print $2}')" = 1
pdffonts /tmp/a8-output/max-input.pdf | awk 'NR > 2 && NF { if ($5 != "yes") exit 1; found=1 } END { exit !found }'
pdffonts /tmp/a8-output/max-input.pdf | grep -F 'NotoSerifJP'
pdftotext -layout /tmp/a8-output/max-input.pdf - | grep -F '青木 幸保'
pdfinfo /tmp/a8-output/max-input.pdf > /tmp/a8-output/pdfinfo.txt
pdffonts /tmp/a8-output/max-input.pdf > /tmp/a8-output/pdffonts.txt
