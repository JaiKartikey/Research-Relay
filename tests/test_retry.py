import pytest

from app.retry import with_retry


async def test_retry_succeeds_after_one_failure():
    calls = {"n": 0}

    async def flaky():
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("temporary error")
        return "ok"

    assert await with_retry(flaky, max_retries=3, delay=0) == "ok"
    assert calls["n"] == 2


async def test_retry_gives_up_and_raises_last_error():
    async def always_fails():
        raise ValueError("still broken")

    with pytest.raises(ValueError):
        await with_retry(always_fails, max_retries=2, delay=0)
