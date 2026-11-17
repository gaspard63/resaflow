"""Authentification (A.8.5) : hachage Argon2id, JWT court, RBAC user/admin."""

from datetime import UTC, datetime, timedelta

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.config import get_settings
from app.db import get_db
from app.logging_conf import security_event
from app.models import Role, User
from app.observability import ACCESS_DENIED

_hasher = PasswordHasher()  # Argon2id, paramètres OWASP par défaut
_bearer = HTTPBearer(auto_error=False)
# Hash factice pour un temps de réponse constant quand l'utilisateur n'existe pas (anti-énumération)
_DUMMY_HASH = _hasher.hash("dummy-password-for-timing")


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(password: str, hashed: str | None) -> bool:
    try:
        return _hasher.verify(hashed or _DUMMY_HASH, password) and hashed is not None
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def create_access_token(user: User) -> tuple[str, int]:
    settings = get_settings()
    expires = timedelta(minutes=settings.access_token_expire_minutes)
    now = datetime.now(UTC)
    claims = {
        "sub": str(user.id),
        "role": user.role.value,
        "iat": now,
        "exp": now + expires,
        "iss": settings.app_name,
    }
    token = jwt.encode(claims, settings.jwt_secret, algorithm=settings.jwt_algorithm)
    return token, int(expires.total_seconds())


def _client_ip(request: Request) -> str:
    fwd = request.headers.get("x-forwarded-for")
    return fwd.split(",")[0].strip() if fwd else (request.client.host if request.client else "-")


def get_current_user(
    request: Request,
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: Session = Depends(get_db),
) -> User:
    unauthorized = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Authentification requise",
        headers={"WWW-Authenticate": "Bearer"},
    )
    if creds is None:
        raise unauthorized
    settings = get_settings()
    try:
        claims = jwt.decode(
            creds.credentials,
            settings.jwt_secret,
            algorithms=[settings.jwt_algorithm],
            issuer=settings.app_name,
            options={"require": ["exp", "sub", "iss"]},
        )
    except jwt.PyJWTError as exc:
        security_event("auth.token.invalid", reason=type(exc).__name__, ip=_client_ip(request))
        raise unauthorized from exc
    user = db.get(User, int(claims["sub"]))
    if user is None or not user.is_active:
        security_event("auth.token.unknown_user", user_id=claims["sub"], ip=_client_ip(request))
        raise unauthorized
    request.state.user_id = user.id
    return user


def require_admin(request: Request, user: User = Depends(get_current_user)) -> User:
    if user.role != Role.admin:
        ACCESS_DENIED.inc()
        security_event("access.denied", user_id=user.id, path=request.url.path, required_role="admin")
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Droits administrateur requis")
    return user


client_ip = _client_ip
