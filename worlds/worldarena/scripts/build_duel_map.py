#!/usr/bin/env python3
"""Build the deterministic WorldArena Duel launch-map manifest.

The generated JSON is authoritative benchmark data.  It deliberately contains
no render-mesh references: every one of the 384 x 256 logical cells can be
reconstructed losslessly from a row-RLE stream and an explicit cell palette.
"""

from __future__ import annotations

import argparse
import hashlib
import heapq
import json
import math
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, MutableMapping, Sequence, Set, Tuple

WIDTH = 384
HEIGHT = 256
CELL_SIZE_MT = 500
WORLD_MAX = (191_999, 127_999)
CELL_MAX = (383, 255)
MAP_ID = "crossroads-duel-v1"
SCHEMA_VERSION = "worldeval-rts/map-manifest/1.0.0"
ALGORITHM_VERSION = "crossroads-duel-generator/1.0.0"

# This order is part of the public wire contract. Positional palette entries keep the complete,
# lossless map small enough to coexist with all required catalogs in MATCH_INIT.
CELL_PALETTE_FIELDS: Tuple[str, ...] = (
    "terrain_id",
    "elevation",
    "ground_pathable",
    "air_pathable",
    "buildable_site_id",
    "region_id",
    "los_block_height",
    "destructible_id",
    "rotated_palette_index",
)

Cell = Tuple[int, int]


REGION_SPECS: Sequence[Tuple[str, Tuple[int, int], int, Sequence[str]]] = (
    ("r_self_home", (96, 112), 0, ("self_start", "buildable", "home_mine")),
    (
        "r_self_natural",
        (96, 94),
        0,
        ("natural_expansion", "medium_camp"),
    ),
    (
        "r_self_west_approach",
        (62, 99),
        0,
        ("choke", "forest", "easy_camp"),
    ),
    (
        "r_self_east_approach",
        (130, 99),
        0,
        ("choke", "forest", "easy_camp"),
    ),
    (
        "r_self_west_wild",
        (36, 92),
        0,
        ("easy_camp", "destructible_route"),
    ),
    (
        "r_self_east_wild",
        (156, 92),
        0,
        ("easy_camp", "destructible_route"),
    ),
    (
        "r_west_neutral",
        (16, 64),
        0,
        ("laboratory", "merchant", "medium_camp"),
    ),
    (
        "r_west_contested",
        (38, 64),
        0,
        ("contested_expansion", "hard_camp"),
    ),
    (
        "r_center",
        (96, 64),
        1,
        ("tavern", "two_medium_camps", "high_ground"),
    ),
    (
        "r_east_contested",
        (154, 64),
        0,
        ("contested_expansion", "hard_camp"),
    ),
    (
        "r_east_neutral",
        (176, 64),
        0,
        ("laboratory", "merchant", "medium_camp"),
    ),
    (
        "r_opponent_west_wild",
        (36, 36),
        0,
        ("easy_camp", "destructible_route"),
    ),
    (
        "r_opponent_east_wild",
        (156, 36),
        0,
        ("easy_camp", "destructible_route"),
    ),
    (
        "r_opponent_west_approach",
        (62, 29),
        0,
        ("choke", "forest", "easy_camp"),
    ),
    (
        "r_opponent_east_approach",
        (130, 29),
        0,
        ("choke", "forest", "easy_camp"),
    ),
    (
        "r_opponent_natural",
        (96, 34),
        0,
        ("natural_expansion", "medium_camp"),
    ),
    (
        "r_opponent_home",
        (96, 16),
        0,
        ("opponent_start", "buildable", "home_mine"),
    ),
)


REGION_MIRROR: Mapping[str, str] = {
    "r_self_home": "r_opponent_home",
    "r_opponent_home": "r_self_home",
    "r_self_natural": "r_opponent_natural",
    "r_opponent_natural": "r_self_natural",
    "r_self_west_approach": "r_opponent_east_approach",
    "r_opponent_east_approach": "r_self_west_approach",
    "r_self_east_approach": "r_opponent_west_approach",
    "r_opponent_west_approach": "r_self_east_approach",
    "r_self_west_wild": "r_opponent_east_wild",
    "r_opponent_east_wild": "r_self_west_wild",
    "r_self_east_wild": "r_opponent_west_wild",
    "r_opponent_west_wild": "r_self_east_wild",
    "r_west_neutral": "r_east_neutral",
    "r_east_neutral": "r_west_neutral",
    "r_west_contested": "r_east_contested",
    "r_east_contested": "r_west_contested",
    "r_center": "r_center",
}


ADJACENCY: Mapping[str, Sequence[str]] = {
    "r_self_home": (
        "r_self_natural",
        "r_self_west_approach",
        "r_self_east_approach",
    ),
    "r_self_natural": (
        "r_self_home",
        "r_self_west_approach",
        "r_self_east_approach",
        "r_center",
    ),
    "r_self_west_approach": (
        "r_self_home",
        "r_self_natural",
        "r_self_west_wild",
        "r_west_contested",
    ),
    "r_self_east_approach": (
        "r_self_home",
        "r_self_natural",
        "r_self_east_wild",
        "r_east_contested",
    ),
    "r_self_west_wild": (
        "r_self_west_approach",
        "r_west_neutral",
        "r_west_contested",
    ),
    "r_self_east_wild": (
        "r_self_east_approach",
        "r_east_neutral",
        "r_east_contested",
    ),
    "r_west_neutral": (
        "r_self_west_wild",
        "r_west_contested",
        "r_opponent_west_wild",
    ),
    "r_east_neutral": (
        "r_self_east_wild",
        "r_east_contested",
        "r_opponent_east_wild",
    ),
    "r_west_contested": (
        "r_self_west_approach",
        "r_self_west_wild",
        "r_west_neutral",
        "r_center",
        "r_opponent_west_wild",
        "r_opponent_west_approach",
    ),
    "r_east_contested": (
        "r_self_east_approach",
        "r_self_east_wild",
        "r_east_neutral",
        "r_center",
        "r_opponent_east_wild",
        "r_opponent_east_approach",
    ),
    "r_center": (
        "r_self_natural",
        "r_west_contested",
        "r_east_contested",
        "r_opponent_natural",
    ),
    "r_opponent_west_wild": (
        "r_west_neutral",
        "r_west_contested",
        "r_opponent_west_approach",
    ),
    "r_opponent_east_wild": (
        "r_east_neutral",
        "r_east_contested",
        "r_opponent_east_approach",
    ),
    "r_opponent_west_approach": (
        "r_west_contested",
        "r_opponent_west_wild",
        "r_opponent_natural",
        "r_opponent_home",
    ),
    "r_opponent_east_approach": (
        "r_east_contested",
        "r_opponent_east_wild",
        "r_opponent_natural",
        "r_opponent_home",
    ),
    "r_opponent_natural": (
        "r_center",
        "r_opponent_west_approach",
        "r_opponent_east_approach",
        "r_opponent_home",
    ),
    "r_opponent_home": (
        "r_opponent_natural",
        "r_opponent_west_approach",
        "r_opponent_east_approach",
    ),
}


FOOTPRINT_CLASSES: Mapping[str, Tuple[int, int]] = {
    "food": (2, 2),
    "tower": (2, 2),
    "shop": (2, 2),
    "altar": (3, 3),
    "forge": (3, 3),
    "barracks": (4, 3),
    "range": (4, 3),
    "mystic": (4, 3),
    "workshop": (4, 4),
    "hall": (5, 5),
    "stronghold": (6, 6),
}


TERRAIN_CATALOG: Mapping[str, Mapping[str, Any]] = {
    "grass": {
        "movement_basis_points": 1_000,
        "ground_pathable": True,
        "air_pathable": True,
        "buildable": False,
        "los_block_height": 0,
    },
    "highland": {
        "movement_basis_points": 1_000,
        "ground_pathable": True,
        "air_pathable": True,
        "buildable": False,
        "los_block_height": 0,
    },
    "road": {
        "movement_basis_points": 900,
        "ground_pathable": True,
        "air_pathable": True,
        "buildable": False,
        "los_block_height": 0,
    },
    "build_pad": {
        "movement_basis_points": 1_000,
        "ground_pathable": True,
        "air_pathable": True,
        "buildable": True,
        "los_block_height": 0,
    },
    "forest": {
        "movement_basis_points": 1_000,
        "ground_pathable": False,
        "air_pathable": True,
        "buildable": False,
        "los_block_height": 2,
    },
    "gold_mine": {
        "movement_basis_points": 1_000,
        "ground_pathable": False,
        "air_pathable": True,
        "buildable": False,
        "los_block_height": 1,
    },
    "neutral_structure": {
        "movement_basis_points": 1_000,
        "ground_pathable": False,
        "air_pathable": True,
        "buildable": False,
        "los_block_height": 1,
    },
    "deep_water": {
        "movement_basis_points": 1_000,
        "ground_pathable": False,
        "air_pathable": True,
        "buildable": False,
        "los_block_height": 0,
    },
}


def rotate_cell(cell: Cell) -> Cell:
    return CELL_MAX[0] - cell[0], CELL_MAX[1] - cell[1]


def rotate_position(position_mt: Sequence[int]) -> List[int]:
    return [WORLD_MAX[0] - position_mt[0], WORLD_MAX[1] - position_mt[1]]


def cell_center_mt(cell: Cell) -> List[int]:
    return [cell[0] * CELL_SIZE_MT + 250, cell[1] * CELL_SIZE_MT + 250]


def rect_cells(anchor: Cell, width: int, height: int) -> List[Cell]:
    return [
        (x, y)
        for y in range(anchor[1], anchor[1] + height)
        for x in range(anchor[0], anchor[0] + width)
    ]


def sorted_cells(cells: Iterable[Cell]) -> List[List[int]]:
    return [[x, y] for x, y in sorted(set(cells), key=lambda item: (item[1], item[0]))]


def rotated_cells(cells: Iterable[Cell]) -> List[Cell]:
    return [rotate_cell(cell) for cell in cells]


def mirror_rect_anchor(anchor: Cell, width: int, height: int) -> Cell:
    return WIDTH - anchor[0] - width, HEIGHT - anchor[1] - height


def cardinal_exit_cells(anchor: Cell, width: int, height: int) -> List[Cell]:
    """Return seat-relative north, east, south, west production exits."""

    x, y = anchor
    return [
        (x + (width - 1) // 2, y - 1),
        (x + width, y + (height - 1) // 2),
        (x + (width - 1) // 2, y + height),
        (x - 1, y + (height - 1) // 2),
    ]


def _region_seed_specs() -> Sequence[Tuple[str, Cell]]:
    # Only the lower half is authored.  The upper half is an exact rotation.
    return (
        ("r_self_home", (192, 224)),
        ("r_self_natural", (192, 188)),
        ("r_self_west_approach", (124, 198)),
        ("r_self_east_approach", (260, 198)),
        ("r_self_west_wild", (72, 184)),
        ("r_self_east_wild", (312, 184)),
        ("r_west_neutral", (32, 128)),
        ("r_west_contested", (76, 128)),
        ("r_center", (192, 128)),
        ("r_east_contested", (308, 128)),
        ("r_east_neutral", (352, 128)),
    )


def build_region_grid() -> List[List[str]]:
    grid: List[List[str | None]] = [[None for _ in range(WIDTH)] for _ in range(HEIGHT)]
    seeds = _region_seed_specs()

    for y in range(HEIGHT // 2, HEIGHT):
        for x in range(WIDTH):
            _, _, region_id = min(
                (
                    (x - seed_x) ** 2 + (y - seed_y) ** 2,
                    index,
                    candidate_id,
                )
                for index, (candidate_id, (seed_x, seed_y)) in enumerate(seeds)
            )
            grid[y][x] = region_id

    # Rasterize the two four-region junctions without inventing graph edges.
    # A one-cell contested strip separates center from the approach regions.
    replacements: List[Tuple[int, int, str]] = []
    for y in range(HEIGHT // 2, HEIGHT):
        for x in range(WIDTH):
            region_id = grid[y][x]
            if region_id not in ("r_self_west_approach", "r_self_east_approach"):
                continue
            if any(
                0 <= x + dx < WIDTH
                and HEIGHT // 2 <= y + dy < HEIGHT
                and grid[y + dy][x + dx] == "r_center"
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
            ):
                replacement = (
                    "r_west_contested"
                    if region_id == "r_self_west_approach"
                    else "r_east_contested"
                )
                replacements.append((x, y, replacement))
    for x, y, replacement in replacements:
        grid[y][x] = replacement

    # These are the two exact integer cells where the four-region cycles meet.
    # Assigning them to the natural preserves all and only Appendix C edges.
    grid[158][152] = "r_self_natural"
    grid[158][232] = "r_self_natural"

    for y in range(HEIGHT // 2, HEIGHT):
        for x in range(WIDTH):
            paired_x, paired_y = rotate_cell((x, y))
            region_id = grid[y][x]
            assert region_id is not None
            grid[paired_y][paired_x] = REGION_MIRROR[region_id]

    return [[str(value) for value in row] for row in grid]


def _edge_set() -> Set[Tuple[str, str]]:
    return {
        tuple(sorted((region_id, neighbor)))
        for region_id, neighbors in ADJACENCY.items()
        for neighbor in neighbors
    }


def _raster_region_edges(region_grid: Sequence[Sequence[str]]) -> Set[Tuple[str, str]]:
    edges: Set[Tuple[str, str]] = set()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            here = region_grid[y][x]
            if x + 1 < WIDTH and region_grid[y][x + 1] != here:
                edges.add(tuple(sorted((here, region_grid[y][x + 1]))))
            if y + 1 < HEIGHT and region_grid[y + 1][x] != here:
                edges.add(tuple(sorted((here, region_grid[y + 1][x]))))
    return edges


def _convex_hull(points: Iterable[Cell]) -> List[Cell]:
    unique = sorted(set(points))
    if len(unique) <= 1:
        return unique

    def cross(origin: Cell, a: Cell, b: Cell) -> int:
        return (a[0] - origin[0]) * (b[1] - origin[1]) - (a[1] - origin[1]) * (b[0] - origin[0])

    lower: List[Cell] = []
    for point in unique:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], point) <= 0:
            lower.pop()
        lower.append(point)
    upper: List[Cell] = []
    for point in reversed(unique):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], point) <= 0:
            upper.pop()
        upper.append(point)
    return lower[:-1] + upper[:-1]


def build_regions(region_grid: Sequence[Sequence[str]]) -> List[Dict[str, Any]]:
    cells_by_region: Dict[str, List[Cell]] = {spec[0]: [] for spec in REGION_SPECS}
    for y, row in enumerate(region_grid):
        for x, region_id in enumerate(row):
            cells_by_region[region_id].append((x, y))

    authored_anchors = dict(_region_seed_specs())
    anchors: Dict[str, List[Cell]] = {}
    for region_id, anchor in authored_anchors.items():
        anchors.setdefault(region_id, []).append(anchor)
        paired_id = REGION_MIRROR[region_id]
        paired_anchor = rotate_cell(anchor)
        if paired_anchor not in anchors.setdefault(paired_id, []):
            anchors[paired_id].append(paired_anchor)
    # The tavern occupies the geometric center; navigation anchors stay clear.
    anchors["r_center"] = [(192, 136), (191, 119)]

    regions: List[Dict[str, Any]] = []
    for region_id, centroid_tile, elevation, tags in REGION_SPECS:
        # Convex hull of exact cell-boundary corners is a compact public review polygon.
        corners: List[Cell] = []
        for x, y in cells_by_region[region_id]:
            corners.extend(((x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)))
        hull = _convex_hull(corners)
        regions.append(
            {
                "id": region_id,
                "review_centroid_tile": list(centroid_tile),
                "centroid_mt": [centroid_tile[0] * 1_000, centroid_tile[1] * 1_000],
                "navigation_anchor_cells": sorted_cells(anchors[region_id]),
                "elevation": elevation,
                "tags": list(tags),
                "boundary_cell_polygon": [[x, y] for x, y in hull],
                "cell_count": len(cells_by_region[region_id]),
            }
        )
    return regions


def _draw_line(start: Cell, end: Cell) -> List[Cell]:
    x0, y0 = start
    x1, y1 = end
    dx = abs(x1 - x0)
    sx = 1 if x0 < x1 else -1
    dy = -abs(y1 - y0)
    sy = 1 if y0 < y1 else -1
    error = dx + dy
    result: List[Cell] = []
    while True:
        result.append((x0, y0))
        if x0 == x1 and y0 == y1:
            break
        twice_error = 2 * error
        if twice_error >= dy:
            error += dy
            x0 += sx
        if twice_error <= dx:
            error += dx
            y0 += sy
    return result


def build_road_mask(region_grid: Sequence[Sequence[str]]) -> Set[Cell]:
    regions = build_regions(region_grid)
    anchors = {region["id"]: tuple(region["navigation_anchor_cells"][0]) for region in regions}
    roads: Set[Cell] = set()
    for a, b in sorted(_edge_set()):
        for center in _draw_line(anchors[a], anchors[b]):
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    if abs(dx) + abs(dy) > 3:
                        continue
                    candidate = (center[0] + dx, center[1] + dy)
                    if 4 <= candidate[0] < WIDTH - 4 and 4 <= candidate[1] < HEIGHT - 4:
                        roads.add(candidate)
                        roads.add(rotate_cell(candidate))
    return roads


def _site(
    site_id: str,
    region_id: str,
    category: str,
    footprint_class: str,
    anchor: Cell,
    occupied_by: str | None = None,
) -> Dict[str, Any]:
    width, height = FOOTPRINT_CLASSES[footprint_class]
    cells = rect_cells(anchor, width, height)
    exits = cardinal_exit_cells(anchor, width, height)
    return {
        "id": site_id,
        "region_id": region_id,
        "category": category,
        "allowed_footprint_class": footprint_class,
        "anchor_cell": list(anchor),
        "footprint_cells": sorted_cells(cells),
        "production_exit_cells": [[x, y] for x, y in exits],
        "exit_order_frame": "seat_relative_north_clockwise",
        "starts_occupied_by": occupied_by,
    }


def _mirror_site(site: Mapping[str, Any], mirror_id: str) -> Dict[str, Any]:
    footprint_class = str(site["allowed_footprint_class"])
    width, height = FOOTPRINT_CLASSES[footprint_class]
    anchor = mirror_rect_anchor(tuple(site["anchor_cell"]), width, height)
    occupied = site["starts_occupied_by"]
    if occupied is not None:
        occupied = str(occupied).replace("self", "opponent")
    return {
        "id": mirror_id,
        "region_id": REGION_MIRROR[str(site["region_id"])],
        "category": site["category"],
        "allowed_footprint_class": footprint_class,
        "anchor_cell": list(anchor),
        "footprint_cells": sorted_cells(rotated_cells(tuple(c) for c in site["footprint_cells"])),
        "production_exit_cells": [
            list(rotate_cell(tuple(cell))) for cell in site["production_exit_cells"]
        ],
        "exit_order_frame": "seat_relative_north_clockwise",
        "starts_occupied_by": occupied,
    }


def build_build_sites() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    authored: Sequence[Tuple[str, str, str, str, Cell, str | None]] = (
        (
            "bs_self_home_inner_01_stronghold",
            "r_self_home",
            "inner",
            "stronghold",
            (189, 222),
            "spawn_self_stronghold",
        ),
        (
            "bs_self_home_inner_02_food",
            "r_self_home",
            "inner",
            "food",
            (181, 232),
            "spawn_self_food",
        ),
        ("bs_self_home_inner_03_altar", "r_self_home", "inner", "altar", (200, 225), None),
        (
            "bs_self_home_inner_04_barracks",
            "r_self_home",
            "inner",
            "barracks",
            (176, 218),
            None,
        ),
        ("bs_self_home_inner_05_forge", "r_self_home", "inner", "forge", (203, 217), None),
        ("bs_self_home_inner_06_shop", "r_self_home", "inner", "shop", (183, 223), None),
        ("bs_self_home_economy_01", "r_self_home", "economy", "food", (174, 230), None),
        ("bs_self_home_economy_02", "r_self_home", "economy", "food", (208, 230), None),
        (
            "bs_self_home_economy_03",
            "r_self_home",
            "economy",
            "workshop",
            (169, 222),
            None,
        ),
        (
            "bs_self_home_economy_04",
            "r_self_home",
            "economy",
            "barracks",
            (211, 221),
            None,
        ),
        ("bs_self_home_outer_01", "r_self_home", "outer", "range", (160, 212), None),
        ("bs_self_home_outer_02", "r_self_home", "outer", "mystic", (220, 212), None),
        ("bs_self_home_outer_03", "r_self_home", "outer", "barracks", (158, 232), None),
        ("bs_self_home_outer_04", "r_self_home", "outer", "food", (225, 232), None),
        ("bs_self_home_tower_01", "r_self_home", "tower", "tower", (166, 207), None),
        ("bs_self_home_tower_02", "r_self_home", "tower", "tower", (216, 207), None),
        ("bs_self_home_choke_01", "r_self_home", "choke", "tower", (181, 206), None),
        ("bs_self_home_choke_02", "r_self_home", "choke", "tower", (201, 206), None),
        ("bs_self_natural_hall", "r_self_natural", "hall", "hall", (190, 184), None),
        ("bs_self_natural_economy_01", "r_self_natural", "economy", "food", (180, 185), None),
        ("bs_self_natural_economy_02", "r_self_natural", "economy", "food", (201, 185), None),
        ("bs_self_natural_economy_03", "r_self_natural", "economy", "shop", (190, 196), None),
        ("bs_self_natural_tower_01", "r_self_natural", "tower", "tower", (174, 178), None),
        ("bs_self_natural_tower_02", "r_self_natural", "tower", "tower", (208, 178), None),
        ("bs_self_natural_outer_01", "r_self_natural", "outer", "barracks", (170, 191), None),
        ("bs_self_natural_outer_02", "r_self_natural", "outer", "barracks", (211, 191), None),
        ("bs_west_contested_hall", "r_west_contested", "hall", "hall", (72, 126), None),
        ("bs_west_contested_economy_01", "r_west_contested", "economy", "food", (62, 134), None),
        ("bs_west_contested_economy_02", "r_west_contested", "economy", "food", (85, 134), None),
        ("bs_west_contested_tower_01", "r_west_contested", "tower", "tower", (62, 119), None),
        ("bs_west_contested_tower_02", "r_west_contested", "tower", "tower", (87, 119), None),
    )

    sites: List[Dict[str, Any]] = []
    pairs: List[Dict[str, str]] = []
    for site_id, region_id, category, footprint_class, anchor, occupied_by in authored:
        site = _site(site_id, region_id, category, footprint_class, anchor, occupied_by)
        if site_id.startswith("bs_self_"):
            mirror_id = site_id.replace("bs_self_", "bs_opponent_", 1)
        elif site_id.startswith("bs_west_"):
            mirror_id = site_id.replace("bs_west_", "bs_east_", 1)
        else:
            raise AssertionError(f"No mirror naming rule for {site_id}")
        mirror = _mirror_site(site, mirror_id)
        sites.extend((site, mirror))
        pairs.append({"a": site_id, "b": mirror_id})
    return sorted(sites, key=lambda item: item["id"]), sorted(pairs, key=lambda item: item["a"])


def _resource_site(
    site_id: str,
    kind: str,
    region_id: str,
    anchor: Cell,
    cells: Iterable[Cell],
    amount: int,
    approach_cell: Cell,
    tags: Sequence[str],
) -> Dict[str, Any]:
    return {
        "id": site_id,
        "kind": kind,
        "region_id": region_id,
        "anchor_cell": list(anchor),
        "position_mt": cell_center_mt(anchor),
        "approach_cell": list(approach_cell),
        "initial_amount": amount,
        "cells": sorted_cells(cells),
        "tags": list(tags),
    }


def _mirror_resource(site: Mapping[str, Any], mirror_id: str) -> Dict[str, Any]:
    anchor = rotate_cell(tuple(site["anchor_cell"]))
    return {
        "id": mirror_id,
        "kind": site["kind"],
        "region_id": REGION_MIRROR[str(site["region_id"])],
        "anchor_cell": list(anchor),
        "position_mt": rotate_position(site["position_mt"]),
        "approach_cell": list(rotate_cell(tuple(site["approach_cell"]))),
        "initial_amount": site["initial_amount"],
        "cells": sorted_cells(rotated_cells(tuple(c) for c in site["cells"])),
        "tags": list(site["tags"]),
    }


def build_resource_sites() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    authored = (
        _resource_site(
            "res_self_home_gold",
            "gold_mine",
            "r_self_home",
            (215, 240),
            rect_cells((215, 240), 4, 4),
            12_000,
            (213, 241),
            ("home", "starting_resource"),
        ),
        _resource_site(
            "res_self_home_forest",
            "lumber_cluster",
            "r_self_home",
            (148, 238),
            rect_cells((148, 238), 8, 10),
            3_200,
            (157, 242),
            ("home", "reachable_lumber"),
        ),
        _resource_site(
            "res_self_natural_gold",
            "gold_mine",
            "r_self_natural",
            (214, 168),
            rect_cells((214, 168), 4, 4),
            9_000,
            (212, 169),
            ("natural_expansion",),
        ),
        _resource_site(
            "res_west_contested_gold",
            "gold_mine",
            "r_west_contested",
            (84, 124),
            rect_cells((84, 124), 4, 4),
            6_000,
            (89, 125),
            ("contested_expansion",),
        ),
    )
    mirror_names = {
        "res_self_home_gold": "res_opponent_home_gold",
        "res_self_home_forest": "res_opponent_home_forest",
        "res_self_natural_gold": "res_opponent_natural_gold",
        "res_west_contested_gold": "res_east_contested_gold",
    }
    resources: List[Dict[str, Any]] = []
    pairs: List[Dict[str, str]] = []
    for site in authored:
        mirror_id = mirror_names[site["id"]]
        resources.extend((site, _mirror_resource(site, mirror_id)))
        pairs.append({"a": site["id"], "b": mirror_id})
    return sorted(resources, key=lambda item: item["id"]), sorted(pairs, key=lambda item: item["a"])


def _neutral_building(
    building_id: str,
    building_type: str,
    region_id: str,
    anchor: Cell,
    size: Tuple[int, int],
    approach_cells: Sequence[Cell],
    tags: Sequence[str],
) -> Dict[str, Any]:
    footprint = rect_cells(anchor, size[0], size[1])
    return {
        "id": building_id,
        "building_type": building_type,
        "region_id": region_id,
        "anchor_cell": list(anchor),
        "position_mt": cell_center_mt(anchor),
        "footprint_cells": sorted_cells(footprint),
        "approach_cells": [[x, y] for x, y in approach_cells],
        "tags": list(tags),
    }


def _mirror_neutral_building(building: Mapping[str, Any], mirror_id: str) -> Dict[str, Any]:
    footprint = [tuple(cell) for cell in building["footprint_cells"]]
    rotated_footprint = rotated_cells(footprint)
    anchor = min(rotated_footprint, key=lambda cell: (cell[1], cell[0]))
    return {
        "id": mirror_id,
        "building_type": building["building_type"],
        "region_id": REGION_MIRROR[str(building["region_id"])],
        "anchor_cell": list(anchor),
        "position_mt": rotate_position(building["position_mt"]),
        "footprint_cells": sorted_cells(rotated_footprint),
        "approach_cells": [list(rotate_cell(tuple(cell))) for cell in building["approach_cells"]],
        "tags": list(building["tags"]),
    }


def build_neutral_buildings() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    west_merchant = _neutral_building(
        "neutral_west_merchant",
        "merchant",
        "r_west_neutral",
        (20, 120),
        (3, 3),
        ((23, 121), (19, 121)),
        ("shop",),
    )
    west_laboratory = _neutral_building(
        "neutral_west_laboratory",
        "laboratory",
        "r_west_neutral",
        (20, 136),
        (4, 3),
        ((24, 137), (19, 137)),
        ("hire", "reveal_service"),
    )
    tavern = _neutral_building(
        "neutral_center_tavern",
        "tavern",
        "r_center",
        (190, 126),
        (4, 4),
        ((191, 125), (194, 127), (192, 130), (189, 128)),
        ("field_revival", "high_ground"),
    )
    buildings = [
        west_merchant,
        _mirror_neutral_building(west_merchant, "neutral_east_merchant"),
        west_laboratory,
        _mirror_neutral_building(west_laboratory, "neutral_east_laboratory"),
        tavern,
    ]
    pairs = [
        {"a": "neutral_west_merchant", "b": "neutral_east_merchant"},
        {"a": "neutral_west_laboratory", "b": "neutral_east_laboratory"},
        {"a": "neutral_center_tavern", "b": "neutral_center_tavern"},
    ]
    return sorted(buildings, key=lambda item: item["id"]), pairs


def _camp(
    camp_id: str,
    tier: str,
    region_id: str,
    anchor: Cell,
    members: Sequence[Tuple[str, int, Cell]],
) -> Dict[str, Any]:
    total_level = sum(member[1] for member in members)
    distributions = {
        "easy": {"tier_1": 70, "none": 30},
        "medium": {"tier_2": 70, "tier_1": 20, "none": 10},
        "hard": {"tier_3": 65, "tier_4": 25, "tier_2": 10},
    }
    return {
        "id": camp_id,
        "tier": tier,
        "region_id": region_id,
        "anchor_cell": list(anchor),
        "position_mt": cell_center_mt(anchor),
        "total_level": total_level,
        "item_tier_distribution_percent": distributions[tier],
        "gold_bounty": total_level * 25,
        "leash_radius_mt": 14_000,
        "formation": "authored_cells",
        "member_spawns": [
            {
                "id": f"{camp_id}_member_{index:02d}",
                "neutral_id": neutral_id,
                "level": level,
                "cell": [anchor[0] + offset[0], anchor[1] + offset[1]],
            }
            for index, (neutral_id, level, offset) in enumerate(members, start=1)
        ],
    }


def _mirror_camp(camp: Mapping[str, Any], mirror_id: str) -> Dict[str, Any]:
    anchor = rotate_cell(tuple(camp["anchor_cell"]))
    return {
        "id": mirror_id,
        "tier": camp["tier"],
        "region_id": REGION_MIRROR[str(camp["region_id"])],
        "anchor_cell": list(anchor),
        "position_mt": rotate_position(camp["position_mt"]),
        "total_level": camp["total_level"],
        "item_tier_distribution_percent": dict(camp["item_tier_distribution_percent"]),
        "gold_bounty": camp["gold_bounty"],
        "leash_radius_mt": camp["leash_radius_mt"],
        "formation": "authored_cells",
        "member_spawns": [
            {
                "id": f"{mirror_id}_member_{index:02d}",
                "neutral_id": member["neutral_id"],
                "level": member["level"],
                "cell": list(rotate_cell(tuple(member["cell"]))),
            }
            for index, member in enumerate(camp["member_spawns"], start=1)
        ],
    }


def build_creep_camps() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    easy_members = (("ridge_wolf", 2, (-1, 0)), ("brushling", 1, (1, 0)))
    natural_members = (
        ("hill_brute", 3, (0, 0)),
        ("ridge_wolf", 2, (-2, 1)),
        ("ridge_wolf", 2, (2, 1)),
    )
    neutral_members = (("mire_seer", 4, (-1, 0)), ("ridge_wolf", 2, (1, 0)))
    center_members = (("stone_keeper", 5, (-1, 0)), ("mire_archer", 2, (1, 0)))
    hard_members = (("elder_titan", 6, (-1, 0)), ("stone_keeper", 5, (1, 0)))
    authored = (
        _camp(
            "camp_self_west_approach_easy",
            "easy",
            "r_self_west_approach",
            (125, 184),
            easy_members,
        ),
        _camp(
            "camp_self_east_approach_easy",
            "easy",
            "r_self_east_approach",
            (259, 184),
            easy_members,
        ),
        _camp(
            "camp_self_west_wild_easy",
            "easy",
            "r_self_west_wild",
            (68, 173),
            easy_members,
        ),
        _camp(
            "camp_self_east_wild_easy",
            "easy",
            "r_self_east_wild",
            (316, 173),
            easy_members,
        ),
        _camp(
            "camp_self_natural_medium",
            "medium",
            "r_self_natural",
            (192, 169),
            natural_members,
        ),
        _camp(
            "camp_west_neutral_medium",
            "medium",
            "r_west_neutral",
            (36, 142),
            neutral_members,
        ),
        _camp(
            "camp_center_west_medium",
            "medium",
            "r_center",
            (168, 128),
            center_members,
        ),
        _camp(
            "camp_west_contested_hard",
            "hard",
            "r_west_contested",
            (96, 128),
            hard_members,
        ),
    )
    mirror_names = {
        "camp_self_west_approach_easy": "camp_opponent_east_approach_easy",
        "camp_self_east_approach_easy": "camp_opponent_west_approach_easy",
        "camp_self_west_wild_easy": "camp_opponent_east_wild_easy",
        "camp_self_east_wild_easy": "camp_opponent_west_wild_easy",
        "camp_self_natural_medium": "camp_opponent_natural_medium",
        "camp_west_neutral_medium": "camp_east_neutral_medium",
        "camp_center_west_medium": "camp_center_east_medium",
        "camp_west_contested_hard": "camp_east_contested_hard",
    }
    camps: List[Dict[str, Any]] = []
    pairs: List[Dict[str, str]] = []
    for camp in authored:
        mirror_id = mirror_names[camp["id"]]
        camps.extend((camp, _mirror_camp(camp, mirror_id)))
        pairs.append({"a": camp["id"], "b": mirror_id})
    return sorted(camps, key=lambda item: item["id"]), sorted(pairs, key=lambda item: item["a"])


def build_destructibles() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    west_cells = [(50, y) for y in range(164, 176)]
    west = {
        "id": "destructible_self_west_tree_line",
        "type": "tree_line",
        "region_id": "r_self_west_wild",
        "hp_per_cell": 200,
        "blocks_ground": True,
        "blocks_los": True,
        "cells": sorted_cells(west_cells),
        "opens_route_between": ["r_self_west_wild", "r_west_neutral"],
    }
    east_cells = rotated_cells(west_cells)
    east = {
        "id": "destructible_opponent_east_tree_line",
        "type": "tree_line",
        "region_id": "r_opponent_east_wild",
        "hp_per_cell": 200,
        "blocks_ground": True,
        "blocks_los": True,
        "cells": sorted_cells(east_cells),
        "opens_route_between": [
            REGION_MIRROR[west["opens_route_between"][0]],
            REGION_MIRROR[west["opens_route_between"][1]],
        ],
    }
    return [east, west], [{"a": west["id"], "b": east["id"]}]


def _spawn(
    spawn_id: str,
    seat: int,
    kind: str,
    entity_type: str,
    region_id: str,
    anchor_cell: Cell,
    footprint_cells: Sequence[Cell],
    build_site_id: str | None,
    tags: Sequence[str],
) -> Dict[str, Any]:
    return {
        "id": spawn_id,
        "seat": seat,
        "kind": kind,
        "entity_type": entity_type,
        "region_id": region_id,
        "anchor_cell": list(anchor_cell),
        "position_mt": cell_center_mt(anchor_cell),
        "footprint_cells": sorted_cells(footprint_cells),
        "build_site_id": build_site_id,
        "tags": list(tags),
    }


def _mirror_spawn(spawn: Mapping[str, Any], mirror_id: str) -> Dict[str, Any]:
    rotated_footprint = rotated_cells(tuple(cell) for cell in spawn["footprint_cells"])
    if spawn["kind"] == "structure":
        # Structure anchors are always the north-west footprint cell; their
        # independent pivot position still rotates as an exact world point.
        anchor = min(rotated_footprint, key=lambda cell: (cell[1], cell[0]))
    else:
        anchor = rotate_cell(tuple(spawn["anchor_cell"]))
    build_site_id = spawn["build_site_id"]
    if build_site_id is not None:
        build_site_id = str(build_site_id).replace("bs_self_", "bs_opponent_", 1)
    return {
        "id": mirror_id,
        "seat": 1,
        "kind": spawn["kind"],
        "entity_type": spawn["entity_type"],
        "region_id": REGION_MIRROR[str(spawn["region_id"])],
        "anchor_cell": list(anchor),
        "position_mt": rotate_position(spawn["position_mt"]),
        "footprint_cells": sorted_cells(rotated_footprint),
        "build_site_id": build_site_id,
        "tags": list(spawn["tags"]),
    }


def build_spawns() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    stronghold_cells = rect_cells((189, 222), 6, 6)
    food_cells = rect_cells((181, 232), 2, 2)
    self_spawns = [
        _spawn(
            "spawn_self_stronghold",
            0,
            "structure",
            "stronghold",
            "r_self_home",
            (189, 222),
            stronghold_cells,
            "bs_self_home_inner_01_stronghold",
            ("required_structure", "starting_entity"),
        ),
        _spawn(
            "spawn_self_food",
            0,
            "structure",
            "food_structure",
            "r_self_home",
            (181, 232),
            food_cells,
            "bs_self_home_inner_02_food",
            ("starting_entity",),
        ),
    ]
    worker_cells = ((186, 236), (190, 236), (194, 236), (198, 236), (202, 236))
    for index, cell in enumerate(worker_cells, start=1):
        self_spawns.append(
            _spawn(
                f"spawn_self_worker_{index:02d}",
                0,
                "unit",
                "faction_worker",
                "r_self_home",
                cell,
                (cell,),
                None,
                ("starting_entity", "faction_resolved"),
            )
        )

    spawns: List[Dict[str, Any]] = []
    pairs: List[Dict[str, str]] = []
    for spawn in self_spawns:
        mirror_id = spawn["id"].replace("spawn_self_", "spawn_opponent_", 1)
        spawns.extend((spawn, _mirror_spawn(spawn, mirror_id)))
        pairs.append({"a": spawn["id"], "b": mirror_id})
    return sorted(spawns, key=lambda item: item["id"]), sorted(pairs, key=lambda item: item["a"])


def _slot(
    slot_id: str,
    region_id: str,
    local_slot_id: str,
    anchor: Cell,
    tags: Sequence[str],
) -> Dict[str, Any]:
    return {
        "id": slot_id,
        "region_id": region_id,
        "slot_id": local_slot_id,
        "anchor_cell": list(anchor),
        "position_mt": cell_center_mt(anchor),
        "tags": list(tags),
    }


def _mirror_slot(slot: Mapping[str, Any], mirror_id: str) -> Dict[str, Any]:
    anchor = rotate_cell(tuple(slot["anchor_cell"]))
    return {
        "id": mirror_id,
        "region_id": REGION_MIRROR[str(slot["region_id"])],
        "slot_id": slot["slot_id"],
        "anchor_cell": list(anchor),
        "position_mt": rotate_position(slot["position_mt"]),
        "tags": list(slot["tags"]),
    }


def build_tactical_slots() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    anchors = dict(_region_seed_specs())
    authored_region_ids = (
        "r_self_home",
        "r_self_natural",
        "r_self_west_approach",
        "r_self_east_approach",
        "r_self_west_wild",
        "r_self_east_wild",
        "r_west_neutral",
        "r_west_contested",
    )
    slots: List[Dict[str, Any]] = []
    pairs: List[Dict[str, str]] = []
    for region_id in authored_region_ids:
        anchor = anchors[region_id]
        region_token = region_id.removeprefix("r_")
        for local_slot_id, offset, tags in (
            ("center", (0, 0), ("formation",)),
            ("left_flank", (-4, 1), ("flank",)),
            ("right_flank", (4, 1), ("flank",)),
            ("retreat_edge", (0, 5), ("retreat",)),
        ):
            point = (anchor[0] + offset[0], anchor[1] + offset[1])
            slot_id = f"slot_{region_token}_{local_slot_id}"
            slot = _slot(slot_id, region_id, local_slot_id, point, tags)
            paired_region = REGION_MIRROR[region_id].removeprefix("r_")
            mirror_id = f"slot_{paired_region}_{local_slot_id}"
            slots.extend((slot, _mirror_slot(slot, mirror_id)))
            pairs.append({"a": slot_id, "b": mirror_id})

    center_authored = (
        _slot(
            "slot_center_high_ground_south",
            "r_center",
            "high_ground_south",
            (192, 136),
            ("high_ground", "formation"),
        ),
        _slot(
            "slot_center_west_crossing_south",
            "r_center",
            "west_crossing_south",
            (168, 136),
            ("crossing", "left_flank"),
        ),
        _slot(
            "slot_center_tavern_front_south",
            "r_center",
            "tavern_front_south",
            (192, 132),
            ("shop_front", "tavern"),
        ),
    )
    center_mirror_names = {
        "slot_center_high_ground_south": "slot_center_high_ground_north",
        "slot_center_west_crossing_south": "slot_center_east_crossing_north",
        "slot_center_tavern_front_south": "slot_center_tavern_front_north",
    }
    for slot in center_authored:
        mirror_id = center_mirror_names[slot["id"]]
        slots.extend((slot, _mirror_slot(slot, mirror_id)))
        pairs.append({"a": slot["id"], "b": mirror_id})
    return sorted(slots, key=lambda item: item["id"]), sorted(pairs, key=lambda item: item["a"])


def _base_cell(region_id: str, road: bool, x: int, y: int) -> Dict[str, Any]:
    if x < 4 or y < 4 or x >= WIDTH - 4 or y >= HEIGHT - 4:
        terrain_id = "deep_water"
    elif road:
        terrain_id = "road"
    elif region_id == "r_center":
        terrain_id = "highland"
    else:
        terrain_id = "grass"
    terrain = TERRAIN_CATALOG[terrain_id]
    return {
        "terrain_id": terrain_id,
        "elevation": 1 if region_id == "r_center" else 0,
        "ground_pathable": terrain["ground_pathable"],
        "air_pathable": terrain["air_pathable"],
        "buildable_site_id": None,
        "region_id": region_id,
        "los_block_height": terrain["los_block_height"],
        "destructible_id": None,
    }


def _apply_terrain(cell: MutableMapping[str, Any], terrain_id: str) -> None:
    terrain = TERRAIN_CATALOG[terrain_id]
    cell["terrain_id"] = terrain_id
    cell["ground_pathable"] = terrain["ground_pathable"]
    cell["air_pathable"] = terrain["air_pathable"]
    cell["los_block_height"] = terrain["los_block_height"]


def build_cells(
    region_grid: Sequence[Sequence[str]],
    build_sites: Sequence[Mapping[str, Any]],
    resource_sites: Sequence[Mapping[str, Any]],
    neutral_buildings: Sequence[Mapping[str, Any]],
    destructibles: Sequence[Mapping[str, Any]],
) -> List[List[Dict[str, Any]]]:
    roads = build_road_mask(region_grid)
    cells = [
        [_base_cell(region_grid[y][x], (x, y) in roads, x, y) for x in range(WIDTH)]
        for y in range(HEIGHT)
    ]

    occupied_static: Dict[Cell, str] = {}
    for resource in resource_sites:
        terrain_id = "gold_mine" if resource["kind"] == "gold_mine" else "forest"
        for raw_cell in resource["cells"]:
            cell = tuple(raw_cell)
            if cell in occupied_static:
                raise AssertionError(f"Static overlap at {cell}: {resource['id']}")
            occupied_static[cell] = str(resource["id"])
            _apply_terrain(cells[cell[1]][cell[0]], terrain_id)

    for destructible in destructibles:
        for raw_cell in destructible["cells"]:
            cell = tuple(raw_cell)
            if cell in occupied_static:
                raise AssertionError(f"Static overlap at {cell}: {destructible['id']}")
            occupied_static[cell] = str(destructible["id"])
            _apply_terrain(cells[cell[1]][cell[0]], "forest")
            cells[cell[1]][cell[0]]["destructible_id"] = destructible["id"]

    for building in neutral_buildings:
        for raw_cell in building["footprint_cells"]:
            cell = tuple(raw_cell)
            if cell in occupied_static:
                raise AssertionError(f"Static overlap at {cell}: {building['id']}")
            occupied_static[cell] = str(building["id"])
            _apply_terrain(cells[cell[1]][cell[0]], "neutral_structure")

    seen_build_cells: Dict[Cell, str] = {}
    for site in build_sites:
        for raw_cell in site["footprint_cells"]:
            cell = tuple(raw_cell)
            if cell in occupied_static:
                raise AssertionError(f"Build/static overlap at {cell}: {site['id']}")
            if cell in seen_build_cells:
                raise AssertionError(
                    f"Build-site overlap at {cell}: {site['id']} and {seen_build_cells[cell]}"
                )
            seen_build_cells[cell] = str(site["id"])
            _apply_terrain(cells[cell[1]][cell[0]], "build_pad")
            cells[cell[1]][cell[0]]["buildable_site_id"] = site["id"]
    return cells


def _cell_key(cell: Mapping[str, Any]) -> Tuple[Any, ...]:
    return (
        cell["terrain_id"],
        cell["elevation"],
        cell["ground_pathable"],
        cell["air_pathable"],
        cell["buildable_site_id"],
        cell["region_id"],
        cell["los_block_height"],
        cell["destructible_id"],
    )


def encode_grid(
    cells: Sequence[Sequence[Mapping[str, Any]]], mirror_maps: Mapping[str, Mapping[str, str]]
) -> Tuple[List[List[Any]], Dict[str, Any]]:
    palette_keys = sorted({_cell_key(cell) for row in cells for cell in row})
    key_to_index = {key: index for index, key in enumerate(palette_keys)}
    expanded_palette: List[Dict[str, Any]] = []
    for key in palette_keys:
        entry = {
            "terrain_id": key[0],
            "elevation": key[1],
            "ground_pathable": key[2],
            "air_pathable": key[3],
            "buildable_site_id": key[4],
            "region_id": key[5],
            "los_block_height": key[6],
            "destructible_id": key[7],
        }
        rotated_key = (
            key[0],
            key[1],
            key[2],
            key[3],
            None if key[4] is None else mirror_maps["build_sites"][str(key[4])],
            REGION_MIRROR[str(key[5])],
            key[6],
            None if key[7] is None else mirror_maps["destructibles"][str(key[7])],
        )
        entry["rotated_palette_index"] = key_to_index[rotated_key]
        expanded_palette.append(entry)

    rows: List[List[int]] = []
    for row in cells:
        indices = [key_to_index[_cell_key(cell)] for cell in row]
        runs: List[int] = []
        for index in indices:
            if runs and runs[-2] == index:
                runs[-1] += 1
            else:
                runs.extend((index, 1))
        rows.append(runs)
    palette = [[entry[field] for field in CELL_PALETTE_FIELDS] for entry in expanded_palette]
    return palette, {
        "encoding": "row_rle_palette_v1",
        "width": WIDTH,
        "height": HEIGHT,
        "rows": rows,
    }


def decode_grid(manifest: Mapping[str, Any]) -> List[List[Mapping[str, Any]]]:
    fields = manifest["cell_palette_fields"]
    palette = [dict(zip(fields, entry)) for entry in manifest["cell_palette"]]
    decoded: List[List[Mapping[str, Any]]] = []
    for runs in manifest["grid"]["rows"]:
        row: List[Mapping[str, Any]] = []
        if len(runs) % 2:
            raise AssertionError("Grid RLE rows must contain palette/count pairs")
        for run_index in range(0, len(runs), 2):
            palette_index = runs[run_index]
            count = runs[run_index + 1]
            row.extend([palette[palette_index]] * count)
        decoded.append(row)
    return decoded


def _adjacency_edges() -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    centroids = {region_id: centroid for region_id, centroid, _, _ in REGION_SPECS}
    edges: List[Dict[str, Any]] = []
    edge_id_by_pair: Dict[Tuple[str, str], str] = {}
    for a, b in sorted(_edge_set()):
        dx_mt = (centroids[a][0] - centroids[b][0]) * 1_000
        dy_mt = (centroids[a][1] - centroids[b][1]) * 1_000
        distance_mt = math.isqrt(dx_mt * dx_mt + dy_mt * dy_mt)
        is_choke = "approach" in a or "approach" in b
        edge_id = f"edge_{a.removeprefix('r_')}__{b.removeprefix('r_')}"
        edge_id_by_pair[(a, b)] = edge_id
        edges.append(
            {
                "id": edge_id,
                "a": a,
                "b": b,
                "distance_mt": distance_mt,
                "width_mt": 4_000 if is_choke else 8_000,
                "traversal_layer": "ground",
                "choke_id": f"choke_{edge_id.removeprefix('edge_')}" if is_choke else None,
            }
        )

    pairs: List[Dict[str, str]] = []
    for edge in edges:
        paired_key = tuple(sorted((REGION_MIRROR[edge["a"]], REGION_MIRROR[edge["b"]])))
        pairs.append({"a": edge["id"], "b": edge_id_by_pair[paired_key]})
    unique_pairs = {tuple(sorted((pair["a"], pair["b"]))) for pair in pairs}
    return edges, [{"a": a, "b": b} for a, b in sorted(unique_pairs)]


def _terrain_cost(cell: Mapping[str, Any], diagonal: bool) -> int:
    base = 1_414 if diagonal else 1_000
    basis_points = TERRAIN_CATALOG[str(cell["terrain_id"])]["movement_basis_points"]
    return base * int(basis_points) // 1_000


def shortest_path_cost(
    cells: Sequence[Sequence[Mapping[str, Any]]], start: Cell, goal: Cell
) -> int:
    if not cells[start[1]][start[0]]["ground_pathable"]:
        raise AssertionError(f"Path start is blocked: {start}")
    if not cells[goal[1]][goal[0]]["ground_pathable"]:
        raise AssertionError(f"Path goal is blocked: {goal}")
    frontier: List[Tuple[int, int, int]] = [(0, start[1], start[0])]
    costs: Dict[Cell, int] = {start: 0}
    neighbors = (
        (0, -1),
        (1, -1),
        (1, 0),
        (1, 1),
        (0, 1),
        (-1, 1),
        (-1, 0),
        (-1, -1),
    )
    while frontier:
        cost, y, x = heapq.heappop(frontier)
        if cost != costs[(x, y)]:
            continue
        if (x, y) == goal:
            return cost
        for dx, dy in neighbors:
            next_x, next_y = x + dx, y + dy
            if not (0 <= next_x < WIDTH and 0 <= next_y < HEIGHT):
                continue
            destination = cells[next_y][next_x]
            if not destination["ground_pathable"]:
                continue
            diagonal = dx != 0 and dy != 0
            if diagonal and (
                not cells[y][next_x]["ground_pathable"] or not cells[next_y][x]["ground_pathable"]
            ):
                continue
            next_cost = cost + _terrain_cost(destination, diagonal)
            point = (next_x, next_y)
            if next_cost < costs.get(point, 2**63 - 1):
                costs[point] = next_cost
                heapq.heappush(frontier, (next_cost, next_y, next_x))
    raise AssertionError(f"No static path between {start} and {goal}")


def build_static_path_distances(
    cells: Sequence[Sequence[Mapping[str, Any]]],
) -> Tuple[List[Dict[str, Any]], List[Dict[str, str]]]:
    authored: Sequence[Tuple[str, str, Cell, str, Cell]] = (
        (
            "path_self_home_to_opponent_home",
            "spawn_self_stronghold",
            (192, 229),
            "spawn_opponent_stronghold",
            (191, 26),
        ),
        (
            "path_self_home_to_self_natural",
            "spawn_self_stronghold",
            (192, 229),
            "res_self_natural_gold",
            (212, 169),
        ),
        (
            "path_self_home_to_west_merchant",
            "spawn_self_stronghold",
            (192, 229),
            "neutral_west_merchant",
            (23, 121),
        ),
        (
            "path_self_home_to_west_laboratory",
            "spawn_self_stronghold",
            (192, 229),
            "neutral_west_laboratory",
            (24, 137),
        ),
        (
            "path_self_home_to_center_tavern",
            "spawn_self_stronghold",
            (192, 229),
            "neutral_center_tavern",
            (192, 132),
        ),
        (
            "path_self_home_to_west_contested",
            "spawn_self_stronghold",
            (192, 229),
            "res_west_contested_gold",
            (89, 125),
        ),
        (
            "path_self_home_to_self_natural_camp",
            "spawn_self_stronghold",
            (192, 229),
            "camp_self_natural_medium",
            (192, 169),
        ),
    )
    records: List[Dict[str, Any]] = []
    pairs: List[Dict[str, str]] = []
    for path_id, from_id, from_cell, to_id, to_cell in authored:
        cost = shortest_path_cost(cells, from_cell, to_cell)
        record = {
            "id": path_id,
            "from_id": from_id,
            "to_id": to_id,
            "from_cell": list(from_cell),
            "to_cell": list(to_cell),
            "path_cost_units": cost,
            "distance_mt": cost // 2,
        }
        mirror_id = path_id
        mirror_id = mirror_id.replace("self_home", "opponent_home", 1)
        mirror_id = mirror_id.replace("self_natural", "opponent_natural")
        mirror_id = mirror_id.replace("west_merchant", "east_merchant")
        mirror_id = mirror_id.replace("west_laboratory", "east_laboratory")
        mirror_id = mirror_id.replace("west_contested", "east_contested")
        mirror_from_cell = rotate_cell(from_cell)
        mirror_to_cell = rotate_cell(to_cell)
        if path_id == "path_self_home_to_opponent_home":
            mirror_from_id = to_id
            mirror_to_id = from_id
            mirror_id = "path_opponent_home_to_self_home"
        else:
            mirror_from_id = from_id.replace("self", "opponent", 1)
            mirror_to_id = to_id
            mirror_to_id = mirror_to_id.replace("self", "opponent")
            mirror_to_id = mirror_to_id.replace("west", "east")
        mirror_cost = shortest_path_cost(cells, mirror_from_cell, mirror_to_cell)
        mirror_record = {
            "id": mirror_id,
            "from_id": mirror_from_id,
            "to_id": mirror_to_id,
            "from_cell": list(mirror_from_cell),
            "to_cell": list(mirror_to_cell),
            "path_cost_units": mirror_cost,
            "distance_mt": mirror_cost // 2,
        }
        records.extend((record, mirror_record))
        pairs.append({"a": path_id, "b": mirror_id})
    return sorted(records, key=lambda item: item["id"]), sorted(pairs, key=lambda item: item["a"])


def _region_pairs() -> List[Dict[str, str]]:
    return [
        {"a": "r_self_home", "b": "r_opponent_home"},
        {"a": "r_self_natural", "b": "r_opponent_natural"},
        {"a": "r_self_west_approach", "b": "r_opponent_east_approach"},
        {"a": "r_self_east_approach", "b": "r_opponent_west_approach"},
        {"a": "r_self_west_wild", "b": "r_opponent_east_wild"},
        {"a": "r_self_east_wild", "b": "r_opponent_west_wild"},
        {"a": "r_west_neutral", "b": "r_east_neutral"},
        {"a": "r_west_contested", "b": "r_east_contested"},
        {"a": "r_center", "b": "r_center"},
    ]


def _mirror_map(pairs: Sequence[Mapping[str, str]]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for pair in pairs:
        result[pair["a"]] = pair["b"]
        result[pair["b"]] = pair["a"]
    return result


def build_manifest() -> Dict[str, Any]:
    region_grid = build_region_grid()
    if _raster_region_edges(region_grid) != _edge_set():
        raise AssertionError("Raster region boundaries do not match Appendix C adjacency")

    build_sites, build_pairs = build_build_sites()
    resource_sites, resource_pairs = build_resource_sites()
    neutral_buildings, neutral_pairs = build_neutral_buildings()
    creep_camps, camp_pairs = build_creep_camps()
    destructibles, destructible_pairs = build_destructibles()
    spawns, spawn_pairs = build_spawns()
    tactical_slots, tactical_pairs = build_tactical_slots()
    adjacency_edges, adjacency_pairs = _adjacency_edges()

    cells = build_cells(
        region_grid,
        build_sites,
        resource_sites,
        neutral_buildings,
        destructibles,
    )
    static_distances, distance_pairs = build_static_path_distances(cells)
    mirror_pairs: Dict[str, List[Dict[str, str]]] = {
        "regions": _region_pairs(),
        "adjacency_edges": adjacency_pairs,
        "tactical_slots": tactical_pairs,
        "build_sites": build_pairs,
        "resource_sites": resource_pairs,
        "creep_camps": camp_pairs,
        "neutral_buildings": neutral_pairs,
        "destructibles": destructible_pairs,
        "spawns": spawn_pairs,
        "static_path_distances": distance_pairs,
    }
    mirror_maps = {category: _mirror_map(pairs) for category, pairs in mirror_pairs.items()}
    palette, encoded_grid = encode_grid(cells, mirror_maps)

    source_path = Path(__file__).resolve()
    source_sha256 = hashlib.sha256(source_path.read_bytes()).hexdigest()
    manifest: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "map_id": MAP_ID,
        "display_name": "Crossroads Duel",
        "ruleset_id": "duel-rules-v1",
        "description": (
            "Authoritative 17-region, 180-degree rotationally symmetric launch map for "
            "mirrored LLM RTS evaluation."
        ),
        "coordinate_system": {
            "unit": "milli_tile",
            "cell_size_mt": CELL_SIZE_MT,
            "width_cells": WIDTH,
            "height_cells": HEIGHT,
            "bounds_mt": {"min_inclusive": [0, 0], "max_exclusive": [192_000, 128_000]},
            "cell_origin": "north_west_minimum_xy",
            "cell_center_offset_mt": [250, 250],
            "review_tile_size_mt": 1_000,
        },
        "rotation_transform": {
            "id": "rotation_180_exact",
            "kind": "rotation_180",
            "self_inverse": True,
            "world_formula": ["191999-x_mt", "127999-y_mt"],
            "cell_formula": ["383-cell_x", "255-cell_y"],
            "review_tile_formula": ["192-tile_x", "128-tile_y"],
            "world_max_inclusive_mt": list(WORLD_MAX),
            "cell_max_inclusive": list(CELL_MAX),
        },
        "terrain_catalog": {key: dict(value) for key, value in TERRAIN_CATALOG.items()},
        "footprint_classes": {
            key: {"width_cells": value[0], "height_cells": value[1]}
            for key, value in FOOTPRINT_CLASSES.items()
        },
        "cell_palette_fields": list(CELL_PALETTE_FIELDS),
        "cell_palette": palette,
        "grid": encoded_grid,
        "regions": build_regions(region_grid),
        "adjacency_edges": adjacency_edges,
        "tactical_slots": tactical_slots,
        "build_sites": build_sites,
        "resource_sites": resource_sites,
        "creep_camps": creep_camps,
        "neutral_buildings": neutral_buildings,
        "destructibles": destructibles,
        "spawns": spawns,
        "static_path_distances": static_distances,
        "mirror_pairs": mirror_pairs,
        "generation": {
            "script": "scripts/build_duel_map.py",
            "algorithm_version": ALGORITHM_VERSION,
            "python_minimum": "3.9",
            "canonical_json": "utf8_sorted_keys_compact_lf",
            "authored_half": "rows_128_through_255_plus_west_centerline_sites",
            "source_sha256": source_sha256,
        },
    }
    validate_manifest(manifest)
    return manifest


def _index(items: Sequence[Mapping[str, Any]]) -> Dict[str, Mapping[str, Any]]:
    return {str(item["id"]): item for item in items}


def validate_manifest(manifest: Mapping[str, Any]) -> None:
    if manifest["grid"]["width"] != WIDTH or manifest["grid"]["height"] != HEIGHT:
        raise AssertionError("Incorrect exact grid dimensions")
    decoded = decode_grid(manifest)
    if len(decoded) != HEIGHT or any(len(row) != WIDTH for row in decoded):
        raise AssertionError("Grid RLE is not a lossless 384 x 256 cell stream")

    build_mirror = _mirror_map(manifest["mirror_pairs"]["build_sites"])
    destructible_mirror = _mirror_map(manifest["mirror_pairs"]["destructibles"])
    for y in range(HEIGHT):
        for x in range(WIDTH):
            cell = decoded[y][x]
            paired = decoded[CELL_MAX[1] - y][CELL_MAX[0] - x]
            if cell["terrain_id"] != paired["terrain_id"]:
                raise AssertionError(f"Terrain mirror mismatch at {(x, y)}")
            for field in (
                "elevation",
                "ground_pathable",
                "air_pathable",
                "los_block_height",
            ):
                if cell[field] != paired[field]:
                    raise AssertionError(f"{field} mirror mismatch at {(x, y)}")
            if REGION_MIRROR[cell["region_id"]] != paired["region_id"]:
                raise AssertionError(f"Region mirror mismatch at {(x, y)}")
            expected_site = (
                None
                if cell["buildable_site_id"] is None
                else build_mirror[cell["buildable_site_id"]]
            )
            if expected_site != paired["buildable_site_id"]:
                raise AssertionError(f"Build-site mirror mismatch at {(x, y)}")
            expected_destructible = (
                None
                if cell["destructible_id"] is None
                else destructible_mirror[cell["destructible_id"]]
            )
            if expected_destructible != paired["destructible_id"]:
                raise AssertionError(f"Destructible mirror mismatch at {(x, y)}")

    for site in manifest["build_sites"]:
        for exit_cell in site["production_exit_cells"]:
            x, y = exit_cell
            if not (0 <= x < WIDTH and 0 <= y < HEIGHT):
                raise AssertionError(f"Out-of-bounds exit for {site['id']}")
            if not decoded[y][x]["ground_pathable"]:
                raise AssertionError(f"Blocked production exit for {site['id']}: {(x, y)}")

    path_pairs = manifest["mirror_pairs"]["static_path_distances"]
    paths = _index(manifest["static_path_distances"])
    for pair in path_pairs:
        if paths[pair["a"]]["path_cost_units"] != paths[pair["b"]]["path_cost_units"]:
            raise AssertionError(f"Unequal mirror path: {pair}")


def canonical_json_bytes(manifest: Mapping[str, Any]) -> bytes:
    return (
        json.dumps(manifest, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def parse_args() -> argparse.Namespace:
    repository_root = Path(__file__).resolve().parents[1]
    default_output = repository_root / "game" / "duel_protocol" / "maps" / f"{MAP_ID}.json"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=default_output)
    parser.add_argument(
        "--check",
        action="store_true",
        help="Fail when the target does not already equal deterministic generated bytes.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    payload = canonical_json_bytes(build_manifest())
    digest = hashlib.sha256(payload).hexdigest()
    if args.check:
        if not args.output.exists() or args.output.read_bytes() != payload:
            raise SystemExit(f"stale generated map: {args.output}")
    else:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(payload)
    print(f"{args.output} sha256={digest} bytes={len(payload)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
