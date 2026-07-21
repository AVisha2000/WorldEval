import pytest
from genesis_arena.embodiment.scratchpad import EpisodeScratchpad, ScratchpadError


def test_scratchpad_enforces_utf8_bytes_not_codepoints() -> None:
    scratchpad = EpisodeScratchpad()
    scratchpad.set("é" * 1024)
    assert len(scratchpad.utf8) == 2048
    with pytest.raises(ScratchpadError, match="2048 UTF-8 bytes"):
        scratchpad.set("é" * 1025)


def test_scratchpad_is_episode_only_and_resettable() -> None:
    scratchpad = EpisodeScratchpad()
    scratchpad.set("working memory")
    scratchpad.reset()
    assert scratchpad.text == ""
    scratchpad.close()
    with pytest.raises(ScratchpadError, match="closed"):
        _ = scratchpad.utf8
