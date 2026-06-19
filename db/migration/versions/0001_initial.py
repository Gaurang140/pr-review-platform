"""initial

Revision ID: 0001
Revises:
Create Date: 2026-05-01 12:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = '0001'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute('CREATE EXTENSION IF NOT EXISTS "pgcrypto"')

    op.create_table(
        'pull_requests',
        sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
        sa.Column('repo_full_name', sa.Text(), nullable=False),
        sa.Column('pr_number', sa.Integer(), nullable=False),
        sa.Column('head_sha', sa.Text(), nullable=False),
        sa.Column('installation_id', sa.BigInteger(), nullable=False),
        sa.Column('status', sa.Text(), nullable=False, server_default='pending'),
        sa.Column('created_at', sa.TIMESTAMP(timezone=True), nullable=False,
                  server_default=sa.text('now()')),
        sa.PrimaryKeyConstraint('id'),
    )

    op.create_table(
        'findings',
        sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
        sa.Column('pr_id', sa.UUID(), nullable=True),
        sa.Column('file_path', sa.Text(), nullable=True),
        sa.Column('line_number', sa.Integer(), nullable=True),
        sa.Column('message', sa.Text(), nullable=True),
        sa.Column('severity', sa.Text(), nullable=True),
        sa.Column('agent', sa.Text(), nullable=True),
        sa.Column('created_at', sa.TIMESTAMP(timezone=True), nullable=True,
                  server_default=sa.text('now()')),
        sa.ForeignKeyConstraint(['pr_id'], ['pull_requests.id']),
        sa.PrimaryKeyConstraint('id'),
    )

    op.create_table(
        'patterns',
        sa.Column('id', sa.UUID(), server_default=sa.text('gen_random_uuid()'), nullable=False),
        sa.Column('repo_full_name', sa.Text(), nullable=False),
        sa.Column('pattern_text', sa.Text(), nullable=False),
        sa.Column('frequency', sa.Integer(), nullable=True, server_default='1'),
        sa.Column('updated_at', sa.TIMESTAMP(timezone=True), nullable=True,
                  server_default=sa.text('now()')),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('repo_full_name', 'pattern_text'),
    )


def downgrade() -> None:
    op.drop_table('findings')
    op.drop_table('patterns')
    op.drop_table('pull_requests')
