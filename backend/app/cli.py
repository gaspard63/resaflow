"""Commandes d'exploitation : `python -m app.cli seed` (exécuté par le Job de migration)."""

import logging
import sys

from sqlalchemy import select

from app.config import get_settings
from app.db import SessionLocal
from app.logging_conf import configure_logging, security_event
from app.models import Resource, ResourceType, Role, User
from app.security import hash_password

log = logging.getLogger("resaflow.cli")

DEMO_RESOURCES = [
    ("Salle Confluence", ResourceType.room, "Bâtiment A, 2e étage", 12, 'Écran 75", visio'),
    ("Salle Fourvière", ResourceType.room, "Bâtiment A, RDC", 6, "Tableau blanc"),
    ("Amphi Bellecour", ResourceType.room, "Bâtiment B", 80, "Sonorisation, vidéoprojecteur"),
    ("Vidéoprojecteur portable #1", ResourceType.equipment, "Accueil", 1, "Full HD, HDMI/USB-C"),
    ("Casque VR Meta Quest 3", ResourceType.equipment, "Lab innovation", 1, "Avec contrôleurs"),
]


def seed() -> None:
    s = get_settings()
    with SessionLocal() as db:
        if s.admin_email and s.admin_password:
            admin = db.scalar(select(User).where(User.email == s.admin_email.lower()))
            if admin is None:
                db.add(
                    User(
                        email=s.admin_email.lower(),
                        full_name="Administrateur",
                        hashed_password=hash_password(s.admin_password),
                        role=Role.admin,
                    )
                )
                security_event("admin.bootstrap", email_domain=s.admin_email.split("@")[-1])
        if not db.scalar(select(Resource.id).limit(1)):
            for name, rtype, location, capacity, desc in DEMO_RESOURCES:
                db.add(Resource(name=name, type=rtype, location=location, capacity=capacity, description=desc))
        db.commit()
    log.info("seed done")


def upload_backup(path: str) -> str:
    """Envoie un dump PostgreSQL vers Blob Storage (CronJob de sauvegarde, A.8.13).

    Le conteneur backups-<env> a une politique de cycle de vie (Terraform) : Cool à J+7, suppression à J+30.
    """
    from datetime import UTC, datetime
    from pathlib import Path

    from app.storage import get_storage

    data = Path(path).read_bytes()
    if len(data) < 100:
        raise SystemExit(f"dump suspect ({len(data)} octets) : sauvegarde annulée")
    key = f"{get_settings().app_env}/resaflow-{datetime.now(UTC):%Y%m%dT%H%M%SZ}.sql.gz"
    get_storage().put(get_settings().backups_container, key, data, "application/gzip")
    security_event("backup.uploaded", key=key, size_bytes=len(data))
    return key


if __name__ == "__main__":
    configure_logging(get_settings().log_level)
    commands = {"seed": (seed, 0), "upload-backup": (upload_backup, 1)}
    if len(sys.argv) < 2 or sys.argv[1] not in commands or len(sys.argv) - 2 != commands[sys.argv[1]][1]:
        sys.exit("usage: python -m app.cli seed | upload-backup <fichier.sql.gz>")
    func, _ = commands[sys.argv[1]]
    func(*sys.argv[2:])
