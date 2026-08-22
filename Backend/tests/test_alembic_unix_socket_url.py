from alembic.config import Config

from fiscal_api.core.config import escape_alembic_config_url


def test_unix_socket_url_round_trips_through_alembic_config() -> None:
    database_url = "postgresql+asyncpg://fiscal_migrator@/fiscal?host=%2Fvar%2Frun%2Fpostgresql"
    config = Config()

    config.set_main_option("sqlalchemy.url", escape_alembic_config_url(database_url))

    assert config.get_main_option("sqlalchemy.url") == database_url
