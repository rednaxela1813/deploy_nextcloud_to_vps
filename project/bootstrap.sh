#!/usr/bin/env bash
set -euo pipefail

# ------------ helpers ------------
log(){ printf "\033[1;36m[bootstrap]\033[0m %s\n" "$*"; }
err(){ printf "\033[1;31m[error]\033[0m %s\n" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s || true)"
DIST_ID=""
if [ -f /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  DIST_ID="${ID:-}"
fi

# ------------ ensure docker ------------
ensure_docker() {
  if have docker; then
    log "Docker найден: $(docker --version)"
  else
    log "Docker не найден — устанавливаю..."
    if [[ "$OS" == "Darwin" ]]; then
      if have brew; then
        brew install --cask docker || { err "Не удалось установить Docker Desktop через Homebrew"; exit 1; }
        log "Запускаю Docker.app (впервые может попросить права)..."
        open -a Docker || true
        log "Жду старт Docker..."
        # ждём socket
        for i in {1..60}; do have docker && docker info >/dev/null 2>&1 && break || sleep 2; done
      else
        err "На macOS без Homebrew автоустановка невозможна. Сначала поставь Docker Desktop вручную: https://www.docker.com/products/docker-desktop/"; exit 1;
      fi
    else
      # Linux — официальная установка Docker CE
      if have apt-get; then
        sudo apt-get update -y
        sudo apt-get install -y ca-certificates curl gnupg lsb-release
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/${DIST_ID:-ubuntu}/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DIST_ID:-ubuntu} \
$(. /etc/os-release && echo ${VERSION_CODENAME:-jammy}) stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
        sudo apt-get update -y
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo usermod -aG docker "$USER" || true
        log "Если это первая установка Docker — перезайди в сессию (или `newgrp docker`)."
      elif have dnf; then
        sudo dnf -y install dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER" || true
      else
        err "Автоустановка Docker не поддержана для этой системы. Установи Docker вручную."; exit 1;
      fi
    fi
  fi
}

# ------------ ensure compose v2 ------------
ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    log "Docker Compose v2 найден: $(docker compose version | head -n1)"
  elif have docker-compose; then
    log "Найден docker-compose v1: $(docker-compose --version)"
    log "Буду использовать 'docker-compose' вместо 'docker compose'."
    export USE_COMPOSE_V1=1
  else
    if [[ "$OS" == "Darwin" ]] && have brew; then
      brew install docker-compose || true
      if ! have docker-compose; then err "Не удалось поставить docker-compose"; exit 1; fi
      export USE_COMPOSE_V1=1
    else
      err "Compose не найден. Установи docker compose plugin (см. установку Docker выше)."; exit 1;
    fi
  fi
}

dc() {
  if [ "${USE_COMPOSE_V1:-0}" = "1" ]; then docker-compose "$@"; else docker compose "$@"; fi
}

# ------------ write files (idempotent) ------------
write_file() {
  local path="$1"
  shift
  local dir; dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir"
  if [ -f "$path" ]; then
    log "Файл уже существует: $path — перезаписываю (backup: .bak)"
    cp -f "$path" "$path.bak" || true
  else
    log "Создаю файл: $path"
  fi
  cat >"$path" <<'EOF'
'"$@"'
EOF
}

# ------------ generate project files ------------
generate_project() {
  # .env
  cat > .env <<'EOF'
# --- Postgres ---
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=nextcloud

# --- Nextcloud admin (смените!) ---
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=admin
NEXTCLOUD_TRUSTED_DOMAINS=nextcloud localhost 127.0.0.1

# --- Elasticsearch JVM ---
ES_JAVA_OPTS=-Xms512m -Xmx512m
EOF

  # docker-compose.yml
  cat > docker-compose.yml <<'EOF'
services:
  db:
    image: postgres:16
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - db_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 20

  valkey:
    image: valkey/valkey:latest
    restart: unless-stopped
    command: ["valkey-server", "--appendonly", "yes"]
    volumes:
      - valkey_data:/data
    healthcheck:
      test: ["CMD", "valkey-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 20

  elasticsearch:
    build: ./elasticsearch
    restart: unless-stopped
    environment:
      - discovery.type=single-node
      - xpack.security.enabled=false
      - ES_JAVA_OPTS=${ES_JAVA_OPTS}
    ulimits:
      memlock: { soft: -1, hard: -1 }
    volumes:
      - es_data:/usr/share/elasticsearch/data
    ports:
      - "9200:9200"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost:9200 >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 30

  nextcloud:
    build: ./nextcloud
    restart: unless-stopped
    depends_on:
      db: { condition: service_healthy }
      valkey: { condition: service_started }
      elasticsearch: { condition: service_healthy }
    environment:
      POSTGRES_HOST: db
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}

      NEXTCLOUD_ADMIN_USER: ${NEXTCLOUD_ADMIN_USER}
      NEXTCLOUD_ADMIN_PASSWORD: ${NEXTCLOUD_ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: ${NEXTCLOUD_TRUSTED_DOMAINS}

      REDIS_HOST: valkey
      REDIS_HOST_PORT: 6379
    volumes:
      - nextcloud_html:/var/www/html
      - nextcloud_data:/var/www/html/data
    ports:
      - "8080:80"
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://localhost/status.php >/dev/null || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 60

  nc-init:
    build: ./nextcloud
    depends_on:
      nextcloud: { condition: service_started }
    user: "33:33"
    volumes:
      - nextcloud_html:/var/www/html
      - nextcloud_data:/var/www/html/data
      - ./scripts/nc-init.sh:/nc-init.sh:ro
    entrypoint: ["/bin/sh","-lc"]
    command: "/nc-init.sh"
    restart: "no"

volumes:
  db_data:
  valkey_data:
  es_data:
  nextcloud_html:
  nextcloud_data:
EOF

  # elasticsearch/Dockerfile
  mkdir -p elasticsearch
  cat > elasticsearch/Dockerfile <<'EOF'
FROM docker.elastic.co/elasticsearch/elasticsearch:8.14.3
RUN elasticsearch-plugin install --batch analysis-icu \
 && elasticsearch-plugin install --batch analysis-kuromoji
EOF

  # nextcloud/Dockerfile
  mkdir -p nextcloud
  cat > nextcloud/Dockerfile <<'EOF'
FROM nextcloud:31-apache

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr tesseract-ocr-eng \
      tesseract-ocr-jpn tesseract-ocr-jpn-vert \
      imagemagick curl jq && \
    rm -rf /var/lib/apt/lists/*

# Разрешить PDF/PS для ImageMagick (превью/конвертации)
RUN sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' /etc/ImageMagick-6/policy.xml || true
EOF

  # scripts/nc-init.sh
  mkdir -p scripts
  cat > scripts/nc-init.sh <<'EOF'
#!/bin/sh
set -e

echo "[nc-init] wait for Nextcloud to finish installation..."
until curl -fsS http://nextcloud/status.php | grep -q '"installed":true'; do
  sleep 3
done
echo "[nc-init] nextcloud is installed"

cd /var/www/html

# Удаляем Office, если вдруг включён
php occ app:disable richdocuments || true
php occ app:remove  richdocuments || true
php occ config:app:delete richdocuments wopi_url || true
php occ config:app:delete richdocuments public_wopi_url || true

# Нужные приложения
php occ app:install groupfolders                   || php occ app:enable groupfolders                   || true
php occ app:install fulltextsearch                 || php occ app:enable fulltextsearch                 || true
php occ app:install files_fulltextsearch           || php occ app:enable files_fulltextsearch           || true
php occ app:install fulltextsearch_elasticsearch   || php occ app:enable fulltextsearch_elasticsearch   || true
php occ app:install files_fulltextsearch_tesseract || php occ app:enable files_fulltextsearch_tesseract || true
php occ app:install encryption                     || php occ app:enable encryption                     || true

# Redis (Valkey)
php occ config:system:set memcache.local   --value="\OC\Memcache\Redis"
php occ config:system:set memcache.locking --value="\OC\Memcache\Redis"
php occ config:system:set redis host --value="valkey"
php occ config:system:set redis port --type=integer --value="6379"

# Интерфейс: дефолт на английском
php occ config:system:set default_language --value="en"
php occ config:system:set default_locale   --value="en_US"

# Full-Text Search: платформа + ES
php occ fulltextsearch:configure '{"search_platform":"OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"}'
php occ fulltextsearch_elasticsearch:configure '{"elastic_host":"http://elasticsearch:9200","elastic_index":"nextcloud","analyzer_tokenizer":"icu"}'
php occ config:app:set fulltextsearch                 search_platform           --value="OCA\\FullTextSearch_Elasticsearch\\Platform\\ElasticSearchPlatform"
php occ config:app:set fulltextsearch_elasticsearch   host                     --value="http://elasticsearch:9200"
php occ config:app:set fulltextsearch_elasticsearch   index                    --value="nextcloud"
php occ config:app:set fulltextsearch_elasticsearch   analyzer_tokenizer       --value="icu"

# Индексация типов
php occ config:app:set files_fulltextsearch files_pdf   --type=integer --value=1
php occ config:app:set files_fulltextsearch files_image --type=integer --value=1

# OCR: включаем Tesseract (eng+jpn), psm=6, pdf=1
php occ config:app:set files_fulltextsearch_tesseract enabled              --type=integer --value=1
php occ config:app:set files_fulltextsearch_tesseract tesseract_enabled    --type=integer --value=1
php occ config:app:set files_fulltextsearch_tesseract lang                 --value="eng+jpn"
php occ config:app:set files_fulltextsearch_tesseract tesseract_lang       --value="eng+jpn"
php occ config:app:set files_fulltextsearch_tesseract psm                  --type=integer --value=6
php occ config:app:set files_fulltextsearch_tesseract tesseract_psm        --type=integer --value=6
php occ config:app:set files_fulltextsearch_tesseract pdf                  --type=integer --value=1
php occ config:app:set files_fulltextsearch_tesseract tesseract_pdf        --type=integer --value=1
php occ config:app:set files_fulltextsearch_tesseract pdf_limit            --type=integer --value=10
php occ config:app:set files_fulltextsearch_tesseract tesseract_pdf_limit  --type=integer --value=10

# Самопроверка
php occ fulltextsearch:check || true

# Первая индексация (может занять время)
php occ fulltextsearch:index || true

echo "[nc-init] done"
EOF
  chmod +x scripts/nc-init.sh
}

# ------------ bring up stack ------------
bring_up() {
  log "Собираю и поднимаю контейнеры..."
  dc up -d --build
  log "Ожидаю готовности Elasticsearch..."
  for i in {1..60}; do
    if curl -fsS http://localhost:9200 >/dev/null 2>&1; then break; fi
    sleep 2
  done
  log "Ожидаю, пока Nextcloud станет доступен на http://localhost:8080 ..."
  for i in {1..60}; do
    if curl -fsS http://localhost:8080/status.php >/dev/null 2>&1; then break; fi
    sleep 2
  done
  log "Контейнеры:"
  dc ps
  log "Готово: открой http://localhost:8080 и войди (admin/admin — см. .env)."
  log "Проверка FTS: docker compose exec -u www-data nextcloud php occ fulltextsearch:check"
}

# ------------ main ------------
ensure_docker
ensure_compose
generate_project
bring_up
