"""Application Celery : worker (pool threads, tâches I/O-bound) + beat (tâches planifiées).

Le worker expose ses propres métriques Prometheus sur le port WORKER_METRICS_PORT.
On utilise le pool "threads" pour que les signaux Celery et le registre Prometheus
vivent dans le même processus ; la montée en charge se fait en ajoutant des pods (HPA).
"""

import logging
import time

from celery import Celery, signals
from celery.schedules import crontab
from prometheus_client import Counter, Gauge, Histogram, start_http_server

from app.config import get_settings
from app.logging_conf import configure_logging
from app.observability import setup_tracing

settings = get_settings()

celery_app = Celery("resaflow", broker=settings.celery_broker_url, include=["app.worker.tasks"])
celery_app.conf.update(
    task_always_eager=settings.celery_task_always_eager,
    task_eager_propagates=True,
    task_acks_late=True,  # message réattribué si le pod meurt pendant la tâche
    task_reject_on_worker_lost=True,
    worker_prefetch_multiplier=1,
    task_default_queue="resaflow",
    task_ignore_result=True,  # l'état métier est en base (table exports), pas dans un backend Celery
    broker_connection_retry_on_startup=True,
    timezone="Europe/Paris",
    beat_schedule={
        "purge-old-exports": {"task": "resaflow.purge_old_exports", "schedule": crontab(hour=3, minute=0)},
        "send-reminders": {"task": "resaflow.send_daily_reminders", "schedule": crontab(hour=18, minute=0)},
    },
)

TASKS_TOTAL = Counter("resaflow_worker_tasks_total", "Tâches exécutées", ["task", "state"])
TASK_DURATION = Histogram(
    "resaflow_worker_task_duration_seconds",
    "Durée des tâches",
    ["task"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30),
)
TASKS_IN_PROGRESS = Gauge("resaflow_worker_tasks_in_progress", "Tâches en cours")
_starts: dict[str, float] = {}


@signals.setup_logging.connect
def _logging(**_):
    configure_logging(settings.log_level)


@signals.worker_init.connect
def _worker_init(**_):
    start_http_server(settings.worker_metrics_port)
    if settings.otel_enabled:
        from opentelemetry.instrumentation.celery import CeleryInstrumentor

        setup_tracing(settings, "resaflow-worker")
        CeleryInstrumentor().instrument()
    logging.getLogger("resaflow.worker").info("worker started", extra={"metrics_port": settings.worker_metrics_port})


@signals.task_prerun.connect
def _prerun(task_id=None, **_):
    _starts[task_id] = time.perf_counter()
    TASKS_IN_PROGRESS.inc()


@signals.task_postrun.connect
def _postrun(task_id=None, task=None, state=None, **_):
    TASKS_IN_PROGRESS.dec()
    started = _starts.pop(task_id, None)
    short = task.name.rsplit(".", 1)[-1] if task else "unknown"
    if started is not None:
        TASK_DURATION.labels(short).observe(time.perf_counter() - started)
    TASKS_TOTAL.labels(short, (state or "UNKNOWN").lower()).inc()
