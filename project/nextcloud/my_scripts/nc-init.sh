#!/bin/sh
set -e

echo "[nc-init] wait nextcloud install..."
until curl -fsS http://localhost/status.php | grep -q '"installed":true'; do sleep 3; done
echo "[nc-init] installed"

cd /var/www/html

# Базовые приложения
php occ app:install groupfolders                   || php occ app:enable groupfolders                   || true
php occ app:install fulltextsearch                 || php occ app:enable fulltextsearch                 || true
php occ app:install files_fulltextsearch           || php occ app:enable files_fulltextsearch           || true
php occ app:install fulltextsearch_elasticsearch   || php occ app:enable fulltextsearch_elasticsearch   || true
php occ app:install files_fulltextsearch_tesseract || php occ app:enable files_fulltextsearch_tesseract || true
php occ app:install encryption                     || php occ app:enable encryption                     || true

# Прокси и URL (под nginx https)
php occ config:system:set overwriteprotocol --value="https"
php occ config:system:set overwritehost     --value="${NEXTCLOUD_OVERWRITE_HOST:-documents.deilmann.sk}"
php occ config:system:set overwrite.cli.url --value="https://${NEXTCLOUD_OVERWRITE_HOST:-documents.deilmann.sk}"
php occ config:system:set trusted_domains 1 --value="${NEXTCLOUD_OVERWRITE_HOST:-documents.deilmann.sk}" || true
php occ config:system:set trusted_proxies  0 --value="127.0.0.1" || true
php occ config:system:set trusted_proxies  1 --value="172.16.0.0/12" || true

# Redis/Valkey
php occ config:system:set memcache.local   --value="\OC\Memcache\Redis"
php occ config:system:set memcache.locking --value="\OC\Memcache\Redis"
php occ config:system:set redis host --value="valkey"
php occ config:system:set redis port --type=integer --value="6379"

# Язык UI
php occ config:system:set default_language --value="en"
php occ config:system:set default_locale   --value="en_US"

# FTS: ES + kuromoji
php occ config:app:set fulltextsearch_elasticsearch analyzer_tokenizer --value="kuromoji"
php occ config:app:set fulltextsearch_elasticsearch host  --value="http://elasticsearch:9200"
php occ config:app:set fulltextsearch_elasticsearch index --value="nextcloud"

# OCR: jpn + jpn_vert + eng, PDF
php occ config:app:set files_fulltextsearch_tesseract lang           --value="jpn+jpn_vert+eng"
php occ config:app:set files_fulltextsearch_tesseract tesseract_lang --value="jpn+jpn_vert+eng" || true
php occ config:app:delete files_fulltextsearch_tesseract psm || true
php occ config:app:delete files_fulltextsearch_tesseract pdf || true
php occ config:app:delete files_fulltextsearch_tesseract pdf_limit || true
php occ config:app:set files_fulltextsearch_tesseract tesseract_psm       --type=integer --value=6
php occ config:app:set files_fulltextsearch_tesseract tesseract_pdf       --type=integer --value=1
php occ config:app:set files_fulltextsearch_tesseract tesseract_pdf_limit --type=integer --value=20

# Режим фоновых задач = cron
php occ background:cron || true

# (опц) включение master key шифрования при первом запуске:
if ! php occ encryption:status | grep -q 'enabled: true'; then
  php occ encryption:enable-master-key || true
fi

# Индексация "по-тихому" на первом раскате (не падаем, если долго)
php occ fulltextsearch:check || true
php occ fulltextsearch:index || true

echo "[nc-init] done"
