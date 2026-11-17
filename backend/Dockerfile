# Image back-end multi-stage : une étape de build (compilation des wheels) et deux cibles
# d'exécution légères qui partagent les mêmes couches :
#   --target api     -> API FastAPI (uvicorn)
#   --target worker  -> worker Celery (aussi utilisé pour Celery beat et le job de migration)

ARG PYTHON_IMAGE=python:3.13-slim

############################
# 1. Build : dépendances dans un virtualenv isolé
############################
FROM ${PYTHON_IMAGE} AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /build
COPY requirements.txt .
RUN pip install -r requirements.txt

############################
# 2. Base d'exécution commune (sans compilateur, sans pip cache, utilisateur non-root)
############################
FROM ${PYTHON_IMAGE} AS runtime
LABEL org.opencontainers.image.source="https://github.com/<votre-compte>/resaflow" \
      org.opencontainers.image.title="resaflow-backend" \
      org.opencontainers.image.licenses="MIT"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY --chown=app:app alembic.ini ./
COPY --chown=app:app alembic ./alembic
COPY --chown=app:app app ./app
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
USER 10001:10001

############################
# 3a. API
############################
FROM runtime AS api
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health/live', timeout=2).status == 200 else 1)"]
# 1 processus par conteneur : on scale horizontalement par pods (HPA), pas par workers uvicorn
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*", "--timeout-graceful-shutdown", "20", "--no-server-header"]

############################
# 3b. Worker Celery
############################
FROM runtime AS worker
EXPOSE 9100
CMD ["celery", "-A", "app.worker.celery_app", "worker", "--pool=threads", "--concurrency=4", \
     "--loglevel=INFO", "-Q", "resaflow", "--without-gossip", "--without-mingle"]
