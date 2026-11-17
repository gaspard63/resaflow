"""Logs JSON sur stdout (collectés par Promtail -> Loki).

Un logger dédié "security" porte les événements de sécurité (A.8.15) avec un champ
`event` normalisé, ce qui permet des requêtes Loki du type {app="resaflow"} | json | event=~"auth.*".
"""

import json
import logging
import sys
from datetime import UTC, datetime

from opentelemetry import trace

_RESERVED = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {"message", "asctime"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        span = trace.get_current_span()
        ctx = span.get_span_context()
        if ctx.is_valid:
            payload["trace_id"] = format(ctx.trace_id, "032x")
            payload["span_id"] = format(ctx.span_id, "016x")
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str, ensure_ascii=False)


def configure_logging(level: str = "INFO") -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())
    # uvicorn : on garde les erreurs, on coupe le log d'accès (déjà couvert par les métriques)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


security_logger = logging.getLogger("security")


def security_event(event: str, **fields) -> None:
    """Journalise un événement de sécurité. Ne jamais y passer de mot de passe ni de jeton."""
    security_logger.info(event, extra={"event": event, "category": "security", **fields})
