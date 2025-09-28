FROM nextcloud:31-apache

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr tesseract-ocr-eng \
      tesseract-ocr-jpn tesseract-ocr-jpn-vert \
      imagemagick curl jq && \
    rm -rf /var/lib/apt/lists/* \
 && sed -i 's/rights="none" pattern="PDF"/rights="read|write" pattern="PDF"/' /etc/ImageMagick-6/policy.xml || true

# init-скрипт
COPY my_scripts/nc-init.sh /nc-init.sh
RUN chmod +x /nc-init.sh

# ... ваш базовый Dockerfile nextcloud ...

# Install Tesseract + lang packs (Debian/Ubuntu or Alpine)
RUN if command -v apt-get >/dev/null 2>&1; then \
      set -eux; \
      apt-get update; \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        tesseract-ocr tesseract-ocr-eng tesseract-ocr-jpn \
        ghostscript poppler-utils; \
      rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
      set -eux; \
      apk add --no-cache \
        tesseract-ocr \
        tesseract-ocr-data-eng \
        tesseract-ocr-data-jpn \
        ghostscript poppler-utils; \
    else \
      echo "Unknown base image: add tesseract manually" && exit 1; \
    fi

# (опционально) на всякий случай, если путь к tessdata нестандартный:
ENV TESSDATA_PREFIX=/usr/share/tesseract-ocr/5/tessdata/

