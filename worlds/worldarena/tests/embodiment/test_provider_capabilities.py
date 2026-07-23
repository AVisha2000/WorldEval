from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest
from genesis_arena.embodiment.providers import (
    ProviderCapabilities,
    provider_capabilities,
)


@pytest.mark.parametrize("name", ("openai", "anthropic", "gemini"))
def test_live_provider_capabilities_require_network_and_credentials(name: str) -> None:
    capabilities = provider_capabilities(name)
    assert capabilities == ProviderCapabilities(name, True, True)
    assert capabilities.as_dict() == {
        "provider_name": name,
        "requires_credential": True,
        "is_networked": True,
    }


@pytest.mark.parametrize("name", ("scripted", "demo"))
def test_local_provider_capabilities_are_credential_free_and_non_networked(name: str) -> None:
    capabilities = provider_capabilities(name)
    assert capabilities == ProviderCapabilities(name, False, False)
    with pytest.raises(FrozenInstanceError):
        capabilities.is_networked = True  # type: ignore[misc]


def test_capability_registry_fails_closed_for_unknown_or_untyped_names() -> None:
    with pytest.raises(ValueError, match="not registered"):
        provider_capabilities("unknown")
    with pytest.raises(TypeError, match="string"):
        provider_capabilities(None)  # type: ignore[arg-type]


@pytest.mark.parametrize("field", ("requires_credential", "is_networked"))
def test_capability_flags_are_strict_booleans(field: str) -> None:
    values = {
        "provider_name": "demo-local",
        "requires_credential": False,
        "is_networked": False,
    }
    values[field] = 0
    with pytest.raises(TypeError, match=field):
        ProviderCapabilities(**values)  # type: ignore[arg-type]
