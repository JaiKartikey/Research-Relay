"""Cache, session memory and job queue, all on an in-memory fake Redis."""
from app.cache import cache_get, cache_set
from app.memory import session_add, session_get
from app.queue import ack_job, consume_jobs, ensure_group, get_result, push_job, set_result


def _text(value):
    return value.decode() if isinstance(value, bytes) else value


async def test_cache_returns_saved_report_for_same_topic(redis, config):
    await cache_set(redis, config, "quantum computing", "REPORT")
    assert await cache_get(redis, config, "quantum computing") == "REPORT"


async def test_cache_miss_for_unrelated_topic(redis, config):
    await cache_set(redis, config, "quantum computing", "REPORT")
    assert await cache_get(redis, config, "zzzz") is None


async def test_session_keeps_only_last_messages(redis, config):
    for i in range(5):
        await session_add(redis, config, "s1", "user", f"msg {i}")
    messages = await session_get(redis, "s1")
    assert [m["content"] for m in messages] == ["msg 2", "msg 3", "msg 4"]  # session_max_messages = 3


async def test_job_goes_through_queue(redis, config):
    await ensure_group(redis, config)
    job_id = await push_job(redis, config, "AI chips", "s1", "text")

    jobs = await consume_jobs(redis, config)
    # fakeredis returns stream data as bytes (real Redis with decode_responses gives str)
    data = {_text(k): _text(v) for k, v in jobs[0]["data"].items()}
    assert data["job_id"] == job_id
    assert data["topic"] == "AI chips"
    await ack_job(redis, config, jobs[0]["msg_id"])


async def test_result_round_trip(redis, config):
    assert await get_result(redis, config, "job-1") is None
    await set_result(redis, config, "job-1", {"status": "done", "report": "hi"})
    assert (await get_result(redis, config, "job-1"))["status"] == "done"
