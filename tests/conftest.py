"""
Shared test setup.

The tests never touch AWS, Redis, Postgres or a real LLM:
- sentence_transformers is replaced by a tiny fake model (no PyTorch download)
- Redis is replaced by fakeredis (an in-memory Redis)
- LLM / Bedrock calls are replaced with monkeypatch inside each test
"""
import sys
import types
from types import SimpleNamespace

import numpy as np
import pytest
import fakeredis.aioredis


# ── 1. Fake sentence_transformers (must run before any app module is imported) ──
class FakeSentenceTransformer:
    def __init__(self, name):
        pass

    def encode(self, text):
        # Same text -> same vector. Good enough to test the cache logic.
        vec = np.zeros(384)
        for i, ch in enumerate(text.lower()):
            vec[(ord(ch) + i) % 384] += 1.0
        return vec


fake_module = types.ModuleType("sentence_transformers")
fake_module.SentenceTransformer = FakeSentenceTransformer
sys.modules["sentence_transformers"] = fake_module


# ── 2. A fake Config with only the values the code reads ──
@pytest.fixture
def config():
    return SimpleNamespace(
        api_key="test-key",
        aws_region="ap-southeast-2",
        bedrock_guardrail_id="gr-test",
        bedrock_guardrail_version="1",
        tensorzero_url="http://tensorzero.test",
        cache_ttl=60,
        cache_similarity_threshold=0.85,
        session_ttl=60,
        session_max_messages=3,
        stream_key="research:jobs",
        consumer_group="workers",
        consumer_name="test-worker",
        result_ttl=60,
        agent_report_truncate=3000,
        agent_max_iterations=2,
        llm_max_retries=2,
        llm_retry_delay=0,
    )


# ── 3. In-memory Redis ──
@pytest.fixture
async def redis():
    client = fakeredis.aioredis.FakeRedis(decode_responses=True)
    yield client
    await client.aclose()
