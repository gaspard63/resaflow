"""Schéma initial : users, resources, reservations, exports

Revision ID: 0001
Revises:
Create Date: 2026-10-13
"""
import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

role = sa.Enum("user", "admin", name="role")
resource_type = sa.Enum("room", "equipment", name="resource_type")
reservation_status = sa.Enum("confirmed", "cancelled", name="reservation_status")
export_status = sa.Enum("pending", "running", "done", "failed", name="export_status")


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("email", sa.String(255), nullable=False),
        sa.Column("full_name", sa.String(120), nullable=False),
        sa.Column("hashed_password", sa.String(255), nullable=False),
        sa.Column("role", role, nullable=False, server_default="user"),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
    )
    op.create_index("ix_users_email", "users", ["email"], unique=True)

    op.create_table(
        "resources",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("name", sa.String(120), nullable=False, unique=True),
        sa.Column("type", resource_type, nullable=False),
        sa.Column("description", sa.Text, nullable=False, server_default=""),
        sa.Column("location", sa.String(120), nullable=False, server_default=""),
        sa.Column("capacity", sa.Integer, nullable=False, server_default="1"),
        sa.Column("image_key", sa.String(255)),
        sa.Column("thumbnail_key", sa.String(255)),
        sa.Column("is_active", sa.Boolean, nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.CheckConstraint("capacity >= 1", name="ck_resource_capacity"),
    )

    op.create_table(
        "reservations",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("resource_id", sa.Integer, sa.ForeignKey("resources.id", ondelete="CASCADE"), nullable=False),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("start_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("end_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("purpose", sa.String(255), nullable=False, server_default=""),
        sa.Column("status", reservation_status, nullable=False, server_default="confirmed"),
        sa.Column("attachment_key", sa.String(255)),
        sa.Column("attachment_name", sa.String(255)),
        sa.Column("reminder_sent", sa.Boolean, nullable=False, server_default=sa.false()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.CheckConstraint("end_at > start_at", name="ck_reservation_period"),
    )
    op.create_index("ix_reservation_resource_period", "reservations", ["resource_id", "start_at", "end_at"])

    if op.get_bind().dialect.name == "postgresql":
        # Interdit au niveau base deux réservations confirmées qui se chevauchent sur la même ressource,
        # même en cas de requêtes concurrentes sur plusieurs réplicas de l'API.
        op.execute("CREATE EXTENSION IF NOT EXISTS btree_gist")
        op.execute(
            "ALTER TABLE reservations ADD CONSTRAINT ex_reservation_no_overlap "
            "EXCLUDE USING gist (resource_id WITH =, tstzrange(start_at, end_at) WITH &&) "
            "WHERE (status = 'confirmed')"
        )

    op.create_table(
        "exports",
        sa.Column("id", sa.Integer, primary_key=True),
        sa.Column("user_id", sa.Integer, sa.ForeignKey("users.id", ondelete="CASCADE"), nullable=False),
        sa.Column("status", export_status, nullable=False, server_default="pending"),
        sa.Column("blob_key", sa.String(255)),
        sa.Column("error", sa.Text),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False, server_default=sa.func.now()),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
    )
    op.create_index("ix_exports_user_id", "exports", ["user_id"])


def downgrade() -> None:
    op.drop_table("exports")
    op.drop_table("reservations")
    op.drop_table("resources")
    op.drop_table("users")
    for enum in (export_status, reservation_status, resource_type, role):
        enum.drop(op.get_bind(), checkfirst=True)
