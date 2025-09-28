# Базовый Tika Server с уже настроенным OCR’ом внутри образа
FROM logicalspark/docker-tikaserver:2.9.2

USER root
# ставим языковые пакеты Tesseract — английский и японский
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr tesseract-ocr-eng tesseract-ocr-jpn && \
    rm -rf /var/lib/apt/lists/*

# (не обязательно) подсказываем Tika нужные языки и включаем OCR
ENV TIKA_OCR_ENABLED=true \
    TIKA_OCR_LANGUAGES=eng+jpn \
    TIKA_OCR_TIMEOUT=120s
EXPOSE 9998
