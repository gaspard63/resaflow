from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.logging_conf import security_event
from app.models import Reservation, ReservationStatus, Resource, User
from app.schemas import UserOut, UserRoleIn
from app.security import require_admin

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("/users", response_model=list[UserOut])
def list_users(db: Session = Depends(get_db), _: User = Depends(require_admin)):
    return db.scalars(select(User).order_by(User.created_at)).all()


@router.patch("/users/{user_id}/role", response_model=UserOut)
def change_role(user_id: int, body: UserRoleIn, db: Session = Depends(get_db), admin: User = Depends(require_admin)):
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Utilisateur introuvable")
    if user.id == admin.id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Impossible de modifier son propre rôle")
    previous = user.role
    user.role = body.role
    db.commit()
    # changement de privilège : événement de sécurité tracé (A.8.2)
    security_event(
        "admin.user.role_change",
        user_id=admin.id,
        target_user_id=user.id,
        previous_role=previous.value,
        new_role=body.role.value,
    )
    return user


@router.get("/stats")
def stats(db: Session = Depends(get_db), _: User = Depends(require_admin)):
    return {
        "users": db.scalar(select(func.count(User.id))),
        "resources": db.scalar(select(func.count(Resource.id)).where(Resource.is_active.is_(True))),
        "reservations_confirmed": db.scalar(
            select(func.count(Reservation.id)).where(Reservation.status == ReservationStatus.confirmed)
        ),
    }
