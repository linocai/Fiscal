from sqlalchemy import BigInteger, CheckConstraint, SmallInteger
from sqlalchemy.orm import Mapped, mapped_column

from fiscal_api.db.base import Base


class DataRevision(Base):
    """Singleton revision of user-visible formal Fiscal data."""

    __tablename__ = "data_revision"
    __table_args__ = (
        CheckConstraint("id = 1", name="singleton"),
        CheckConstraint("revision >= 0", name="nonnegative"),
    )

    id: Mapped[int] = mapped_column(SmallInteger, primary_key=True, default=1)
    revision: Mapped[int] = mapped_column(BigInteger, nullable=False, default=0)
