from datetime import datetime

import pytest
from pydantic import ValidationError

from fiscal_api.api.p21_schemas import CheckpointCreate


def test_p21_checkpoint_requires_an_aware_as_of() -> None:
    with pytest.raises(ValidationError):
        CheckpointCreate(
            target_kind="account",
            account_id="00000000-0000-0000-0000-000000000001",
            as_of=datetime(2026, 8, 11),
            actual_balance_minor=1,
        )
