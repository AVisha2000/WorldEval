from __future__ import annotations

from genesis_arena.duel import AudienceEventSequencer, OpaqueAliasBook


def test_entity_aliases_are_stable_observer_specific_and_not_preallocated() -> None:
    secret = bytes(range(32))
    player_zero = OpaqueAliasBook(secret, 0)
    player_one = OpaqueAliasBook(secret, 1)

    assert player_zero.known_alias("internal_enemy_7") is None
    alias_zero = player_zero.observe("internal_enemy_7")
    alias_one = player_one.observe("internal_enemy_7")
    assert alias_zero.startswith("e_")
    assert "internal" not in alias_zero
    assert alias_zero != alias_one
    assert player_zero.observe("internal_enemy_7") == alias_zero
    assert player_zero.resolve_known(alias_zero) == "internal_enemy_7"

    assert player_zero.tombstone("internal_enemy_7") == alias_zero
    assert player_zero.is_tombstoned(alias_zero)
    assert player_zero.observe("internal_enemy_7") == alias_zero


def test_hidden_events_do_not_create_sequence_gaps_for_other_player() -> None:
    events = AudienceEventSequencer()
    first_zero = events.emit("player_0", tick=1, kind="visible", payload={})
    hidden_one = events.emit("player_1", tick=2, kind="private", payload={})
    omniscient = events.emit("omniscient", tick=2, kind="all_state", payload={})
    second_zero = events.emit("player_0", tick=3, kind="visible", payload={})

    assert (first_zero.event_seq, second_zero.event_seq) == (1, 2)
    assert hidden_one.event_seq == 1
    assert omniscient.event_seq == 1
