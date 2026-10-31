from app import agents
from app.agents import CriticAgent, ResearchState, build_graph


def fake_llm(critic_answer):
    """Replaces the real TensorZero call. Returns a canned answer per agent."""
    async def _fake(config, function_name, message):
        if message.startswith("Review this report"):
            return critic_answer
        if function_name == "report_write":
            return "## Executive Summary\nFake report"
        return "- fact one\n- fact two"
    return _fake


def empty_state(topic="AI chips"):
    return ResearchState(
        topic=topic, session_id="s1", session_history=[], ltm_context="",
        search_results=[], summaries=[], report="", verified=False, error="", iterations=0,
    )


async def test_critic_yes_means_verified(monkeypatch, config):
    monkeypatch.setattr(agents, "_tz_call", fake_llm("YES, looks good"))
    assert await CriticAgent(config).run("report") is True


async def test_critic_no_means_not_verified(monkeypatch, config):
    monkeypatch.setattr(agents, "_tz_call", fake_llm("NO, missing data"))
    assert await CriticAgent(config).run("report") is False


async def test_relay_finishes_in_one_pass_when_critic_approves(monkeypatch, config):
    monkeypatch.setattr(agents, "_tz_call", fake_llm("YES"))
    final = await build_graph(config).ainvoke(empty_state())
    assert final["verified"] is True
    assert final["iterations"] == 1
    assert "Executive Summary" in final["report"]


async def test_relay_stops_at_max_iterations_when_critic_rejects(monkeypatch, config):
    monkeypatch.setattr(agents, "_tz_call", fake_llm("NO"))
    final = await build_graph(config).ainvoke(empty_state())
    assert final["verified"] is False
    assert final["iterations"] == config.agent_max_iterations
