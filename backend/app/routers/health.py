"""Sondes Kubernetes.

- /health/live  : le processus répond (livenessProbe) — ne dépend de rien d'externe,
                  sinon une panne de base redémarrerait tous les pods en boucle.
- /health/ready : la base est joignable (readinessProbe) — le pod sort du Service sinon.
"""

from fastapi import APIRouter, Depends, Response, status
from sqlalchemy import text
from sqlalchemy.orm import Session

from app import __version__
from app.db import get_db

router = APIRouter(prefix="/health", tags=["health"])


@router.get("/live")
def live():
    return {"status": "ok", "version": __version__}


@router.get("/ready")
def ready(response: Response, db: Session = Depends(get_db)):
    try:
        db.execute(text("SELECT 1"))
    except Exception:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "degraded", "database": "down"}
    return {"status": "ok", "database": "up"}
