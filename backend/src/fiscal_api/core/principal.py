from dataclasses import dataclass
from uuid import UUID


@dataclass(frozen=True)
class AuthenticatedPrincipal:
    """The holder of a current-generation personal access key."""

    id: UUID
    label: str
    credential_generation: int
