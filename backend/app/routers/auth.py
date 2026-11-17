from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.db import get_db
from app.logging_conf import security_event
from app.models import User
from app.observability import AUTH_ATTEMPTS
from app.schemas import LoginIn, RegisterIn, TokenOut, UserOut
from app.security import client_ip, create_access_token, get_current_user, hash_password, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=UserOut, status_code=status.HTTP_201_CREATED)
def register(body: RegisterIn, request: Request, db: Session = Depends(get_db)):
    email = body.email.lower()
    if db.scalar(select(User).where(func.lower(User.email) == email)):
        raise HTTPException(status.HTTP_409_CONFLICT, "Un compte existe déjà avec cet e-mail")
    user = User(email=email, full_name=body.full_name, hashed_password=hash_password(body.password))
    db.add(user)
    db.commit()
    security_event("auth.register", user_id=user.id, ip=client_ip(request))
    return user


@router.post("/login", response_model=TokenOut)
def login(body: LoginIn, request: Request, db: Session = Depends(get_db)):
    user = db.scalar(select(User).where(func.lower(User.email) == body.email.lower()))
    ok = verify_password(body.password, user.hashed_password if user else None)
    if not ok or user is None or not user.is_active:
        AUTH_ATTEMPTS.labels("failure").inc()
        # pas d'e-mail en clair dans les logs : on journalise seulement le domaine
        security_event("auth.login.failure", email_domain=body.email.split("@")[-1], ip=client_ip(request))
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Identifiants invalides")
    AUTH_ATTEMPTS.labels("success").inc()
    security_event("auth.login.success", user_id=user.id, ip=client_ip(request))
    token, expires_in = create_access_token(user)
    return TokenOut(access_token=token, expires_in=expires_in)


@router.get("/me", response_model=UserOut)
def me(user: User = Depends(get_current_user)):
    return user
