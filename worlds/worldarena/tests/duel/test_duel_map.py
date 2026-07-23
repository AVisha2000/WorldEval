from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from collections import Counter, deque
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Sequence, Set, Tuple

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
MAP_PATH = REPOSITORY_ROOT / "game" / "duel_protocol" / "maps" / "crossroads-duel-v1.json"
GENERATOR_PATH = REPOSITORY_ROOT / "scripts" / "build_duel_map.py"
WIDTH = 384
HEIGHT = 256
Cell = Tuple[int, int]


def load_manifest() -> Dict[str, Any]:
    return json.loads(MAP_PATH.read_text(encoding="utf-8"))


def expand_indices(manifest: Mapping[str, Any]) -> List[List[int]]:
    rows: List[List[int]] = []
    for encoded_row in manifest["grid"]["rows"]:
        row: List[int] = []
        assert len(encoded_row) % 2 == 0
        for run_index in range(0, len(encoded_row), 2):
            palette_index, count = encoded_row[run_index : run_index + 2]
            row.extend([palette_index] * count)
        rows.append(row)
    return rows


def decode_palette(manifest: Mapping[str, Any]) -> List[Mapping[str, Any]]:
    fields = manifest["cell_palette_fields"]
    return [dict(zip(fields, entry)) for entry in manifest["cell_palette"]]


def expand_cells(manifest: Mapping[str, Any]) -> List[List[Mapping[str, Any]]]:
    palette = decode_palette(manifest)
    return [[palette[index] for index in row] for row in expand_indices(manifest)]


def rotate_cell(cell: Sequence[int]) -> Cell:
    return 383 - cell[0], 255 - cell[1]


def rotate_position(position: Sequence[int]) -> Tuple[int, int]:
    return 191_999 - position[0], 127_999 - position[1]


def pair_map(pairs: Iterable[Mapping[str, str]]) -> Dict[str, str]:
    result: Dict[str, str] = {}
    for pair in pairs:
        assert pair["a"] not in result or result[pair["a"]] == pair["b"]
        assert pair["b"] not in result or result[pair["b"]] == pair["a"]
        result[pair["a"]] = pair["b"]
        result[pair["b"]] = pair["a"]
    return result


def index(items: Iterable[Mapping[str, Any]]) -> Dict[str, Mapping[str, Any]]:
    return {item["id"]: item for item in items}


def cell_set(cells: Iterable[Sequence[int]]) -> Set[Cell]:
    return {tuple(cell) for cell in cells}


def rotated_set(cells: Iterable[Sequence[int]]) -> Set[Cell]:
    return {rotate_cell(cell) for cell in cells}


def test_grid_is_exactly_384_by_256_and_losslessly_explicit() -> None:
    manifest = load_manifest()
    grid = manifest["grid"]
    palette = manifest["cell_palette"]

    assert grid["encoding"] == "row_rle_palette_v1"
    assert (grid["width"], grid["height"]) == (WIDTH, HEIGHT)
    assert len(grid["rows"]) == HEIGHT
    assert all(len(row) % 2 == 0 for row in grid["rows"])
    assert all(sum(row[1::2]) == WIDTH for row in grid["rows"])
    assert all(count > 0 for row in grid["rows"] for count in row[1::2])
    assert all(0 <= index < len(palette) for row in grid["rows"] for index in row[0::2])

    required_fields = (
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
    assert manifest["cell_palette_fields"] == list(required_fields)
    assert all(len(entry) == len(required_fields) for entry in palette)
    assert sum(sum(row[1::2]) for row in grid["rows"]) == 98_304


def test_every_cell_has_exact_180_degree_semantics() -> None:
    manifest = load_manifest()
    palette = decode_palette(manifest)
    indices = expand_indices(manifest)
    region_mirror = pair_map(manifest["mirror_pairs"]["regions"])
    build_mirror = pair_map(manifest["mirror_pairs"]["build_sites"])
    destructible_mirror = pair_map(manifest["mirror_pairs"]["destructibles"])

    for palette_index, entry in enumerate(palette):
        rotated_index = entry["rotated_palette_index"]
        assert palette[rotated_index]["rotated_palette_index"] == palette_index

    for y, row in enumerate(indices):
        for x, palette_index in enumerate(row):
            paired_index = indices[255 - y][383 - x]
            assert paired_index == palette[palette_index]["rotated_palette_index"]
            cell = palette[palette_index]
            paired = palette[paired_index]
            for unchanged_field in (
                "terrain_id",
                "elevation",
                "ground_pathable",
                "air_pathable",
                "los_block_height",
            ):
                assert cell[unchanged_field] == paired[unchanged_field]
            assert paired["region_id"] == region_mirror[cell["region_id"]]
            expected_build_site = (
                None
                if cell["buildable_site_id"] is None
                else build_mirror[cell["buildable_site_id"]]
            )
            assert paired["buildable_site_id"] == expected_build_site
            expected_destructible = (
                None
                if cell["destructible_id"] is None
                else destructible_mirror[cell["destructible_id"]]
            )
            assert paired["destructible_id"] == expected_destructible


def test_region_graph_is_exact_symmetric_and_matches_cell_boundaries() -> None:
    manifest = load_manifest()
    regions = index(manifest["regions"])
    edges = {tuple(sorted((edge["a"], edge["b"]))) for edge in manifest["adjacency_edges"]}
    assert len(edges) == len(manifest["adjacency_edges"]) == 32

    expected_region_ids = {
        "r_self_home",
        "r_self_natural",
        "r_self_west_approach",
        "r_self_east_approach",
        "r_self_west_wild",
        "r_self_east_wild",
        "r_west_neutral",
        "r_west_contested",
        "r_center",
        "r_east_contested",
        "r_east_neutral",
        "r_opponent_west_wild",
        "r_opponent_east_wild",
        "r_opponent_west_approach",
        "r_opponent_east_approach",
        "r_opponent_natural",
        "r_opponent_home",
    }
    assert set(regions) == expected_region_ids

    region_mirror = pair_map(manifest["mirror_pairs"]["regions"])
    for a, b in edges:
        assert tuple(sorted((region_mirror[a], region_mirror[b]))) in edges

    for region_id, region in regions.items():
        paired = regions[region_mirror[region_id]]
        x, y = region["review_centroid_tile"]
        assert paired["review_centroid_tile"] == [192 - x, 128 - y]
        assert paired["elevation"] == region["elevation"]

    cells = expand_cells(manifest)
    raster_edges: Set[Tuple[str, str]] = set()
    cell_counts: Counter[str] = Counter()
    for y in range(HEIGHT):
        for x in range(WIDTH):
            here = cells[y][x]["region_id"]
            cell_counts[here] += 1
            if x + 1 < WIDTH and cells[y][x + 1]["region_id"] != here:
                raster_edges.add(tuple(sorted((here, cells[y][x + 1]["region_id"]))))
            if y + 1 < HEIGHT and cells[y + 1][x]["region_id"] != here:
                raster_edges.add(tuple(sorted((here, cells[y + 1][x]["region_id"]))))
    assert raster_edges == edges
    assert cell_counts == Counter(
        {region_id: region["cell_count"] for region_id, region in regions.items()}
    )


def test_all_authored_objects_are_exact_rotational_pairs() -> None:
    manifest = load_manifest()
    region_mirror = pair_map(manifest["mirror_pairs"]["regions"])

    slots = index(manifest["tactical_slots"])
    for pair in manifest["mirror_pairs"]["tactical_slots"]:
        a, b = slots[pair["a"]], slots[pair["b"]]
        assert rotate_cell(a["anchor_cell"]) == tuple(b["anchor_cell"])
        assert rotate_position(a["position_mt"]) == tuple(b["position_mt"])
        assert region_mirror[a["region_id"]] == b["region_id"]
        assert a["slot_id"] == b["slot_id"]

    build_sites = index(manifest["build_sites"])
    for pair in manifest["mirror_pairs"]["build_sites"]:
        a, b = build_sites[pair["a"]], build_sites[pair["b"]]
        assert rotated_set(a["footprint_cells"]) == cell_set(b["footprint_cells"])
        assert [rotate_cell(cell) for cell in a["production_exit_cells"]] == [
            tuple(cell) for cell in b["production_exit_cells"]
        ]
        assert region_mirror[a["region_id"]] == b["region_id"]
        assert a["allowed_footprint_class"] == b["allowed_footprint_class"]
        assert a["category"] == b["category"]

    resources = index(manifest["resource_sites"])
    for pair in manifest["mirror_pairs"]["resource_sites"]:
        a, b = resources[pair["a"]], resources[pair["b"]]
        assert rotate_cell(a["anchor_cell"]) == tuple(b["anchor_cell"])
        assert rotate_cell(a["approach_cell"]) == tuple(b["approach_cell"])
        assert rotate_position(a["position_mt"]) == tuple(b["position_mt"])
        assert rotated_set(a["cells"]) == cell_set(b["cells"])
        assert a["initial_amount"] == b["initial_amount"]
        assert region_mirror[a["region_id"]] == b["region_id"]

    camps = index(manifest["creep_camps"])
    for pair in manifest["mirror_pairs"]["creep_camps"]:
        a, b = camps[pair["a"]], camps[pair["b"]]
        assert rotate_cell(a["anchor_cell"]) == tuple(b["anchor_cell"])
        assert rotate_position(a["position_mt"]) == tuple(b["position_mt"])
        assert region_mirror[a["region_id"]] == b["region_id"]
        assert a["tier"] == b["tier"]
        assert a["total_level"] == b["total_level"]
        assert len(a["member_spawns"]) == len(b["member_spawns"])
        for member_a, member_b in zip(a["member_spawns"], b["member_spawns"]):
            assert member_a["neutral_id"] == member_b["neutral_id"]
            assert member_a["level"] == member_b["level"]
            assert rotate_cell(member_a["cell"]) == tuple(member_b["cell"])

    buildings = index(manifest["neutral_buildings"])
    for pair in manifest["mirror_pairs"]["neutral_buildings"]:
        a, b = buildings[pair["a"]], buildings[pair["b"]]
        assert rotated_set(a["footprint_cells"]) == cell_set(b["footprint_cells"])
        assert rotated_set(a["approach_cells"]) == cell_set(b["approach_cells"])
        assert region_mirror[a["region_id"]] == b["region_id"]
        if pair["a"] != pair["b"]:
            assert rotate_position(a["position_mt"]) == tuple(b["position_mt"])

    destructibles = index(manifest["destructibles"])
    for pair in manifest["mirror_pairs"]["destructibles"]:
        a, b = destructibles[pair["a"]], destructibles[pair["b"]]
        assert rotated_set(a["cells"]) == cell_set(b["cells"])
        assert region_mirror[a["region_id"]] == b["region_id"]
        assert [region_mirror[value] for value in a["opens_route_between"]] == b[
            "opens_route_between"
        ]

    spawns = index(manifest["spawns"])
    for pair in manifest["mirror_pairs"]["spawns"]:
        a, b = spawns[pair["a"]], spawns[pair["b"]]
        assert rotated_set(a["footprint_cells"]) == cell_set(b["footprint_cells"])
        assert rotate_position(a["position_mt"]) == tuple(b["position_mt"])
        assert region_mirror[a["region_id"]] == b["region_id"]
        assert (a["seat"], b["seat"]) == (0, 1)
        if a["kind"] == "unit":
            assert rotate_cell(a["anchor_cell"]) == tuple(b["anchor_cell"])
        if a["build_site_id"] is not None:
            assert cell_set(a["footprint_cells"]) == cell_set(
                build_sites[a["build_site_id"]]["footprint_cells"]
            )
            assert cell_set(b["footprint_cells"]) == cell_set(
                build_sites[b["build_site_id"]]["footprint_cells"]
            )


def breadth_first_distances(
    cells: Sequence[Sequence[Mapping[str, Any]]], start: Cell
) -> Dict[Cell, int]:
    assert cells[start[1]][start[0]]["ground_pathable"]
    distances = {start: 0}
    queue = deque([start])
    while queue:
        x, y = queue.popleft()
        for dx, dy in ((0, -1), (1, 0), (0, 1), (-1, 0)):
            neighbor = (x + dx, y + dy)
            if not (0 <= neighbor[0] < WIDTH and 0 <= neighbor[1] < HEIGHT):
                continue
            if neighbor in distances:
                continue
            if not cells[neighbor[1]][neighbor[0]]["ground_pathable"]:
                continue
            distances[neighbor] = distances[(x, y)] + 1
            queue.append(neighbor)
    return distances


def test_starts_are_connected_with_equal_mirrored_path_distances() -> None:
    manifest = load_manifest()
    cells = expand_cells(manifest)
    self_start = (192, 229)
    opponent_start = rotate_cell(self_start)
    self_distances = breadth_first_distances(cells, self_start)
    opponent_distances = breadth_first_distances(cells, opponent_start)

    assert opponent_start in self_distances
    assert len(self_distances) == len(opponent_distances)
    for point in (
        (212, 169),
        (23, 121),
        (24, 137),
        (192, 132),
        (89, 125),
        (192, 169),
    ):
        assert point in self_distances
        assert rotate_cell(point) in opponent_distances
        assert self_distances[point] == opponent_distances[rotate_cell(point)]

    paths = index(manifest["static_path_distances"])
    for pair in manifest["mirror_pairs"]["static_path_distances"]:
        a, b = paths[pair["a"]], paths[pair["b"]]
        assert rotate_cell(a["from_cell"]) == tuple(b["from_cell"])
        assert rotate_cell(a["to_cell"]) == tuple(b["to_cell"])
        assert a["path_cost_units"] == b["path_cost_units"]
        assert a["distance_mt"] == b["distance_mt"]


def test_site_counts_resources_and_ids_are_complete() -> None:
    manifest = load_manifest()
    ids: Set[str] = set()
    id_categories = (
        "regions",
        "adjacency_edges",
        "tactical_slots",
        "build_sites",
        "resource_sites",
        "creep_camps",
        "neutral_buildings",
        "destructibles",
        "spawns",
        "static_path_distances",
    )
    for category in id_categories:
        for item in manifest[category]:
            assert item["id"] not in ids
            ids.add(item["id"])
    for camp in manifest["creep_camps"]:
        for member in camp["member_spawns"]:
            assert member["id"] not in ids
            ids.add(member["id"])

    paired_categories = {
        "regions": "regions",
        "adjacency_edges": "adjacency_edges",
        "tactical_slots": "tactical_slots",
        "build_sites": "build_sites",
        "resource_sites": "resource_sites",
        "creep_camps": "creep_camps",
        "neutral_buildings": "neutral_buildings",
        "destructibles": "destructibles",
        "spawns": "spawns",
        "static_path_distances": "static_path_distances",
    }
    for pair_category, object_category in paired_categories.items():
        assert set(pair_map(manifest["mirror_pairs"][pair_category])) == set(
            index(manifest[object_category])
        )

    site_counts = Counter((site["region_id"], site["category"]) for site in manifest["build_sites"])
    for home in ("r_self_home", "r_opponent_home"):
        assert sum(count for (region, _), count in site_counts.items() if region == home) == 18
        assert site_counts[(home, "inner")] == 6
        assert site_counts[(home, "economy")] == 4
        assert site_counts[(home, "outer")] == 4
        assert site_counts[(home, "tower")] == 2
        assert site_counts[(home, "choke")] == 2
    for natural in ("r_self_natural", "r_opponent_natural"):
        assert sum(count for (region, _), count in site_counts.items() if region == natural) == 8
        assert site_counts[(natural, "hall")] == 1
        assert site_counts[(natural, "economy")] == 3
        assert site_counts[(natural, "tower")] == 2
        assert site_counts[(natural, "outer")] == 2
    for contested in ("r_west_contested", "r_east_contested"):
        assert sum(count for (region, _), count in site_counts.items() if region == contested) == 5

    assert Counter(camp["tier"] for camp in manifest["creep_camps"]) == {
        "easy": 8,
        "medium": 6,
        "hard": 2,
    }
    assert Counter(building["building_type"] for building in manifest["neutral_buildings"]) == {
        "merchant": 2,
        "laboratory": 2,
        "tavern": 1,
    }
    resources = index(manifest["resource_sites"])
    assert resources["res_self_home_gold"]["initial_amount"] == 12_000
    assert resources["res_opponent_home_gold"]["initial_amount"] == 12_000
    assert resources["res_self_home_forest"]["initial_amount"] >= 3_000
    assert resources["res_opponent_home_forest"]["initial_amount"] >= 3_000
    assert resources["res_self_natural_gold"]["initial_amount"] == 9_000
    assert resources["res_opponent_natural_gold"]["initial_amount"] == 9_000
    assert resources["res_west_contested_gold"]["initial_amount"] == 6_000
    assert resources["res_east_contested_gold"]["initial_amount"] == 6_000


def test_sites_occupants_exits_and_static_cells_are_fully_authored() -> None:
    manifest = load_manifest()
    cells = expand_cells(manifest)
    build_sites = index(manifest["build_sites"])
    spawns = index(manifest["spawns"])

    footprint_cells: Set[Cell] = set()
    for site in build_sites.values():
        for raw_cell in site["footprint_cells"]:
            point = tuple(raw_cell)
            assert point not in footprint_cells
            footprint_cells.add(point)
            authored_cell = cells[point[1]][point[0]]
            assert authored_cell["buildable_site_id"] == site["id"]
            assert authored_cell["region_id"] == site["region_id"]
            assert authored_cell["ground_pathable"]
        for raw_exit in site["production_exit_cells"]:
            exit_cell = tuple(raw_exit)
            assert 0 <= exit_cell[0] < WIDTH and 0 <= exit_cell[1] < HEIGHT
            assert cells[exit_cell[1]][exit_cell[0]]["ground_pathable"]
        occupant_id = site["starts_occupied_by"]
        if occupant_id is not None:
            assert spawns[occupant_id]["build_site_id"] == site["id"]

    for resource in manifest["resource_sites"]:
        expected_terrain = "gold_mine" if resource["kind"] == "gold_mine" else "forest"
        for raw_cell in resource["cells"]:
            x, y = raw_cell
            assert cells[y][x]["terrain_id"] == expected_terrain
            assert cells[y][x]["region_id"] == resource["region_id"]
            assert not cells[y][x]["ground_pathable"]
        approach_x, approach_y = resource["approach_cell"]
        assert cells[approach_y][approach_x]["ground_pathable"]

    for building in manifest["neutral_buildings"]:
        for x, y in building["footprint_cells"]:
            assert cells[y][x]["terrain_id"] == "neutral_structure"
            assert cells[y][x]["region_id"] == building["region_id"]
            assert not cells[y][x]["ground_pathable"]
        assert any(cells[y][x]["ground_pathable"] for x, y in building["approach_cells"])

    for destructible in manifest["destructibles"]:
        for x, y in destructible["cells"]:
            assert cells[y][x]["destructible_id"] == destructible["id"]
            assert cells[y][x]["terrain_id"] == "forest"
            assert cells[y][x]["region_id"] == destructible["region_id"]

    for camp in manifest["creep_camps"]:
        for raw_cell in [camp["anchor_cell"]] + [
            member["cell"] for member in camp["member_spawns"]
        ]:
            x, y = raw_cell
            assert cells[y][x]["region_id"] == camp["region_id"]
            assert cells[y][x]["ground_pathable"]

    for slot in manifest["tactical_slots"]:
        x, y = slot["anchor_cell"]
        assert cells[y][x]["region_id"] == slot["region_id"]
        assert cells[y][x]["ground_pathable"]


def test_generated_artifact_is_deterministic_and_current(tmp_path: Path) -> None:
    output = tmp_path / "crossroads-duel-v1.json"
    completed = subprocess.run(
        [sys.executable, str(GENERATOR_PATH), "--output", str(output)],
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    assert "sha256=" in completed.stdout
    assert output.read_bytes() == MAP_PATH.read_bytes()

    manifest = load_manifest()
    assert (
        manifest["generation"]["source_sha256"]
        == hashlib.sha256(GENERATOR_PATH.read_bytes()).hexdigest()
    )
    subprocess.run(
        [sys.executable, str(GENERATOR_PATH), "--output", str(output), "--check"],
        cwd=REPOSITORY_ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
