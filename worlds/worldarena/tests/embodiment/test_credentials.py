from genesis_arena.embodiment.credentials import (
    CredentialError,
    InMemoryCredentialStore,
    SessionCredential,
)


def test_session_credentials_are_redacted_and_erased() -> None:
    secret = "sk-session-only-test-value"
    credential = SessionCredential(secret)
    assert secret not in repr(credential)
    assert credential.reveal() == secret
    credential.close()
    assert credential.closed
    try:
        credential.reveal()
    except CredentialError as error:
        assert secret not in str(error)
    else:
        raise AssertionError("closed credential was revealed")


def test_store_discards_every_credential_for_episode() -> None:
    store = InMemoryCredentialStore()
    first = store.put("ep_credential", "openai", "first-secret")
    second = store.put("ep_credential", "anthropic", "second-secret")
    assert len(store) == 2
    assert store.get(first).reveal() == "first-secret"
    assert store.get(second).reveal() == "second-secret"
    store.discard_episode("ep_credential")
    assert len(store) == 0
    for ref in (first, second):
        try:
            store.get(ref)
        except CredentialError:
            pass
        else:
            raise AssertionError("discarded credential remained available")
