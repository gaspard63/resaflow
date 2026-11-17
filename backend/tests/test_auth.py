import jwt


def test_register_login_me(client):
    r = client.post(
        "/api/v1/auth/register",
        json={"email": "Carol@Example.com", "full_name": "Carol", "password": "un-mot-de-passe-long"},
    )
    assert r.status_code == 201
    assert r.json()["email"] == "carol@example.com"
    assert r.json()["role"] == "user"
    assert "hashed_password" not in r.json()

    r = client.post("/api/v1/auth/login", json={"email": "carol@example.com", "password": "un-mot-de-passe-long"})
    assert r.status_code == 200
    token = r.json()["access_token"]
    r = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200 and r.json()["full_name"] == "Carol"


def test_register_duplicate_and_weak_password(client):
    body = {"email": "dup@example.com", "full_name": "Dup", "password": "un-mot-de-passe-long"}
    assert client.post("/api/v1/auth/register", json=body).status_code == 201
    assert client.post("/api/v1/auth/register", json=body).status_code == 409
    weak = {**body, "email": "weak@example.com", "password": "court"}
    assert client.post("/api/v1/auth/register", json=weak).status_code == 422


def test_login_failure_is_generic(client, user_headers):
    wrong_pwd = client.post("/api/v1/auth/login", json={"email": "alice@example.com", "password": "nope"})
    unknown = client.post("/api/v1/auth/login", json={"email": "ghost@example.com", "password": "nope"})
    assert wrong_pwd.status_code == unknown.status_code == 401
    assert wrong_pwd.json() == unknown.json()  # pas d'énumération des comptes


def test_login_accepts_reserved_domain_accounts(client):
    """Régression : un compte amorcé sur un domaine réservé (.local) doit pouvoir se connecter."""
    from tests.conftest import _make_user

    _make_user("ops@resaflow.local")
    r = client.post("/api/v1/auth/login", json={"email": "ops@resaflow.local", "password": "motdepasse-solide"})
    assert r.status_code == 200
    me = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {r.json()['access_token']}"})
    assert me.status_code == 200 and me.json()["email"] == "ops@resaflow.local"
    assert client.post("/api/v1/auth/login", json={"email": "pas-un-email", "password": "x"}).status_code == 422


def test_protected_routes_require_token(client):
    assert client.get("/api/v1/resources").status_code == 401
    assert client.get("/api/v1/auth/me", headers={"Authorization": "Bearer abc.def.ghi"}).status_code == 401


def test_expired_or_forged_token_rejected(client, user_headers):
    forged = jwt.encode({"sub": "1", "iss": "resaflow", "exp": 9999999999}, "wrong-secret", algorithm="HS256")
    assert client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {forged}"}).status_code == 401
    expired = jwt.encode(
        {"sub": "1", "iss": "resaflow", "exp": 1}, "test-secret-with-enough-length-0123456789", algorithm="HS256"
    )
    assert client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {expired}"}).status_code == 401


def test_security_headers(client):
    r = client.get("/health/live")
    assert r.headers["x-content-type-options"] == "nosniff"
    assert r.headers["x-frame-options"] == "DENY"
