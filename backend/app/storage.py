"""Stockage objet : Azure Blob Storage (Azurite en local).

En cloud, aucune clé n'est utilisée : le pod s'authentifie par Workload Identity
(DefaultAzureCredential) avec le rôle "Storage Blob Data Contributor" limité au compte.
En local, Azurite est joint par une chaîne de connexion de développement.
"""

import contextlib
import logging
import threading
from dataclasses import dataclass
from functools import lru_cache
from typing import Protocol

from app.config import get_settings

log = logging.getLogger(__name__)


class ObjectNotFoundError(Exception):
    pass


@dataclass
class StoredObject:
    data: bytes
    content_type: str


class Storage(Protocol):
    def put(self, container: str, key: str, data: bytes, content_type: str) -> None: ...
    def get(self, container: str, key: str) -> StoredObject: ...
    def delete(self, container: str, key: str) -> None: ...
    def ping(self) -> bool: ...


class InMemoryStorage:
    """Utilisé par les tests unitaires."""

    def __init__(self) -> None:
        self._objects: dict[tuple[str, str], StoredObject] = {}
        self._lock = threading.Lock()

    def put(self, container, key, data, content_type):
        with self._lock:
            self._objects[(container, key)] = StoredObject(data, content_type)

    def get(self, container, key):
        try:
            return self._objects[(container, key)]
        except KeyError as exc:
            raise ObjectNotFoundError(key) from exc

    def delete(self, container, key):
        with self._lock:
            self._objects.pop((container, key), None)

    def ping(self):
        return True


class AzureBlobStorage:
    def __init__(self) -> None:
        from azure.storage.blob import BlobServiceClient

        s = get_settings()
        if s.azure_storage_connection_string:
            self._client = BlobServiceClient.from_connection_string(s.azure_storage_connection_string)
        elif s.azure_storage_account_url:
            from azure.identity import DefaultAzureCredential

            self._client = BlobServiceClient(s.azure_storage_account_url, credential=DefaultAzureCredential())
        else:
            raise RuntimeError("AZURE_STORAGE_ACCOUNT_URL ou AZURE_STORAGE_CONNECTION_STRING requis")
        self._ensure_containers([s.uploads_container, s.exports_container, s.backups_container])

    def _ensure_containers(self, names: list[str]) -> None:
        from azure.core.exceptions import HttpResponseError, ResourceExistsError

        for name in names:
            try:
                self._client.create_container(name)
            except ResourceExistsError:
                pass
            except HttpResponseError as exc:  # en cloud les conteneurs sont créés par Terraform
                log.debug("container check skipped", extra={"container": name, "error": str(exc)})

    def put(self, container, key, data, content_type):
        from azure.storage.blob import ContentSettings

        self._client.get_blob_client(container, key).upload_blob(
            data, overwrite=True, content_settings=ContentSettings(content_type=content_type)
        )

    def get(self, container, key):
        from azure.core.exceptions import ResourceNotFoundError

        try:
            blob = self._client.get_blob_client(container, key).download_blob()
        except ResourceNotFoundError as exc:
            raise ObjectNotFoundError(key) from exc
        return StoredObject(blob.readall(), blob.properties.content_settings.content_type or "application/octet-stream")

    def delete(self, container, key):
        from azure.core.exceptions import ResourceNotFoundError

        with contextlib.suppress(ResourceNotFoundError):
            self._client.get_blob_client(container, key).delete_blob()

    def ping(self):
        s = get_settings()
        return self._client.get_container_client(s.uploads_container).exists()


@lru_cache
def get_storage() -> Storage:
    backend = get_settings().storage_backend
    if backend == "memory":
        return InMemoryStorage()
    return AzureBlobStorage()
