FROM python:3.12-slim-bookworm

# psycopg[binary] trae libpq compilada: no hace falta instalar drivers del sistema ni aceptar licencias.
WORKDIR /srv
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-cache-dir ".[postgres]"

# /data solo se usa con SQLite local; debe existir antes para que el volumen herede el dueno.
RUN useradd --create-home --uid 10001 ledger && install -d -o ledger /data
USER 10001

# Cloud Run indica el puerto en PORT (8080); en local se usa 8000.
ENV PORT=8000
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=3s --start-period=90s \
    CMD python -c "import os, urllib.request as u; u.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/healthz', timeout=2)"
CMD ["sh", "-c", "exec uvicorn ledger.asgi:app --host 0.0.0.0 --port ${PORT}"]
