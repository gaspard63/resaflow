"""Métriques Prometheus métier + traces OpenTelemetry (optionnelles, activées par OTEL_ENABLED)."""

import logging

from prometheus_client import Counter, Histogram

from app.config import Settings

log = logging.getLogger(__name__)

# --- Métriques métier / sécurité (exposées sur /metrics de l'API) ---------------
AUTH_ATTEMPTS = Counter("resaflow_auth_attempts_total", "Tentatives de connexion", ["outcome"])
ACCESS_DENIED = Counter("resaflow_access_denied_total", "Accès refusés (RBAC)")
RESERVATIONS_CREATED = Counter("resaflow_reservations_created_total", "Réservations créées", ["resource_type"])
RESERVATION_CONFLICTS = Counter("resaflow_reservation_conflicts_total", "Créneaux refusés car déjà pris")
UPLOADS = Counter("resaflow_uploads_total", "Fichiers téléversés", ["kind", "outcome"])
UPLOAD_BYTES = Histogram(
    "resaflow_upload_size_bytes",
    "Taille des fichiers téléversés",
    buckets=(10_000, 100_000, 500_000, 1_000_000, 2_500_000, 5_000_000),
)
TASKS_ENQUEUED = Counter("resaflow_tasks_enqueued_total", "Tâches envoyées dans la file", ["task"])


def setup_tracing(settings: Settings, service_name: str) -> None:
    """Exporte les traces en OTLP/HTTP vers Tempo (via le endpoint configuré)."""
    if not settings.otel_enabled:
        return
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider(
        resource=Resource.create(
            {
                "service.name": service_name,
                "service.version": settings.app_version,
                "deployment.environment": settings.app_env,
            }
        )
    )
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{settings.otel_exporter_otlp_endpoint.rstrip('/')}/v1/traces"))
    )
    trace.set_tracer_provider(provider)

    from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

    from app.db import engine

    SQLAlchemyInstrumentor().instrument(engine=engine)
    log.info("tracing enabled", extra={"otlp_endpoint": settings.otel_exporter_otlp_endpoint})
