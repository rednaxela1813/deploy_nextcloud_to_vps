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
# НЕ переключаемся на www-data здесь
