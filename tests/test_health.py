from app import main


def test_health_returns_ok(client):
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_health_does_not_depend_on_the_database(client, monkeypatch):
    # Liveness must stay green while the database is unreachable, otherwise a
    # transient outage would cause Kubernetes to restart healthy containers.
    async def unreachable():
        raise RuntimeError("database is down")

    monkeypatch.setattr(main, "check_schema", unreachable)

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_ready_returns_ready_when_the_database_is_reachable(client):
    # Runs against the real database, so this exercises check_schema properly:
    # it passes only because the users table exists and can be queried.
    response = client.get("/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


def test_ready_returns_503_when_the_database_is_unreachable(client, monkeypatch):
    async def unreachable():
        raise RuntimeError("database is down")

    monkeypatch.setattr(main, "check_schema", unreachable)

    response = client.get("/ready")

    assert response.status_code == 503
    assert response.json()["detail"] == "database not ready"


def test_ready_consults_the_schema_not_just_the_connection(client, monkeypatch):
    # A bare connection check passes against a database whose schema is
    # missing, so the app would report ready and then serve 500s. This pins the
    # decision: readiness goes through check_schema, which queries the model.
    called = []

    async def spy():
        called.append(True)

    monkeypatch.setattr(main, "check_schema", spy)

    response = client.get("/ready")

    assert response.status_code == 200
    assert called, "readiness did not consult the database schema"
