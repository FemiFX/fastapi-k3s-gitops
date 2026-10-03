import ormar
import sqlalchemy

from .config import settings


def _async_url(url: str) -> str:
    """Make sure the URL names an async driver.

    SQLAlchemy 2 chooses its driver from the URL scheme, and a bare
    postgresql:// means the synchronous psycopg2 driver, which an async engine
    cannot use. Everything that hands us a URL -- the Helm chart, docker
    compose, CI -- writes the plain form, so normalise it here rather than
    changing every one of them and hoping none is missed.
    """
    if url.startswith("postgresql+"):
        return url
    return url.replace("postgresql://", "postgresql+asyncpg://", 1)


base_ormar_config = ormar.OrmarConfig(
    database=ormar.DatabaseConnection(_async_url(settings.db_url)),
    metadata=sqlalchemy.MetaData(),
)


class User(ormar.Model):
    ormar_config = base_ormar_config.copy(tablename="users")

    id: int = ormar.Integer(primary_key=True)
    email: str = ormar.String(max_length=128, unique=True, nullable=False)
    active: bool = ormar.Boolean(default=True, nullable=False)


async def create_tables() -> None:
    """Create any missing tables.

    Still done at startup rather than by a migration tool. The consequences of
    that are real and deliberate: see the decision log. It now runs inside the
    application's lifespan instead of at import, which at least means it
    happens once, at a known point, rather than as a side effect of importing a
    module.
    """
    async with base_ormar_config.database.engine.begin() as connection:
        await connection.run_sync(base_ormar_config.metadata.create_all)


async def check_schema() -> None:
    """Prove the table the application serves is queryable.

    Used by the readiness probe. Going through the model rather than issuing a
    bare connection check is the point: a database that is reachable but
    missing its schema would pass a connection check and then serve errors.
    """
    await User.objects.count()
