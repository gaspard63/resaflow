from datetime import UTC, datetime, timedelta

from app.db import SessionLocal
from app.models import Export


def test_export_pdf_flow(client, user_headers, other_headers, resource):
    start = datetime(2030, 3, 1, 10, tzinfo=UTC)
    client.post(
        "/api/v1/reservations",
        headers=user_headers,
        json={
            "resource_id": resource["id"],
            "start_at": start.isoformat(),
            "end_at": (start + timedelta(hours=1)).isoformat(),
        },
    )
    r = client.post("/api/v1/exports", headers=user_headers)
    assert r.status_code == 202
    export_id = r.json()["id"]
    # eager : la tâche a déjà tourné
    status = client.get(f"/api/v1/exports/{export_id}", headers=user_headers).json()["status"]
    assert status == "done"
    dl = client.get(f"/api/v1/exports/{export_id}/download", headers=user_headers)
    assert dl.status_code == 200 and dl.content.startswith(b"%PDF")
    assert client.get(f"/api/v1/exports/{export_id}/download", headers=other_headers).status_code == 404
    assert len(client.get("/api/v1/exports", headers=user_headers).json()) == 1


def test_purge_old_exports(client, user_headers):
    from app.worker.tasks import purge_old_exports

    export_id = client.post("/api/v1/exports", headers=user_headers).json()["id"]
    with SessionLocal() as db:
        db.get(Export, export_id).created_at = datetime.now(UTC) - timedelta(days=30)
        db.commit()
    assert purge_old_exports() == 1
    assert client.get(f"/api/v1/exports/{export_id}", headers=user_headers).status_code == 404


def test_admin_endpoints(client, admin_headers, user_headers):
    assert client.get("/api/v1/admin/users", headers=user_headers).status_code == 403
    users = client.get("/api/v1/admin/users", headers=admin_headers).json()
    alice = next(u for u in users if u["email"] == "alice@example.com")
    r = client.patch(f"/api/v1/admin/users/{alice['id']}/role", headers=admin_headers, json={"role": "admin"})
    assert r.status_code == 200 and r.json()["role"] == "admin"
    me = next(u for u in users if u["email"] == "admin@example.com")
    assert (
        client.patch(f"/api/v1/admin/users/{me['id']}/role", headers=admin_headers, json={"role": "user"}).status_code
        == 400
    )
    stats = client.get("/api/v1/admin/stats", headers=admin_headers).json()
    assert stats["users"] == 2


def test_health_and_metrics(client, user_headers):
    assert client.get("/health/live").json()["status"] == "ok"
    assert client.get("/health/ready").json()["database"] == "up"
    client.post("/api/v1/auth/login", json={"email": "alice@example.com", "password": "bad"})
    metrics = client.get("/metrics").text
    assert "http_requests_total" in metrics
    assert 'resaflow_auth_attempts_total{outcome="failure"}' in metrics


def test_seed_is_idempotent(monkeypatch):
    from app import cli
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "admin_email", "root@example.com")
    monkeypatch.setattr(get_settings(), "admin_password", "un-mot-de-passe-long")
    cli.seed()
    cli.seed()
    from sqlalchemy import func, select

    from app.models import Resource, User

    with SessionLocal() as db:
        assert db.scalar(select(func.count(User.id))) == 1
        assert db.scalar(select(func.count(Resource.id))) == len(cli.DEMO_RESOURCES)
