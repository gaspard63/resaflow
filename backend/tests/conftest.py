"""Fixtures de test.

Par défaut : SQLite + stockage mémoire + Celery en mode eager (rapide, sans dépendance).
En CI : TEST_DATABASE_URL pointe vers un PostgreSQL de service et le schéma est créé par
Alembic, ce qui teste aussi les migrations et la contrainte d'exclusion anti-chevauchement.
"""

import os
import tempfile

_TEST_DB = os.environ.get("TEST_DATABASE_URL")
_tmpdir = tempfile.mkdtemp()
os.environ.update(
    {
        "APP_ENV": "test",
        "DATABASE_URL": _TEST_DB or f"sqlite:///{_tmpdir}/test.db",
        "STORAGE_BACKEND": "memory",
        "CELERY_TASK_ALWAYS_EAGER": "true",
        "CELERY_BROKER_URL": "memory://",
        "JWT_SECRET": "test-secret-with-enough-length-0123456789",
    }
)

import io  # noqa: E402

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from PIL import Image  # noqa: E402

from app.db import Base, SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import Role, User  # noqa: E402
from app.security import hash_password  # noqa: E402


@pytest.fixture(autouse=True)
def _db():
    if _TEST_DB:
        from alembic import command
        from alembic.config import Config

        cfg = Config(os.path.join(os.path.dirname(__file__), "..", "alembic.ini"))
        cfg.set_main_option("script_location", os.path.join(os.path.dirname(__file__), "..", "alembic"))
        command.upgrade(cfg, "head")
        yield
        command.downgrade(cfg, "base")
    else:
        Base.metadata.create_all(engine)
        yield
        Base.metadata.drop_all(engine)


@pytest.fixture
def sent_emails(monkeypatch):
    outbox: list[dict] = []

    def fake_send(to, subject, body, attachment=None):
        outbox.append({"to": to, "subject": subject, "body": body})

    monkeypatch.setattr("app.worker.tasks.send_email", fake_send)
    return outbox


@pytest.fixture
def client(sent_emails):
    with TestClient(app) as c:
        yield c


def _make_user(email: str, role: Role = Role.user) -> User:
    with SessionLocal() as db:
        user = User(
            email=email, full_name=email.split("@")[0], hashed_password=hash_password("motdepasse-solide"), role=role
        )
        db.add(user)
        db.commit()
        return user


def _auth(client: TestClient, email: str) -> dict:
    r = client.post("/api/v1/auth/login", json={"email": email, "password": "motdepasse-solide"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['access_token']}"}


@pytest.fixture
def user_headers(client):
    _make_user("alice@example.com")
    return _auth(client, "alice@example.com")


@pytest.fixture
def other_headers(client):
    _make_user("bob@example.com")
    return _auth(client, "bob@example.com")


@pytest.fixture
def admin_headers(client):
    _make_user("admin@example.com", Role.admin)
    return _auth(client, "admin@example.com")


@pytest.fixture
def resource(client, admin_headers):
    r = client.post(
        "/api/v1/resources",
        headers=admin_headers,
        json={"name": "Salle Test", "type": "room", "location": "A1", "capacity": 8},
    )
    assert r.status_code == 201, r.text
    return r.json()


def png_bytes(size=(800, 600)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, (30, 120, 200)).save(buf, format="PNG")
    return buf.getvalue()
