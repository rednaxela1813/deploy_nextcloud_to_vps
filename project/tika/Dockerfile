FROM apache/tika:latest-full

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      tesseract-ocr tesseract-ocr-eng tesseract-ocr-jpn curl && \
    rm -rf /var/lib/apt/lists/*

ENV TIKA_OCR_ENABLED=true \
    TIKA_OCR_LANGUAGES=eng+jpn \
    TIKA_OCR_TIMEOUT=120s

EXPOSE 9998
