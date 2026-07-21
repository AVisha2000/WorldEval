"""Isolated protocol-v2 solo control games and participant-visible Demo policies."""

from .movement_maze_demo import (
    MOVEMENT_MAZE_DEMO_MODEL,
    MOVEMENT_MAZE_POLICY_ID,
    MOVEMENT_MAZE_SCENARIO_ID,
    movement_maze_demo_behavior,
)
from .movement_maze_evaluation import evaluate_movement_maze
from .operator_action_course_demo import (
    OPERATOR_ACTION_COURSE_DEMO_MODEL,
    OPERATOR_ACTION_COURSE_POLICY_ID,
    OPERATOR_ACTION_COURSE_SCENARIO_ID,
    operator_action_course_demo_behavior,
)
from .operator_action_course_evaluation import evaluate_operator_action_course

__all__ = [
    "MOVEMENT_MAZE_DEMO_MODEL",
    "MOVEMENT_MAZE_POLICY_ID",
    "MOVEMENT_MAZE_SCENARIO_ID",
    "OPERATOR_ACTION_COURSE_DEMO_MODEL",
    "OPERATOR_ACTION_COURSE_POLICY_ID",
    "OPERATOR_ACTION_COURSE_SCENARIO_ID",
    "evaluate_movement_maze",
    "evaluate_operator_action_course",
    "movement_maze_demo_behavior",
    "operator_action_course_demo_behavior",
]
