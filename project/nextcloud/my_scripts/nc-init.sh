#!/bin/sh
set -euo pipefail

echo "[nc-init] waiting for Nextcloud (occ)..."
cd /var/www/html

occ() { php occ "$@"; }

# Ждём, пока инстанс установлен и база доступна
i=0
until occ status 2>/dev/null | grep -q 'installed: true'; do
  i=$((i+1))
  if [ "$i" -ge 120 ]; then
    echo "[nc-init] occ is not ready after 120 tries" >&2
    exit 1
  fi
  sleep 2
done
echo "[nc-init] occ is ready"

# -----------------------------
# Базовые приложения
# -----------------------------
for app in \
  groupfolders \
  fulltextsearch \
  files_fulltextsearch \
  fulltextsearch_elasticsearch \
  files_fulltextsearch_tesseract \
  encryption
do
  occ app:install "$app" 2>/dev/null || true
  occ app:enable  "$app" 2>/dev/null || true
done

# -----------------------------
# Прокси/URL/доверенные домены
# -----------------------------
HOST="${NEXTCLOUD_OVERWRITE_HOST:-documents.deilmann.sk}"
occ config:system:set overwriteprotocol --value="https"
occ config:system:set overwritehost     --value="${HOST}"
occ config:system:set overwrite.cli.url --value="https://${HOST}"

# trusted_domains: детерминированно забиваем первые слоты
occ config:system:set trusted_domains 0 --value="${HOST}"
occ config:system:set trusted_domains 1 --value="localhost"
occ config:system:set trusted_domains 2 --value="127.0.0.1"

# trusted_proxies (если нужен обратный прокси в docker-сети)
occ config:system:set trusted_proxies 0 --value="127.0.0.1"      || true
occ config:system:set trusted_proxies 1 --value="172.16.0.0/12"  || true

# -----------------------------
# Redis/Valkey
# -----------------------------
occ config:system:set memcache.local   --value="\OC\Memcache\Redis"
occ config:system:set memcache.locking --value="\OC\Memcache\Redis"
occ config:system:set redis host --value="valkey"
occ config:system:set redis port --type=integer --value="6379"

# -----------------------------
# Язык интерфейса (по желанию)
# -----------------------------
occ config:system:set default_language --value="en"
occ config:system:set default_locale   --value="en_US"

# -----------------------------
# Fulltext Search: платформа + Elasticsearch
# -----------------------------
# Выбираем платформу поиска = Elasticsearch
occ config:app:set fulltextsearch search_platform \
  --value="OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"

# Правильные ключи для коннекта к ES
occ config:app:set fulltextsearch_elasticsearch elastic_host  --value="http://elasticsearch:9200"
occ config:app:set fulltextsearch_elasticsearch elastic_index --value="nextcloud"

# (опционально) НЕ трогаем analyzer_tokenizer здесь.
# Для японского лучше использовать ES template/kuromoji на стороне Elasticsearch.

# -----------------------------
# Files provider: типы файлов и чанки
# -----------------------------
occ config:app:set files_fulltextsearch files_pdf        --value=1
occ config:app:set files_fulltextsearch files_office     --value=1
occ config:app:set files_fulltextsearch files_image      --value=1
occ config:app:set files_fulltextsearch files_chunk_size --value=2

# -----------------------------
# OCR (Tesseract) — языки/режимы
# (плагин: files_fulltextsearch_tesseract; в контейнере установлен tesseract + eng/jpn)
# -----------------------------
occ config:app:set files_fulltextsearch_tesseract lang             --value="jpn+jpn_vert+eng"
occ config:app:set files_fulltextsearch_tesseract tesseract_lang   --value="jpn+jpn_vert+eng" || true
# чистим устаревшие ключи, если были
occ config:app:delete files_fulltextsearch_tesseract psm       || true
occ config:app:delete files_fulltextsearch_tesseract pdf       || true
occ config:app:delete files_fulltextsearch_tesseract pdf_limit || true
# актуальные ключи
occ config:app:set files_fulltextsearch_tesseract tesseract_psm       --type=integer --value=6
occ config:app:set files_fulltextsearch_tesseract tesseract_pdf       --type=integer --value=1
occ config:app:set files_fulltextsearch_tesseract tesseract_pdf_limit --type=integer --value=20

# -----------------------------
# Фоновые задачи = cron
# -----------------------------
occ background:cron || true

# -----------------------------
# (опционально) включить master-key шифрование на первом запуске
# -----------------------------
if ! occ encryption:status | grep -q 'enabled: true'; then
  occ encryption:enable-master-key || true
fi

# -----------------------------
# Первая индексация (не валим init, если долго)
# -----------------------------
occ fulltextsearch:check  || true
occ fulltextsearch:index  || true

echo "[nc-init] done"
