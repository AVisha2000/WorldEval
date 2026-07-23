"""Repository-native feature lifecycle management.

Lifecycle state is intentionally derived from directory placement.  Feature
metadata never contains a second, potentially contradictory, status field.
"""

from .workflow import (
    FeatureManager,
    FeatureRecord,
    FeatureWorkflowError,
    FeatureWorkspace,
    ValidationIssue,
)

__all__ = [
    "FeatureRecord",
    "FeatureManager",
    "FeatureWorkflowError",
    "FeatureWorkspace",
    "ValidationIssue",
]
