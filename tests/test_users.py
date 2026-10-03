def test_root_returns_a_list_of_users(client):
    response = client.get("/")

    assert response.status_code == 200
    assert isinstance(response.json(), list)


def test_root_contains_the_seeded_user(client):
    # The startup event creates this row via get_or_create.
    emails = [user["email"] for user in client.get("/").json()]

    assert "test@test.com" in emails


def test_users_expose_the_expected_fields(client):
    users = client.get("/").json()

    assert users, "expected at least the seeded user"
    assert set(users[0]) >= {"id", "email", "active"}
