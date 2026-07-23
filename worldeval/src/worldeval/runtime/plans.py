"""Interruptible plan leases and explicit decision-response handling."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from jsonschema import Draft202012Validator
from pydantic import ValidationError

from worldeval.contracts.models import (
    AbortResponse,
    ActionCall,
    ActionCatalog,
    ActionPlan,
    ActionReceipt,
    ActivePlanSummary,
    ContinueResponse,
    DecisionProfile,
    ReplaceResponse,
    SourceObservation,
    WaitResponse,
    parse_decision_response,
)


class ActionAuthorityError(ValueError):
    """An action is unknown, malformed, or delegates forbidden authority."""


@dataclass(frozen=True)
class ObservationSource:
    observation_seq: int
    tick: int
    state_hash: str

    def as_model(self) -> SourceObservation:
        return SourceObservation(
            observation_seq=self.observation_seq,
            tick=self.tick,
            state_hash=self.state_hash,
        )


@dataclass(frozen=True)
class Authorization:
    plan_id: str
    step_id: str
    action: ActionCall
    lease_ticks: int


@dataclass(frozen=True)
class DecisionOutcome:
    receipt: ActionReceipt
    authorization: Authorization | None = None
    wait_ticks: int = 0


@dataclass
class _PlanState:
    plan: ActionPlan
    step_index: int = 0
    status: str = "active"
    authorized_ticks: int = 0
    interrupt_events: tuple[str, ...] = ()


class ActionAuthorityGuard:
    def __init__(self, catalog: ActionCatalog) -> None:
        self.catalog = catalog
        self._definitions = {item.action_id: item for item in catalog.actions}

    def validate(self, call: ActionCall) -> None:
        definition = self._definitions.get(call.action)
        if definition is None:
            raise ActionAuthorityError(f"unknown action: {call.action}")
        errors = sorted(
            Draft202012Validator(definition.argument_schema).iter_errors(call.arguments),
            key=lambda error: list(error.absolute_path),
        )
        if errors:
            raise ActionAuthorityError(f"invalid {call.action} arguments: {errors[0].message}")
        if call.action == "move_to":
            if call.arguments.get("navigation") != "direct_only":
                raise ActionAuthorityError("move_to requires navigation=direct_only")
            if definition.authority.navigation != "direct_only":
                raise ActionAuthorityError("the selected profile delegates pathfinding")
            if "choose_detour" not in definition.authority.game_must_not:
                raise ActionAuthorityError("move_to does not forbid game-selected detours")


class PlanCoordinator:
    """Authorizes at most one step and one bounded lease at a time."""

    def __init__(self, profile: DecisionProfile, catalog: ActionCatalog) -> None:
        self.profile = profile
        self.guard = ActionAuthorityGuard(catalog)
        self._state: _PlanState | None = None
        self._receipt_seq = 0

    @property
    def active_plan_id(self) -> str | None:
        return self._state.plan.plan_id if self._state else None

    @property
    def active_summary(self) -> ActivePlanSummary | None:
        if self._state is None:
            return None
        step_id = None
        if self._state.step_index < len(self._state.plan.steps):
            step_id = self._state.plan.steps[self._state.step_index].step_id
        return ActivePlanSummary(
            plan_id=self._state.plan.plan_id,
            step_id=step_id,
            status=self._state.status,
        )

    @property
    def interrupt_events(self) -> list[str]:
        return list(self._state.interrupt_events) if self._state else []

    def handle(
        self,
        response: Any,
        source: ObservationSource,
        *,
        missing_reason: str = "missing",
    ) -> DecisionOutcome:
        if response is None:
            if missing_reason not in {"missing", "invalid", "timeout"}:
                missing_reason = "invalid"
            return DecisionOutcome(self._neutral_receipt(source, missing_reason))
        try:
            parsed = parse_decision_response(response)
        except (ValidationError, ValueError, TypeError):
            return DecisionOutcome(self._neutral_receipt(source, "invalid"))

        response_source = (
            parsed.plan.source if isinstance(parsed, ReplaceResponse) else parsed.source
        )
        stale_reason = self._stale_reason(response_source, source)
        if stale_reason:
            return DecisionOutcome(
                self._neutral_receipt(source, stale_reason, response_type=parsed.type)
            )

        if isinstance(parsed, ReplaceResponse):
            return self._replace(parsed, source)
        if isinstance(parsed, ContinueResponse):
            return self._continue(parsed, source)
        if isinstance(parsed, AbortResponse):
            return self._abort(parsed, source)
        if isinstance(parsed, WaitResponse):
            return self._wait(parsed, source)
        return DecisionOutcome(self._neutral_receipt(source, "invalid"))

    def interrupt(self, event: str, *, revoke: bool = False) -> None:
        if self._state is None:
            return
        self._state.status = "revoked" if revoke else "suspended"
        self._state.authorized_ticks = 0
        self._state.interrupt_events = tuple(sorted(set(self._state.interrupt_events + (event,))))

    def record_boundary(self, *, completed: bool, lease_expired: bool, events: list[str]) -> None:
        if self._state is None:
            return
        material = [event for event in events if event in self.profile.interrupt_events]
        if material:
            revoke = any(
                event in {"hostile_near_target", "target_disappeared", "objective_revised"}
                for event in material
            )
            self.interrupt(material[0], revoke=revoke)
            for event in material[1:]:
                self.interrupt(event, revoke=revoke)
            return
        if completed:
            self._state.step_index += 1
            self._state.authorized_ticks = 0
            self._state.status = "awaiting_confirmation"
        elif lease_expired:
            self._state.authorized_ticks = 0
            self._state.status = "awaiting_confirmation"

    def _replace(self, response: ReplaceResponse, source: ObservationSource) -> DecisionOutcome:
        if self._state:
            if response.replaces_plan_id != self._state.plan.plan_id:
                return DecisionOutcome(
                    self._rejected_receipt(source, response.type, "replacement_plan_mismatch")
                )
        elif response.replaces_plan_id is not None:
            return DecisionOutcome(
                self._rejected_receipt(source, response.type, "no_plan_to_replace")
            )
        try:
            self._validate_plan(response.plan)
        except ActionAuthorityError as exc:
            return DecisionOutcome(
                self._rejected_receipt(source, response.type, "invalid_plan", detail=str(exc))
            )
        self._state = _PlanState(plan=response.plan, authorized_ticks=response.plan.lease_ticks)
        authorization = self._authorization(response.plan.lease_ticks)
        return DecisionOutcome(
            self._accepted_receipt(
                source,
                response.type,
                response.plan.plan_id,
                authorization.step_id,
            ),
            authorization=authorization,
        )

    def _continue(self, response: ContinueResponse, source: ObservationSource) -> DecisionOutcome:
        if self._state is None or response.plan_id != self._state.plan.plan_id:
            return DecisionOutcome(self._rejected_receipt(source, response.type, "unknown_plan"))
        if self._state.status == "revoked":
            return DecisionOutcome(self._rejected_receipt(source, response.type, "plan_revoked"))
        if self._state.step_index >= len(self._state.plan.steps):
            return DecisionOutcome(self._rejected_receipt(source, response.type, "plan_complete"))
        try:
            self._validate_lease(response.lease_ticks)
            step = self._state.plan.steps[self._state.step_index]
            self.guard.validate(step.action)
        except ActionAuthorityError as exc:
            return DecisionOutcome(
                self._rejected_receipt(
                    source,
                    response.type,
                    "invalid_continuation",
                    detail=str(exc),
                )
            )
        self._state.status = "active"
        self._state.authorized_ticks = response.lease_ticks
        self._state.interrupt_events = ()
        authorization = self._authorization(response.lease_ticks)
        return DecisionOutcome(
            self._accepted_receipt(source, response.type, response.plan_id, authorization.step_id),
            authorization=authorization,
        )

    def _abort(self, response: AbortResponse, source: ObservationSource) -> DecisionOutcome:
        if self._state is None or response.plan_id != self._state.plan.plan_id:
            return DecisionOutcome(self._rejected_receipt(source, response.type, "unknown_plan"))
        plan_id = self._state.plan.plan_id
        step_id = self.active_summary.step_id if self.active_summary else None
        self._state = None
        return DecisionOutcome(self._accepted_receipt(source, response.type, plan_id, step_id))

    def _wait(self, response: WaitResponse, source: ObservationSource) -> DecisionOutcome:
        try:
            self._validate_lease(response.maximum_ticks)
        except ActionAuthorityError as exc:
            return DecisionOutcome(
                self._rejected_receipt(source, response.type, "invalid_wait", detail=str(exc))
            )
        return DecisionOutcome(
            self._accepted_receipt(source, response.type, self.active_plan_id, None),
            wait_ticks=response.maximum_ticks,
        )

    def _validate_plan(self, plan: ActionPlan) -> None:
        self._validate_lease(plan.lease_ticks)
        for step in plan.steps:
            self.guard.validate(step.action)

    def _validate_lease(self, ticks: int) -> None:
        if not self.profile.minimum_ticks <= ticks <= self.profile.maximum_ticks:
            raise ActionAuthorityError(
                f"lease {ticks} outside profile range "
                f"{self.profile.minimum_ticks}..{self.profile.maximum_ticks}"
            )

    def _authorization(self, lease_ticks: int) -> Authorization:
        if self._state is None:
            raise RuntimeError("cannot authorize without an active plan")
        step = self._state.plan.steps[self._state.step_index]
        return Authorization(
            plan_id=self._state.plan.plan_id,
            step_id=step.step_id,
            action=step.action,
            lease_ticks=lease_ticks,
        )

    @staticmethod
    def _stale_reason(expected: SourceObservation, actual: ObservationSource) -> str | None:
        if expected.observation_seq != actual.observation_seq:
            return "stale_observation"
        if expected.tick != actual.tick:
            return "stale_tick"
        if expected.state_hash != actual.state_hash:
            return "stale_state"
        return None

    def _receipt_id(self) -> str:
        self._receipt_seq += 1
        return f"decision-{self._receipt_seq:06d}"

    def _accepted_receipt(
        self,
        source: ObservationSource,
        response_type: str,
        plan_id: str | None,
        step_id: str | None,
    ) -> ActionReceipt:
        return ActionReceipt(
            schema_version="action-receipt.v1",
            protocol="worldeval-agent/0.1.0",
            receipt_id=self._receipt_id(),
            observation_seq=source.observation_seq,
            response_type=response_type,
            plan_id=plan_id,
            step_id=step_id,
            accepted=True,
            disposition="accepted",
            fallback="none",
            no_input_reason=None,
            start_tick=source.tick,
            end_tick=source.tick,
            applied_ticks=0,
            codes=["decision_accepted"],
            effects=[],
        )

    def _neutral_receipt(
        self,
        source: ObservationSource,
        reason: str,
        *,
        response_type: str | None = None,
    ) -> ActionReceipt:
        return ActionReceipt(
            schema_version="action-receipt.v1",
            protocol="worldeval-agent/0.1.0",
            receipt_id=self._receipt_id(),
            observation_seq=source.observation_seq,
            response_type=response_type,
            plan_id=self.active_plan_id,
            step_id=self.active_summary.step_id if self.active_summary else None,
            accepted=False,
            disposition="no_input",
            fallback="neutral",
            no_input_reason=reason,
            start_tick=source.tick,
            end_tick=source.tick,
            applied_ticks=0,
            codes=["neutral_noop"],
            effects=[],
        )

    def _rejected_receipt(
        self,
        source: ObservationSource,
        response_type: str,
        code: str,
        *,
        detail: str | None = None,
    ) -> ActionReceipt:
        codes = [code]
        if detail:
            codes.append("detail_available")
        return ActionReceipt(
            schema_version="action-receipt.v1",
            protocol="worldeval-agent/0.1.0",
            receipt_id=self._receipt_id(),
            observation_seq=source.observation_seq,
            response_type=response_type,
            plan_id=self.active_plan_id,
            step_id=self.active_summary.step_id if self.active_summary else None,
            accepted=False,
            disposition="rejected",
            fallback="none",
            no_input_reason=None,
            start_tick=source.tick,
            end_tick=source.tick,
            applied_ticks=0,
            codes=codes,
            effects=[],
        )
