def test_metrics_endpoint_is_served(client):
    response = client.get("/metrics")

    assert response.status_code == 200
    # Prometheus scrapes a plain text format, not JSON.
    assert "text/plain" in response.headers["content-type"]


def test_metrics_report_request_counts(client):
    # Generate some traffic, then check it was counted.
    for _ in range(3):
        client.get("/")

    body = client.get("/metrics").text

    assert "http_requests_total" in body
    assert 'handler="/"' in body


def test_probe_traffic_is_excluded_from_metrics(client):
    # Kubernetes hits the probes every few seconds. Counting them would bury
    # real traffic, so they are deliberately left out.
    client.get("/health")
    client.get("/ready")

    body = client.get("/metrics").text

    assert 'handler="/health"' not in body
    assert 'handler="/ready"' not in body
