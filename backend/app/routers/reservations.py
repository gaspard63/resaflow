from fastapi import APIRouter, Depends, File, HTTPException, Response, UploadFile, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_db
from app.models import Reservation, ReservationStatus, Resource, Role, User
from app.observability import RESERVATION_CONFLICTS, RESERVATIONS_CREATED
from app.schemas import ReservationIn, ReservationOut
from app.security import get_current_user
from app.storage import ObjectNotFoundError, get_storage
from app.tasks_client import enqueue
from app.uploads import new_key, safe_filename, validate_attachment

router = APIRouter(prefix="/reservations", tags=["reservations"])


def _owned(db: Session, reservation_id: int, user: User) -> Reservation:
    """Contrôle d'accès objet (A.8.3) : un utilisateur ne voit que ses réservations, l'admin voit tout."""
    reservation = db.get(Reservation, reservation_id)
    if reservation is None or (user.role != Role.admin and reservation.user_id != user.id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Réservation introuvable")
    return reservation


def _conflict() -> HTTPException:
    RESERVATION_CONFLICTS.inc()
    return HTTPException(status.HTTP_409_CONFLICT, "Ce créneau est déjà réservé")


@router.get("", response_model=list[ReservationOut])
def list_reservations(all: bool = False, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    stmt = select(Reservation).order_by(Reservation.start_at.desc()).limit(500)
    if not (all and user.role == Role.admin):
        stmt = stmt.where(Reservation.user_id == user.id)
    return db.scalars(stmt).all()


@router.post("", response_model=ReservationOut, status_code=status.HTTP_201_CREATED)
def create_reservation(body: ReservationIn, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    from app.worker.tasks import send_reservation_confirmation

    resource = db.get(Resource, body.resource_id)
    if resource is None or not resource.is_active:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ressource introuvable")
    # 1er niveau : vérification applicative (message clair, fonctionne sur toute base)
    overlap = db.scalar(
        select(Reservation.id).where(
            Reservation.resource_id == resource.id,
            Reservation.status == ReservationStatus.confirmed,
            Reservation.start_at < body.end_at,
            Reservation.end_at > body.start_at,
        )
    )
    if overlap:
        raise _conflict()
    reservation = Reservation(user_id=user.id, **body.model_dump())
    db.add(reservation)
    try:
        db.commit()
    except IntegrityError as exc:
        # 2e niveau : contrainte d'exclusion PostgreSQL (protège des requêtes concurrentes)
        db.rollback()
        raise _conflict() from exc
    RESERVATIONS_CREATED.labels(resource.type.value).inc()
    enqueue(send_reservation_confirmation, reservation.id)
    return reservation


@router.get("/{reservation_id}", response_model=ReservationOut)
def get_reservation(reservation_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    return _owned(db, reservation_id, user)


@router.post("/{reservation_id}/cancel", response_model=ReservationOut)
def cancel_reservation(reservation_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    reservation = _owned(db, reservation_id, user)
    reservation.status = ReservationStatus.cancelled
    db.commit()
    return reservation


@router.post("/{reservation_id}/attachment", response_model=ReservationOut)
async def upload_attachment(
    reservation_id: int,
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    user: User = Depends(get_current_user),
):
    reservation = _owned(db, reservation_id, user)
    data, content_type = await validate_attachment(file)
    storage, container = get_storage(), get_settings().uploads_container
    key = new_key(f"reservations/{reservation.id}")
    storage.put(container, key, data, content_type)
    if reservation.attachment_key:
        storage.delete(container, reservation.attachment_key)
    reservation.attachment_key = key
    reservation.attachment_name = safe_filename(file.filename)
    db.commit()
    return reservation


@router.get("/{reservation_id}/attachment")
def download_attachment(reservation_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    reservation = _owned(db, reservation_id, user)
    if not reservation.attachment_key:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Pas de pièce jointe")
    try:
        obj = get_storage().get(get_settings().uploads_container, reservation.attachment_key)
    except ObjectNotFoundError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Pièce jointe introuvable") from exc
    return Response(
        obj.data,
        media_type=obj.content_type,
        headers={
            "Content-Disposition": f'attachment; filename="{reservation.attachment_name}"',
            "X-Content-Type-Options": "nosniff",
        },
    )
