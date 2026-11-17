from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_db
from app.models import Export, ExportStatus, User
from app.schemas import ExportOut
from app.security import get_current_user
from app.storage import ObjectNotFoundError, get_storage
from app.tasks_client import enqueue

router = APIRouter(prefix="/exports", tags=["exports"])


@router.post("", response_model=ExportOut, status_code=status.HTTP_202_ACCEPTED)
def request_export(db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    """Demande la génération (asynchrone) d'un PDF récapitulatif des réservations de l'utilisateur."""
    from app.worker.tasks import generate_reservations_pdf

    export = Export(user_id=user.id)
    db.add(export)
    db.commit()
    if not enqueue(generate_reservations_pdf, export.id):
        export.status, export.error = ExportStatus.failed, "File de messages indisponible"
        db.commit()
    db.refresh(export)
    return export


@router.get("", response_model=list[ExportOut])
def list_exports(db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    stmt = select(Export).where(Export.user_id == user.id).order_by(Export.created_at.desc()).limit(20)
    return db.scalars(stmt).all()


@router.get("/{export_id}", response_model=ExportOut)
def get_export(export_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    export = db.get(Export, export_id)
    if export is None or export.user_id != user.id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Export introuvable")
    return export


@router.get("/{export_id}/download")
def download_export(export_id: int, db: Session = Depends(get_db), user: User = Depends(get_current_user)):
    export = get_export(export_id, db, user)
    if export.status != ExportStatus.done or not export.blob_key:
        raise HTTPException(status.HTTP_409_CONFLICT, "Export pas encore prêt")
    try:
        obj = get_storage().get(get_settings().exports_container, export.blob_key)
    except ObjectNotFoundError as exc:
        raise HTTPException(status.HTTP_410_GONE, "Export expiré") from exc
    return Response(
        obj.data,
        media_type="application/pdf",
        headers={"Content-Disposition": f'attachment; filename="resaflow-reservations-{export.id}.pdf"'},
    )
