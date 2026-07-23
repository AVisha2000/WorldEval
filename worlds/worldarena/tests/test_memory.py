from __future__ import annotations

from genesis_arena.memory import MemoryStore


def test_memory_is_deduplicated_and_bounded(tmp_path) -> None:
    store = MemoryStore(tmp_path)
    store.append("sol", "Crystal discovered north of camp.")
    store.append("sol", "Crystal discovered north of camp.")
    for index in range(20):
        store.append("sol", f"Strategic fact {index}")

    facts = store.load("sol")

    assert len(facts) == store.MAX_FACTS
    assert facts[-1] == "Strategic fact 19"
