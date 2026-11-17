from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field, model_validator

from app.models import ExportStatus, ReservationStatus, ResourceType, Role


class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# --- Auth ---------------------------------------------------------------
class RegisterIn(BaseModel):
    email: EmailStr
    full_name: str = Field(min_length=2, max_length=120)
    password: str = Field(min_length=10, max_length=128)


class LoginIn(BaseModel):
    # Pas de validation de délivrabilité à la connexion : on compare simplement à la base
    # (évite de bloquer un compte existant pour une règle de format, et ne renseigne pas l'attaquant).
    email: str = Field(min_length=3, max_length=254, pattern=r"^[^@\s]+@[^@\s]+$")
    password: str = Field(max_length=128)


class TokenOut(BaseModel):
    access_token: str
    token_type: str = "bearer"  # noqa: S105 - type de jeton OAuth2, pas un secret
    expires_in: int


class UserOut(ORM):
    id: int
    email: str  # déjà validé à l'inscription : pas de revalidation en sortie (comptes amorcés, domaines internes)
    full_name: str
    role: Role
    is_active: bool
    created_at: datetime


class UserRoleIn(BaseModel):
    role: Role


# --- Resources -------------------------------------------------------------
class ResourceIn(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    type: ResourceType
    description: str = Field(default="", max_length=2000)
    location: str = Field(default="", max_length=120)
    capacity: int = Field(default=1, ge=1, le=1000)


class ResourcePatch(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=120)
    description: str | None = Field(default=None, max_length=2000)
    location: str | None = Field(default=None, max_length=120)
    capacity: int | None = Field(default=None, ge=1, le=1000)
    is_active: bool | None = None


class ResourceOut(ORM):
    id: int
    name: str
    type: ResourceType
    description: str
    location: str
    capacity: int
    is_active: bool
    has_image: bool = False
    has_thumbnail: bool = False

    @model_validator(mode="before")
    @classmethod
    def _flags(cls, data):
        if hasattr(data, "image_key"):
            return {
                **{
                    k: getattr(data, k)
                    for k in ("id", "name", "type", "description", "location", "capacity", "is_active")
                },
                "has_image": data.image_key is not None,
                "has_thumbnail": data.thumbnail_key is not None,
            }
        return data


# --- Reservations ----------------------------------------------------------
class ReservationIn(BaseModel):
    resource_id: int
    start_at: datetime
    end_at: datetime
    purpose: str = Field(default="", max_length=255)

    @model_validator(mode="after")
    def _check_period(self):
        if self.start_at.tzinfo is None or self.end_at.tzinfo is None:
            raise ValueError("Les dates doivent inclure un fuseau horaire (ISO 8601)")
        if self.end_at <= self.start_at:
            raise ValueError("end_at doit être postérieur à start_at")
        if (self.end_at - self.start_at).total_seconds() > 14 * 24 * 3600:
            raise ValueError("Une réservation ne peut pas dépasser 14 jours")
        return self


class ReservationOut(ORM):
    id: int
    resource_id: int
    user_id: int
    start_at: datetime
    end_at: datetime
    purpose: str
    status: ReservationStatus
    attachment_name: str | None
    created_at: datetime


class SlotOut(ORM):
    id: int
    start_at: datetime
    end_at: datetime
    status: ReservationStatus


# --- Exports ---------------------------------------------------------------
class ExportOut(ORM):
    id: int
    status: ExportStatus
    error: str | None
    created_at: datetime
    finished_at: datetime | None
