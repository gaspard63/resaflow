"""Tâches de fond.

- send_reservation_confirmation : e-mail de confirmation (déclenché à la création)
- generate_thumbnail            : miniature de l'image d'une ressource (déclenché à l'upload)
- generate_reservations_pdf     : export PDF des réservations, stocké dans Blob Storage
- purge_old_exports             : nettoyage planifié (beat, 3h) des exports expirés
- send_daily_reminders          : rappel planifié (beat, 18h) des réservations du lendemain
"""

import io
import logging
from datetime import UTC, datetime, timedelta

from PIL import Image
from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import getSampleStyleSheet
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle
from sqlalchemy import select

from app.config import get_settings
from app.db import SessionLocal
from app.mailer import send_email
from app.models import Export, ExportStatus, Reservation, ReservationStatus, Resource, User
from app.storage import get_storage
from app.uploads import new_key
from app.worker.celery_app import celery_app

log = logging.getLogger("resaflow.worker")
RETRY = {
    "autoretry_for": (ConnectionError, TimeoutError, OSError),
    "retry_backoff": True,
    "max_retries": 5,
    "retry_jitter": True,
}


def _fmt(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%d/%m/%Y %H:%M UTC")


@celery_app.task(name="resaflow.send_reservation_confirmation", **RETRY)
def send_reservation_confirmation(reservation_id: int) -> None:
    with SessionLocal() as db:
        r = db.get(Reservation, reservation_id)
        if r is None:
            return
        send_email(
            r.user.email,
            f"[ResaFlow] Réservation confirmée : {r.resource.name}",
            f"Bonjour {r.user.full_name},\n\nVotre réservation n°{r.id} est confirmée.\n"
            f"Ressource : {r.resource.name} ({r.resource.location})\n"
            f"Du {_fmt(r.start_at)} au {_fmt(r.end_at)}\nObjet : {r.purpose or '-'}\n\n— ResaFlow",
        )
    log.info("confirmation sent", extra={"reservation_id": reservation_id})


@celery_app.task(name="resaflow.generate_thumbnail", **RETRY)
def generate_thumbnail(resource_id: int) -> None:
    s, storage = get_settings(), get_storage()
    with SessionLocal() as db:
        resource = db.get(Resource, resource_id)
        if resource is None or not resource.image_key:
            return
        original = storage.get(s.uploads_container, resource.image_key)
        with Image.open(io.BytesIO(original.data)) as img:
            img = img.convert("RGB")
            img.thumbnail((320, 320))
            out = io.BytesIO()
            img.save(out, format="WEBP", quality=80)
        key = new_key(f"resources/{resource.id}/thumb")
        storage.put(s.uploads_container, key, out.getvalue(), "image/webp")
        if resource.thumbnail_key:
            storage.delete(s.uploads_container, resource.thumbnail_key)
        resource.thumbnail_key = key
        db.commit()
    log.info("thumbnail generated", extra={"resource_id": resource_id})


def _build_pdf(user: User, reservations: list[Reservation]) -> bytes:
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, title="ResaFlow — Mes réservations")
    styles = getSampleStyleSheet()
    rows = [["N°", "Ressource", "Début", "Fin", "Statut"]] + [
        [str(r.id), r.resource.name, _fmt(r.start_at), _fmt(r.end_at), r.status.value] for r in reservations
    ]
    table = Table(rows, repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1f4e79")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("GRID", (0, 0), (-1, -1), 0.25, colors.grey),
                ("FONTSIZE", (0, 0), (-1, -1), 9),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, colors.HexColor("#f2f2f2")]),
            ]
        )
    )
    doc.build(
        [
            Paragraph("ResaFlow — Récapitulatif des réservations", styles["Title"]),
            Paragraph(f"{user.full_name} — généré le {_fmt(datetime.now(UTC))}", styles["Normal"]),
            Spacer(1, 12),
            table if reservations else Paragraph("Aucune réservation.", styles["Normal"]),
        ]
    )
    return buf.getvalue()


@celery_app.task(name="resaflow.generate_reservations_pdf", **RETRY)
def generate_reservations_pdf(export_id: int) -> None:
    s = get_settings()
    with SessionLocal() as db:
        export = db.get(Export, export_id)
        if export is None:
            return
        export.status = ExportStatus.running
        db.commit()
        try:
            user = db.get(User, export.user_id)
            reservations = db.scalars(
                select(Reservation).where(Reservation.user_id == user.id).order_by(Reservation.start_at)
            ).all()
            key = new_key(f"exports/{user.id}")
            get_storage().put(s.exports_container, key, _build_pdf(user, list(reservations)), "application/pdf")
            export.blob_key, export.status = key, ExportStatus.done
        except Exception as exc:
            export.status, export.error = ExportStatus.failed, type(exc).__name__
            log.exception("export failed", extra={"export_id": export_id})
            raise
        finally:
            export.finished_at = datetime.now(UTC)
            db.commit()
    log.info("export generated", extra={"export_id": export_id})


@celery_app.task(name="resaflow.purge_old_exports")
def purge_old_exports() -> int:
    s, storage = get_settings(), get_storage()
    limit = datetime.now(UTC) - timedelta(days=s.export_retention_days)
    with SessionLocal() as db:
        old = db.scalars(select(Export).where(Export.created_at < limit)).all()
        for export in old:
            if export.blob_key:
                storage.delete(s.exports_container, export.blob_key)
            db.delete(export)
        db.commit()
    log.info("exports purged", extra={"count": len(old)})
    return len(old)


@celery_app.task(name="resaflow.send_daily_reminders")
def send_daily_reminders() -> int:
    now = datetime.now(UTC)
    sent = 0
    with SessionLocal() as db:
        upcoming = db.scalars(
            select(Reservation).where(
                Reservation.status == ReservationStatus.confirmed,
                Reservation.reminder_sent.is_(False),
                Reservation.start_at >= now,
                Reservation.start_at < now + timedelta(days=1),
            )
        ).all()
        for r in upcoming:
            send_email(
                r.user.email,
                f"[ResaFlow] Rappel : {r.resource.name} demain",
                f"Rappel : réservation n°{r.id} le {_fmt(r.start_at)}.",
            )
            r.reminder_sent = True
            sent += 1
        db.commit()
    log.info("reminders sent", extra={"count": sent})
    return sent
