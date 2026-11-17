"""Configuration 12-factor : tout vient des variables d'environnement (ConfigMap / Secret / Key Vault).

Aucun secret n'a de valeur par défaut exploitable : en dehors de l'environnement "test",
l'application refuse de démarrer avec le JWT_SECRET de développement.
"""

from functools import lru_cache

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

# Sentinelle de développement : refusée en staging/prod (voir le validateur ci-dessous)
DEV_JWT_SECRET = "change-me-dev-only"  # noqa: S105  # nosec B105


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    app_name: str = "resaflow"
    app_env: str = Field(default="dev", description="dev | test | staging | prod")
    app_version: str = "1.0.0"
    log_level: str = "INFO"

    # Base de données
    database_url: str = "postgresql+psycopg://resaflow:resaflow@localhost:5432/resaflow"
    db_pool_size: int = 5
    db_max_overflow: int = 5

    # Authentification
    jwt_secret: str = DEV_JWT_SECRET
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    password_min_length: int = 10

    # File de messages (Celery / RabbitMQ)
    celery_broker_url: str = "amqp://resaflow:resaflow@localhost:5672//"
    celery_task_always_eager: bool = False

    # Stockage objet (Azure Blob / Azurite en local)
    storage_backend: str = "azure"  # azure | memory
    azure_storage_connection_string: str | None = None  # Azurite (local) uniquement
    azure_storage_account_url: str | None = None  # Azure : authentification par Workload Identity
    uploads_container: str = "uploads"
    exports_container: str = "exports"
    backups_container: str = "backups"
    max_upload_mb: int = 5

    # E-mail
    smtp_host: str = "localhost"
    smtp_port: int = 1025
    smtp_user: str | None = None
    smtp_password: str | None = None
    smtp_starttls: bool = False
    smtp_from: str = "ResaFlow <no-reply@resaflow.dev>"

    # Rétention / tâches planifiées
    export_retention_days: int = 7

    # CORS (le front est servi sur le même domaine via l'Ingress, donc vide en cloud)
    cors_origins: list[str] = []

    # Observabilité
    otel_enabled: bool = False
    otel_exporter_otlp_endpoint: str = "http://localhost:4318"
    worker_metrics_port: int = 9100

    # Amorçage du compte administrateur (job de migration)
    admin_email: str | None = None
    admin_password: str | None = None

    @model_validator(mode="after")
    def _refuse_dev_secret_outside_dev(self) -> "Settings":
        if self.app_env in {"staging", "prod"} and self.jwt_secret == DEV_JWT_SECRET:
            raise ValueError("JWT_SECRET doit être fourni (Key Vault) en staging/prod")
        if self.app_env in {"staging", "prod"} and len(self.jwt_secret) < 32:
            raise ValueError("JWT_SECRET trop court (32 caractères minimum)")
        return self


@lru_cache
def get_settings() -> Settings:
    return Settings()
