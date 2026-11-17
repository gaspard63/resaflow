from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from app.db import SessionLocal, engine
from app.models import Reservation

BASE = datetime(2030, 1, 15, 9, 0, tzinfo=UTC)


def _slot(resource_id, start_h, end_h, purpose="Réunion"):
    return {
        "resource_id": resource_id,
        "start_at": (BASE + timedelta(hours=start_h)).isoformat(),
        "end_at": (BASE + timedelta(hours=end_h)).isoformat(),
        "purpose": purpose,
    }


def test_create_reservation_sends_confirmation(client, user_headers, resource, sent_emails):
    r = client.post("/api/v1/reservations", headers=user_headers, json=_slot(resource["id"], 0, 2))
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "confirmed"
    assert len(sent_emails) == 1
    assert sent_emails[0]["to"] == "alice@example.com"
    assert "Salle Test" in sent_emails[0]["subject"]


def test_overlap_is_rejected_and_cancel_frees_slot(client, user_headers, other_headers, resource):
    rid = resource["id"]
    first = client.post("/api/v1/reservations", headers=user_headers, json=_slot(rid, 0, 2)).json()
    assert client.post("/api/v1/reservations", headers=other_headers, json=_slot(rid, 1, 3)).status_code == 409
    # créneaux adjacents autorisés
    assert client.post("/api/v1/reservations", headers=other_headers, json=_slot(rid, 2, 3)).status_code == 201
    assert client.post(f"/api/v1/reservations/{first['id']}/cancel", headers=user_headers).status_code == 200
    assert client.post("/api/v1/reservations", headers=other_headers, json=_slot(rid, 0, 1)).status_code == 201


def test_invalid_periods(client, user_headers, resource):
    rid = resource["id"]
    assert client.post("/api/v1/reservations", headers=user_headers, json=_slot(rid, 2, 1)).status_code == 422
    naive = {"resource_id": rid, "start_at": "2030-01-01T10:00:00", "end_at": "2030-01-01T11:00:00"}
    assert client.post("/api/v1/reservations", headers=user_headers, json=naive).status_code == 422
    assert client.post("/api/v1/reservations", headers=user_headers, json=_slot(rid, 0, 24 * 15)).status_code == 422
    assert client.post("/api/v1/reservations", headers=user_headers, json=_slot(999, 0, 1)).status_code == 404


def test_users_only_see_their_reservations(client, user_headers, other_headers, admin_headers, resource):
    mine = client.post("/api/v1/reservations", headers=user_headers, json=_slot(resource["id"], 0, 1)).json()
    assert client.get(f"/api/v1/reservations/{mine['id']}", headers=other_headers).status_code == 404
    assert client.post(f"/api/v1/reservations/{mine['id']}/cancel", headers=other_headers).status_code == 404
    assert client.get("/api/v1/reservations", headers=other_headers).json() == []
    assert len(client.get("/api/v1/reservations?all=true", headers=admin_headers).json()) == 1
    assert client.get("/api/v1/reservations?all=true", headers=other_headers).json() == []


def test_slots_endpoint(client, user_headers, resource):
    rid = resource["id"]
    client.post("/api/v1/reservations", headers=user_headers, json=_slot(rid, 0, 1))
    params = {"start": BASE.isoformat(), "end": (BASE + timedelta(days=1)).isoformat()}
    slots = client.get(f"/api/v1/resources/{rid}/slots", headers=user_headers, params=params).json()
    assert len(slots) == 1


def test_attachment_upload_download(client, user_headers, other_headers, resource):
    res = client.post("/api/v1/reservations", headers=user_headers, json=_slot(resource["id"], 0, 1)).json()
    url = f"/api/v1/reservations/{res['id']}/attachment"
    assert client.get(url, headers=user_headers).status_code == 404
    pdf = b"%PDF-1.4\n%fake test pdf\n"
    r = client.post(url, headers=user_headers, files={"file": ("../../ordre du jour.pdf", pdf, "application/pdf")})
    assert r.status_code == 200 and r.json()["attachment_name"] == "ordre du jour.pdf"
    dl = client.get(url, headers=user_headers)
    assert dl.status_code == 200 and dl.content == pdf
    assert client.get(url, headers=other_headers).status_code == 404
    bad = client.post(url, headers=user_headers, files={"file": ("x.pdf", b"MZ\x90\x00", "application/pdf")})
    assert bad.status_code == 415


def test_daily_reminders(client, user_headers, resource, sent_emails):
    from app.worker.tasks import send_daily_reminders

    soon = datetime.now(UTC) + timedelta(hours=3)
    body = {
        "resource_id": resource["id"],
        "start_at": soon.isoformat(),
        "end_at": (soon + timedelta(hours=1)).isoformat(),
    }
    assert client.post("/api/v1/reservations", headers=user_headers, json=body).status_code == 201
    assert send_daily_reminders() == 1
    assert send_daily_reminders() == 0  # pas de doublon
    assert any("Rappel" in m["subject"] for m in sent_emails)


def test_db_exclusion_constraint_blocks_concurrent_overlap(client, user_headers, resource):
    """Simule deux requêtes concurrentes ayant toutes deux passé la vérification applicative."""
    if engine.dialect.name != "postgresql":
        pytest.skip("contrainte d'exclusion propre à PostgreSQL (exécuté en CI)")
    client.post("/api/v1/reservations", headers=user_headers, json=_slot(resource["id"], 0, 2))
    with SessionLocal() as db:
        user_id = db.scalar(select(Reservation.user_id))
        db.add(
            Reservation(
                resource_id=resource["id"],
                user_id=user_id,
                start_at=BASE + timedelta(hours=1),
                end_at=BASE + timedelta(hours=3),
            )
        )
        with pytest.raises(IntegrityError):
            db.commit()
