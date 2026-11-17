import gzip
import os

import pytest

from app.cli import upload_backup
from app.storage import get_storage


def test_upload_backup(tmp_path):
    dump = tmp_path / "dump.sql.gz"
    dump.write_bytes(gzip.compress(b"-- PostgreSQL database dump\n" + os.urandom(512)))
    key = upload_backup(str(dump))
    assert key.startswith("test/resaflow-") and key.endswith(".sql.gz")
    assert get_storage().get("backups", key).data == dump.read_bytes()


def test_upload_backup_refuses_empty_dump(tmp_path):
    dump = tmp_path / "empty.sql.gz"
    dump.write_bytes(b"")
    with pytest.raises(SystemExit):
        upload_backup(str(dump))
