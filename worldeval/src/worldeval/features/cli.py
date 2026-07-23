"""Argparse interface for the repository-native feature workflow."""

from __future__ import annotations

import argparse
import getpass
import importlib
import json
import os
import sys
from pathlib import Path
from typing import Any, Sequence

from .workflow import FeatureWorkflowError, FeatureWorkspace


def _default_owner() -> str:
    return os.environ.get("CODEX_AGENT_NAME") or os.environ.get("USER") or getpass.getuser()


def _repository_native_verifiers() -> Any:
    """Load the environment adapter only at the replay completion boundary.

    WorldEval core remains importable without WorldArena. If the optional
    adapter is absent or broken, replay-required completion fails closed in the
    workflow instead of trusting manifest claims.
    """

    try:
        module = importlib.import_module("worldarena.replay_verifiers")
        return module.default_native_verifiers()
    except (AttributeError, ImportError, OSError, RuntimeError, TypeError, ValueError):
        return None


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="worldeval feature", description="Manage WorldEval features"
    )
    parser.add_argument("--root", type=Path, help="repository root (defaults to auto-discovery)")
    commands = parser.add_subparsers(dest="command", required=True)

    create = commands.add_parser("new", help="create a backlog feature from the standard template")
    create.add_argument("feature_id")
    create.add_argument("--title", required=True)
    create.add_argument("--summary", required=True)
    create.add_argument("--slug")
    create.add_argument("--product", default="worldeval")
    create.add_argument("--kind", default="capability")
    create.add_argument("--priority", choices=("p0", "p1", "p2", "p3"), default="p2")
    create.add_argument("--risk", choices=("low", "medium", "high", "critical"), default="medium")
    create.add_argument("--dependency", action="append", default=[])
    create.add_argument("--related-feature", action="append", default=[])
    create.add_argument("--supersedes", action="append", default=[])
    create.add_argument("--in-scope", action="append", default=[])
    create.add_argument("--out-of-scope", action="append", default=[])
    create.add_argument("--affected-path", action="append", default=[])
    create.add_argument("--shared-surface", action="append", default=[])
    create.add_argument("--acceptance", action="append", default=[])
    create.add_argument("--proof-type", action="append", default=[])
    create.add_argument("--demo-required", action="store_true")
    create.add_argument("--replay-required", action="store_true")
    create.add_argument("--required-approval", action="append", default=[])

    listing = commands.add_parser("list", help="list features and directory-derived states")
    listing.add_argument("--json", action="store_true", dest="as_json")

    validate = commands.add_parser("validate", help="validate feature records")
    validate.add_argument("feature_id", nargs="?")
    validate.add_argument("--json", action="store_true", dest="as_json")

    claim = commands.add_parser("claim", help="atomically move a backlog feature into progress")
    claim.add_argument("feature_id")
    claim.add_argument("--owner", default=_default_owner())
    claim.add_argument("--collaborator", action="append", default=[])
    claim.add_argument("--branch")
    claim.add_argument("--task-id", default=os.environ.get("CODEX_TASK_ID"))
    claim.add_argument("--lease-hours", type=int, default=24)

    renew = commands.add_parser("renew", help="renew an active claim lease")
    renew.add_argument("feature_id")
    renew.add_argument("--owner", default=_default_owner())
    renew.add_argument("--lease-hours", type=int, default=24)

    block = commands.add_parser("block", help="record a blocker without abandoning work")
    block.add_argument("feature_id")
    block.add_argument("--owner", default=_default_owner())
    block.add_argument("--reason", required=True)
    block.add_argument("--next-action", required=True)
    block.add_argument("--lease-hours", type=int, default=24)

    ready = commands.add_parser("ready", help="run completion gates and mark evidence ready")
    ready.add_argument("feature_id")
    ready.add_argument("--owner", default=_default_owner())
    ready.add_argument("--resolve-blockers", action="store_true")

    release = commands.add_parser("release", help="return an in-progress feature to backlog")
    release.add_argument("feature_id")
    release.add_argument("--owner", default=_default_owner())
    release.add_argument("--reason", required=True)

    reclaim = commands.add_parser("reclaim", help="take over an expired claim after inspection")
    reclaim.add_argument("feature_id")
    reclaim.add_argument("--owner", default=_default_owner())
    reclaim.add_argument("--inspected-revision", required=True)
    reclaim.add_argument("--collaborator", action="append", default=[])
    reclaim.add_argument("--branch")
    reclaim.add_argument("--task-id", default=os.environ.get("CODEX_TASK_ID"))
    reclaim.add_argument("--lease-hours", type=int, default=24)

    complete = commands.add_parser("complete", help="gate and move a feature to implemented")
    complete.add_argument("feature_id")
    complete.add_argument("--owner", default=_default_owner())

    doctor = commands.add_parser("doctor", help="inspect or safely repair interrupted operations")
    doctor.add_argument("--repair", action="store_true")
    doctor.add_argument("--json", action="store_true", dest="as_json")
    return parser


def _record_payload(record: Any, workspace: FeatureWorkspace) -> dict[str, Any]:
    value = record.as_dict(workspace._now())
    try:
        value["path"] = str(record.path.relative_to(workspace.root))
    except ValueError:
        pass
    return value


def _print_json(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        workspace = FeatureWorkspace(
            args.root,
            native_replay_verifiers=_repository_native_verifiers(),
        )
        if args.command == "new":
            proof_types = args.proof_type or ["test"]
            criteria = [
                {
                    "id": f"{args.feature_id}-AC-{index:02d}",
                    "description": description,
                    "proof_types": proof_types,
                    "demo_required": args.demo_required,
                    "replay_required": args.replay_required,
                }
                for index, description in enumerate(args.acceptance, start=1)
            ]
            record = workspace.create(
                args.feature_id,
                title=args.title,
                summary=args.summary,
                slug=args.slug,
                product=args.product,
                kind=args.kind,
                priority=args.priority,
                risk=args.risk,
                dependencies=args.dependency,
                related_features=args.related_feature,
                supersedes=args.supersedes,
                in_scope=args.in_scope,
                out_of_scope=args.out_of_scope,
                affected_paths=args.affected_path,
                shared_surfaces=args.shared_surface,
                acceptance_criteria=criteria or None,
                required_approvals=args.required_approval,
            )
            _print_json(_record_payload(record, workspace))
        elif args.command == "list":
            values = [_record_payload(record, workspace) for record in workspace.list_features()]
            if args.as_json:
                _print_json(values)
            else:
                for value in values:
                    owner = value.get("claim", {}).get("owner", "-")
                    print(f"{value['id']}\t{value['state']}\t{owner}\t{value['title']}")
        elif args.command == "validate":
            issues = workspace.validate(args.feature_id)
            if args.as_json:
                _print_json([issue.as_dict() for issue in issues])
            elif issues:
                for issue in issues:
                    location = f" ({issue.path})" if issue.path else ""
                    print(f"{issue.level}: {issue.code}: {issue.message}{location}")
            else:
                print("feature records are valid")
            return 1 if any(issue.level == "error" for issue in issues) else 0
        elif args.command == "claim":
            record = workspace.claim(
                args.feature_id,
                owner=args.owner,
                collaborators=args.collaborator,
                branch=args.branch,
                task_id=args.task_id,
                lease_hours=args.lease_hours,
            )
            _print_json(_record_payload(record, workspace))
        elif args.command == "renew":
            record = workspace.renew(
                args.feature_id, actor=args.owner, lease_hours=args.lease_hours
            )
            _print_json(_record_payload(record, workspace))
        elif args.command == "block":
            record = workspace.block(
                args.feature_id,
                actor=args.owner,
                reason=args.reason,
                next_action=args.next_action,
                lease_hours=args.lease_hours,
            )
            _print_json(_record_payload(record, workspace))
        elif args.command == "ready":
            record = workspace.ready(
                args.feature_id,
                actor=args.owner,
                resolve_blockers=args.resolve_blockers,
            )
            _print_json(_record_payload(record, workspace))
        elif args.command == "release":
            record = workspace.release(args.feature_id, actor=args.owner, reason=args.reason)
            _print_json(_record_payload(record, workspace))
        elif args.command == "reclaim":
            record = workspace.reclaim(
                args.feature_id,
                owner=args.owner,
                inspected_revision=args.inspected_revision,
                collaborators=args.collaborator,
                branch=args.branch,
                task_id=args.task_id,
                lease_hours=args.lease_hours,
            )
            _print_json(_record_payload(record, workspace))
        elif args.command == "complete":
            record = workspace.complete(args.feature_id, actor=args.owner)
            _print_json(_record_payload(record, workspace))
        elif args.command == "doctor":
            report = workspace.doctor(repair=args.repair)
            if args.as_json:
                _print_json(report)
            else:
                for repaired in report["repaired"]:
                    print(f"repaired: {repaired['code']}: {repaired['path']}")
                for issue in report["issues"]:
                    print(f"issue: {issue['code']}: {issue['message']}")
                if not report["issues"] and not report["repaired"]:
                    print("feature workspace is healthy")
            return 1 if report["issues"] and not args.repair else 0
        return 0
    except FeatureWorkflowError as exc:
        print(f"worldeval feature: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
