from tests.conftest import png_bytes


def test_user_cannot_create_resource(client, user_headers):
    r = client.post("/api/v1/resources", headers=user_headers, json={"name": "X", "type": "room"})
    assert r.status_code in (403, 422)
    r = client.post("/api/v1/resources", headers=user_headers, json={"name": "Salle X", "type": "room"})
    assert r.status_code == 403


def test_admin_crud_resource(client, admin_headers, user_headers, resource):
    rid = resource["id"]
    assert client.get("/api/v1/resources", headers=user_headers).json()[0]["name"] == "Salle Test"
    assert client.get("/api/v1/resources?type=equipment", headers=user_headers).json() == []
    assert client.get("/api/v1/resources?q=test", headers=user_headers).json()[0]["id"] == rid

    r = client.patch(f"/api/v1/resources/{rid}", headers=admin_headers, json={"capacity": 20})
    assert r.status_code == 200 and r.json()["capacity"] == 20

    dup = client.post("/api/v1/resources", headers=admin_headers, json={"name": "Salle Test", "type": "room"})
    assert dup.status_code == 409

    assert client.delete(f"/api/v1/resources/{rid}", headers=admin_headers).status_code == 204
    assert client.get("/api/v1/resources", headers=user_headers).json() == []
    assert client.get(f"/api/v1/resources/{rid}", headers=user_headers).json()["is_active"] is False
    assert client.get("/api/v1/resources/9999", headers=user_headers).status_code == 404


def test_image_upload_triggers_thumbnail(client, admin_headers, user_headers, resource):
    rid = resource["id"]
    r = client.post(
        f"/api/v1/resources/{rid}/image", headers=admin_headers, files={"file": ("photo.png", png_bytes(), "image/png")}
    )
    assert r.status_code == 200, r.text
    # Celery en mode eager : la miniature est générée par la tâche
    body = client.get(f"/api/v1/resources/{rid}", headers=user_headers).json()
    assert body["has_image"] and body["has_thumbnail"]
    thumb = client.get(f"/api/v1/resources/{rid}/image?thumbnail=true", headers=user_headers)
    assert thumb.status_code == 200 and thumb.headers["content-type"] == "image/webp"
    assert len(thumb.content) < len(png_bytes())
    full = client.get(f"/api/v1/resources/{rid}/image", headers=user_headers)
    assert full.headers["content-type"] == "image/png"


def test_image_upload_rejects_bad_files(client, admin_headers, resource):
    rid = resource["id"]
    url = f"/api/v1/resources/{rid}/image"
    fake = client.post(url, headers=admin_headers, files={"file": ("x.png", b"not an image", "image/png")})
    assert fake.status_code == 415
    wrong_type = client.post(url, headers=admin_headers, files={"file": ("x.gif", b"GIF89a", "image/gif")})
    assert wrong_type.status_code == 415
    big = client.post(url, headers=admin_headers, files={"file": ("x.png", b"0" * (6 * 1024 * 1024), "image/png")})
    assert big.status_code == 413
    assert client.get(f"/api/v1/resources/{rid}/image", headers=admin_headers).status_code == 404
