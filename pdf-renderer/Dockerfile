FROM debian:bookworm-20260824-slim

ENV DEBIAN_FRONTEND=noninteractive LANG=ja_JP.UTF-8 LC_ALL=ja_JP.UTF-8 PYTHONDONTWRITEBYTECODE=1
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates fontconfig libreoffice-writer locales poppler-utils python3 \
  && sed -i 's/^# *\(ja_JP.UTF-8 UTF-8\)/\1/' /etc/locale.gen \
  && locale-gen \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY assets/fonts/NotoSerifJP-Regular.otf /usr/local/share/fonts/noto/NotoSerifJP-Regular.otf
COPY assets/fonts/OFL.txt /usr/local/share/doc/noto-serif-jp/OFL.txt
RUN fc-cache -f \
  && fc-match 'Noto Serif JP' | grep -F 'NotoSerifJP-Regular.otf'
COPY assets/ assets/
COPY fixtures/ fixtures/
COPY render-settings.json renderer.py worker.py test_renderer.py test-renderer.sh ./
RUN sha256sum -c <<'EOF'
39d3621b02fd4559fa227f263f541ccc92dbd0d1b19a663891d0783407c33bfe  assets/02-02.使用許可申請書（様式第１号）.docx
2c9a12dbd4f2408c4610c7ee84a108b62d7236c3775baed618c64d9cb44b2f04  assets/fonts/NotoSerifJP-Regular.otf
EOF

USER 65532:65532
ENTRYPOINT ["python3", "/app/worker.py"]
