import pytest
from fastapi.testclient import TestClient

from app.main import app


@pytest.fixture(scope="module")
def client():
    # Using TestClient as a context manager triggers the app's startup and
    # shutdown events, so the database connection is opened and the seed row
    # is created exactly as it would be at runtime.
    with TestClient(app) as test_client:
        yield test_client
