import logging
import time

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from prometheus_fastapi_instrumentator import Instrumentator

from app import __version__
from app.config import get_settings
from app.logging_conf import configure_logging
from app.observability import setup_tracing
from app.routers import admin, auth, exports, health, reservations, resources

settings = get_settings()
configure_logging(settings.log_level)
log = logging.getLogger("resaflow.api")

app = FastAPI(
    title="ResaFlow API",
    version=__version__,
    description="Réservation de ressources (salles, matériel) — API REST stateless",
    docs_url="/api/docs" if settings.app_env != "prod" else None,
    openapi_url="/api/openapi.json" if settings.app_env != "prod" else None,
)

if settings.cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_methods=["GET", "POST", "PATCH", "DELETE"],
        allow_headers=["Authorization", "Content-Type"],
    )


@app.middleware("http")
async def security_headers_and_timing(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "no-referrer")
    response.headers.setdefault("Cache-Control", "no-store")
    if request.url.path.startswith("/api/") and response.status_code >= 500:
        log.error(
            "request failed",
            extra={
                "path": request.url.path,
                "method": request.method,
                "status": response.status_code,
                "duration_ms": round((time.perf_counter() - start) * 1000, 1),
            },
        )
    return response


API_PREFIX = "/api/v1"
app.include_router(health.router)
for module in (auth, resources, reservations, exports, admin):
    app.include_router(module.router, prefix=API_PREFIX)

# Métriques RED (Rate / Errors / Duration) exposées sur /metrics — non publié par l'Ingress
Instrumentator(
    excluded_handlers=["/metrics", "/health/live", "/health/ready"],
    should_group_status_codes=False,
).instrument(
    app,
    latency_lowr_buckets=(0.025, 0.05, 0.1, 0.25, 0.3, 0.5, 1, 2.5, 5),
).expose(app, include_in_schema=False)

if settings.otel_enabled:
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    setup_tracing(settings, "resaflow-api")
    FastAPIInstrumentor.instrument_app(app, excluded_urls="health,metrics")

log.info("api started", extra={"env": settings.app_env, "version": __version__})
