"""Conexion a la base de datos, incluida la espera a Cloud SQL mientras arranca o se reinicia."""

import logging
import time

from sqlalchemy import create_engine, event, text
from sqlalchemy.engine import Engine
from sqlalchemy.exc import DBAPIError

from ledger.models import Base

logger = logging.getLogger(__name__)


def build_engine(database_url: str) -> Engine:
    if database_url.startswith("sqlite"):
        engine = create_engine(database_url, connect_args={"timeout": 30})

        @event.listens_for(engine, "connect")
        def _enable_sqlite_constraints(connection, _record):
            connection.execute("PRAGMA foreign_keys=ON")

        return engine
    # pool_pre_ping detecta conexiones cortadas por un reinicio o mantenimiento de Cloud SQL.
    return create_engine(database_url, pool_pre_ping=True, pool_recycle=1800, pool_size=3)


def wait_for_database(engine: Engine, attempts: int = 10, delay_seconds: float = 6.0) -> None:
    """La primera conexion puede fallar si la instancia de Cloud SQL se esta reiniciando."""
    for attempt in range(1, attempts + 1):
        try:
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
            return
        except DBAPIError:
            if attempt == attempts:
                raise
            logger.warning("Base de datos no disponible, intento %s de %s", attempt, attempts)
            time.sleep(delay_seconds)


def init_schema(engine: Engine) -> None:
    wait_for_database(engine)
    Base.metadata.create_all(engine)
