"""Validation des fichiers téléversés : taille, type MIME déclaré ET contenu réel (magic bytes)."""

import io
import uuid

from fastapi import HTTPException, UploadFile, status
from PIL import Image, UnidentifiedImageError

from app.config import get_settings
from app.observability import UPLOAD_BYTES, UPLOADS

IMAGE_TYPES = {"image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WEBP"}
ATTACHMENT_TYPES = {"application/pdf", *IMAGE_TYPES}


def _too_large(kind: str) -> HTTPException:
    UPLOADS.labels(kind, "rejected").inc()
    return HTTPException(status.HTTP_413_CONTENT_TOO_LARGE, f"Fichier limité à {get_settings().max_upload_mb} Mo")


def _bad_type(kind: str, detail: str) -> HTTPException:
    UPLOADS.labels(kind, "rejected").inc()
    return HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail)


async def read_limited(file: UploadFile, kind: str) -> bytes:
    limit = get_settings().max_upload_mb * 1024 * 1024
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise _too_large(kind)
    if not data:
        raise _bad_type(kind, "Fichier vide")
    return data


def _check_image(data: bytes, declared: str, kind: str) -> None:
    try:
        with Image.open(io.BytesIO(data)) as img:
            img.verify()
            real = img.format
    except (UnidentifiedImageError, OSError) as exc:
        raise _bad_type(kind, "Image invalide ou corrompue") from exc
    if IMAGE_TYPES.get(declared) != real:
        raise _bad_type(kind, "Le contenu ne correspond pas au type déclaré")


async def validate_image(file: UploadFile) -> tuple[bytes, str]:
    if file.content_type not in IMAGE_TYPES:
        raise _bad_type("image", "Formats acceptés : JPEG, PNG, WebP")
    data = await read_limited(file, "image")
    _check_image(data, file.content_type, "image")
    UPLOADS.labels("image", "accepted").inc()
    UPLOAD_BYTES.observe(len(data))
    return data, file.content_type


async def validate_attachment(file: UploadFile) -> tuple[bytes, str]:
    if file.content_type not in ATTACHMENT_TYPES:
        raise _bad_type("attachment", "Formats acceptés : PDF, JPEG, PNG, WebP")
    data = await read_limited(file, "attachment")
    if file.content_type == "application/pdf":
        if not data.startswith(b"%PDF-"):
            raise _bad_type("attachment", "Le contenu n'est pas un PDF")
    else:
        _check_image(data, file.content_type, "attachment")
    UPLOADS.labels("attachment", "accepted").inc()
    UPLOAD_BYTES.observe(len(data))
    return data, file.content_type


def new_key(prefix: str) -> str:
    """Clé opaque : jamais le nom fourni par l'utilisateur (évite traversée de chemin et fuite d'info)."""
    return f"{prefix}/{uuid.uuid4().hex}"


def safe_filename(name: str | None) -> str:
    base = (name or "fichier").replace("\\", "/").rsplit("/", 1)[-1]
    cleaned = "".join(c for c in base if c.isalnum() or c in "._- ")[:120].strip()
    return cleaned or "fichier"
