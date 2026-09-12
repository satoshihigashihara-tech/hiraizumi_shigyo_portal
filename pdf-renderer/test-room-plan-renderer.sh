#!/bin/sh
set -eu
rm -rf /tmp/a11-qa /tmp/a11-output
mkdir -p /tmp/a11-qa /tmp/a11-output
trap 'cp /tmp/a11-qa/* /tmp/a11-output/ 2>/dev/null || true' EXIT
python3 /app/renderer.py --job /app/fixtures/max-room-plan-job.json \
  --output-pdf /tmp/a11-output/max-room-plan.pdf --qa-dir /tmp/a11-qa >/tmp/a11-output/result.json
pages="$(pdfinfo /tmp/a11-output/max-room-plan.pdf | awk '/^Pages:/ {print $2}')"
test "$pages" -ge 1
test "$pages" -le 8
pdffonts /tmp/a11-output/max-room-plan.pdf | awk 'NR > 2 && NF { if ($5 != "yes") exit 1; found=1 } END { exit !found }'
pdffonts /tmp/a11-output/max-room-plan.pdf | grep -F 'NotoSerifJP'
pdftotext -raw /tmp/a11-output/max-room-plan.pdf - | tr -d '[:space:]' | grep -F '職員用配置表'
pdftotext -raw /tmp/a11-output/max-room-plan.pdf - | grep -F '10000000-0000-4000-8000-000000000115'
pdfinfo /tmp/a11-output/max-room-plan.pdf > /tmp/a11-output/pdfinfo.txt
pdffonts /tmp/a11-output/max-room-plan.pdf > /tmp/a11-output/pdffonts.txt
cp /tmp/a11-qa/page-*.png /tmp/a11-output/
