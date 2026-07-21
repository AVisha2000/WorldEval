"""Credential-free ProviderAdapter for the canonical visible-state duel baseline."""

from __future__ import annotations

from ..baselines import BASELINE_TIERS, BaselineLock, baseline_intent, decide_baseline
from ..contracts import ControllerAction
from ..protocol import canonical_json_bytes, strict_json_loads
from ..providers.contracts import ProviderCallResult, ProviderRequest, ProviderTelemetry


class ScriptedBaselineAdapter:
    provider_name = "scripted"

    def __init__(self, tier: str) -> None:
        if tier not in BASELINE_TIERS:
            raise ValueError("unsupported scripted baseline tier")
        self._lock = BaselineLock(tier)  # type: ignore[arg-type]

    @property
    def lock(self) -> BaselineLock:
        return self._lock

    async def request(self, request: ProviderRequest) -> ProviderCallResult:
        if not isinstance(request, ProviderRequest):
            raise TypeError("request must be ProviderRequest")
        if request.model != self._lock.tier:
            raise ValueError("request model does not match the scripted baseline tier")
        observation = strict_json_loads(request.observation_json)
        if not isinstance(observation, dict):
            raise ValueError("baseline observation must be an object")
        control = decide_baseline(self._lock, observation)
        action = ControllerAction(
            episode_id=request.episode_id,
            observation_seq=request.observation_seq,
            action_id=f"baseline_{self._lock.tier[:-3]}_{request.observation_seq:06d}",
            control=control,
            intent_label=baseline_intent(control),
            memory_update="",
        )
        return ProviderCallResult.success(
            canonical_json_bytes(action.as_dict()), ProviderTelemetry(latency_ms=0)
        )

    async def aclose(self) -> None:
        return None


__all__ = ["ScriptedBaselineAdapter"]
