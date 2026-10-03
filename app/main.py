import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from prometheus_fastapi_instrumentator import Instrumentator

from app.db import User, base_ormar_config, check_schema, create_tables


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Replaces @app.on_event("startup"/"shutdown"), which modern Starlette has
    # removed. A lifespan makes the ordering explicit: everything before the
    # yield runs before the first request is served, everything after runs on
    # shutdown, and the context manager guarantees the connection is closed
    # even if startup raises.
    async with base_ormar_config.database:
        await create_tables()
        await User.objects.get_or_create(email="test@test.com")
        yield


app = FastAPI(title="FastAPI, Docker, and Traefik", lifespan=lifespan)

# Probe failures are turned into an HTTP status for Kubernetes, which discards
# the reason. Without this the log shows a wall of 503s and nothing about what
# caused them, and the only way to find out is to reproduce the query by hand.
logger = logging.getLogger(__name__)

# Publishes request counts, durations and sizes at /metrics in the text format
# Prometheus scrapes. Adding it here rather than during the monitoring phase
# means the endpoint ships through the normal pipeline first, so setting up
# Prometheus later is purely infrastructure work.
#
# The probe endpoints are excluded: Kubernetes hits them every few seconds, and
# counting those would drown the real traffic in noise.
metrics = Instrumentator(excluded_handlers=["/health", "/ready", "/metrics"])
metrics.instrument(app)
metrics.expose(app, endpoint="/metrics", include_in_schema=False)


@app.get("/")
async def read_root():
    return await User.objects.all()


@app.get("/health")
async def health():
    # Liveness check: deliberately cheap and dependency-free. A 200 here only
    # proves the process and the asyncio event loop are responsive. This maps to
    # a Kubernetes livenessProbe -- so it must NOT touch the database, or a brief
    # DB outage would trigger needless container restarts.
    return {"status": "ok"}


@app.get("/ready")
async def ready():
    # Readiness check: verifies the app can actually serve real traffic, which
    # means both that PostgreSQL is reachable and that the schema it serves is
    # there. Maps to a Kubernetes readinessProbe -- on failure the pod is
    # removed from the load balancer but NOT restarted, so a transient DB blip
    # pauses traffic instead of restart-storming every replica.
    try:
        await check_schema()
    except Exception as exc:
        logger.warning("readiness check failed: %s", exc)
        raise HTTPException(status_code=503, detail="database not ready") from exc
    return {"status": "ready"}
