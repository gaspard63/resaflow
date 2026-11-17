from datetime import datetime

from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile, status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_db
from app.logging_conf import security_event
from app.models import Reservation, ReservationStatus, Resource, ResourceType, User
from app.schemas import ResourceIn, ResourceOut, ResourcePatch, SlotOut
from app.security import get_current_user, require_admin
from app.storage import ObjectNotFoundError, get_storage
from app.tasks_client import enqueue
from app.uploads import new_key, validate_image

router = APIRouter(prefix="/resources", tags=["resources"])


def _get_resource(db: Session, resource_id: int) -> Resource:
    resource = db.get(Resource, resource_id)
    if resource is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Ressource introuvable")
    return resource


@router.get("", response_model=list[ResourceOut])
def list_resources(
    type: ResourceType | None = None,
    q: str | None = Query(default=None, max_length=60),
    include_inactive: bool = False,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    stmt = select(Resource).order_by(Resource.name)
    if type:
        stmt = stmt.where(Resource.type == type)
    if q:
        stmt = stmt.where(Resource.name.ilike(f"%{q}%"))
    if not include_inactive:
        stmt = stmt.where(Resource.is_active.is_(True))
    return db.scalars(stmt).all()


@router.get("/{resource_id}", response_model=ResourceOut)
def get_resource(resource_id: int, db: Session = Depends(get_db), _: User = Depends(get_current_user)):
    return _get_resource(db, resource_id)


@router.get("/{resource_id}/slots", response_model=list[SlotOut])
def resource_slots(
    resource_id: int,
    start: datetime,
    end: datetime,
    db: Session = Depends(get_db),
    _: User = Depends(get_current_user),
):
    """Créneaux occupés sur une période (alimente le calendrier du front)."""
    _get_resource(db, resource_id)
    stmt = (
        select(Reservation)
        .where(
            Reservation.resource_id == resource_id,
            Reservation.status == ReservationStatus.confirmed,
            Reservation.start_at < end,
            Reservation.end_at > start,
        )
        .order_by(Reservation.start_at)
    )
    return db.scalars(stmt).all()


@router.post("", response_model=ResourceOut, status_code=status.HTTP_201_CREATED)
def create_resource(body: ResourceIn, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    resource = Resource(**body.model_dump())
    db.add(resource)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Nom de ressource déjà utilisé") from exc
    security_event("admin.resource.create", user_id=admin.id, resource_id=resource.id)
    return resource


@router.patch("/{resource_id}", response_model=ResourceOut)
def update_resource(
    resource_id: int, body: ResourcePatch, db: Session = Depends(get_db), admin: User = Depends(require_admin)
):
    resource = _get_resource(db, resource_id)
    for field, value in body.model_dump(exclude_unset=True).items():
        setattr(resource, field, value)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Nom de ressource déjà utilisé") from exc
    security_event("admin.resource.update", user_id=admin.id, resource_id=resource.id)
    return resource


@router.delete("/{resource_id}", status_code=status.HTTP_204_NO_CONTENT)
def deactivate_resource(resource_id: int, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    """Suppression logique : l'historique des réservations est conservé."""
    resource = _get_resource(db, resource_id)
    resource.is_active = False
    db.commit()
    security_event("admin.resource.deactivate", user_id=admin.id, resource_id=resource.id)


@router.post("/{resource_id}/image", response_model=ResourceOut)
async def upload_image(
    resource_id: int, file: UploadFile = File(...), db: Session = Depends(get_db), admin: User = Depends(require_admin)
):
    from app.worker.tasks import generate_thumbnail

    resource = _get_resource(db, resource_id)
    data, content_type = await validate_image(file)
    storage = get_storage()
    container = get_settings().uploads_container
    key = new_key(f"resources/{resource.id}")
    storage.put(container, key, data, content_type)
    for old in (resource.image_key, resource.thumbnail_key):
        if old:
            storage.delete(container, old)
    resource.image_key, resource.thumbnail_key = key, None
    db.commit()
    enqueue(generate_thumbnail, resource.id)  # traitement asynchrone par le worker
    db.refresh(resource)
    return resource


@router.get("/{resource_id}/image")
def get_image(
    resource_id: int, thumbnail: bool = False, db: Session = Depends(get_db), _: User = Depends(get_current_user)
):
    resource = _get_resource(db, resource_id)
    key = (resource.thumbnail_key or resource.image_key) if thumbnail else resource.image_key
    if not key:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Pas d'image")
    try:
        obj = get_storage().get(get_settings().uploads_container, key)
    except ObjectNotFoundError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Image introuvable") from exc
    return Response(obj.data, media_type=obj.content_type, headers={"Cache-Control": "private, max-age=300"})
