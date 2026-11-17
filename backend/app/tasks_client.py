"""Envoi de tâches vers la file : une panne du broker ne doit pas faire échouer la requête HTTP."""

import logging

from app.observability import TASKS_ENQUEUED

log = logging.getLogger(__name__)


def enqueue(task, *args) -> bool:
    try:
        task.delay(*args)
    except Exception:  # broker indisponible : on journalise, l'API reste disponible
        log.exception("task enqueue failed", extra={"task": task.name})
        return False
    TASKS_ENQUEUED.labels(task.name.rsplit(".", 1)[-1]).inc()
    return True
