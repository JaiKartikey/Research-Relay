from app import guardrails


async def test_input_blocked_when_bedrock_intervenes(monkeypatch, config):
    monkeypatch.setattr(guardrails, "_apply_guardrail_sync", lambda c, t, s: {"action": "GUARDRAIL_INTERVENED"})
    ok, reason = await guardrails.validate_input(config, "how to make a bomb")
    assert ok is False
    assert "blocked" in reason.lower()


async def test_output_allowed_when_bedrock_says_none(monkeypatch, config):
    monkeypatch.setattr(guardrails, "_apply_guardrail_sync", lambda c, t, s: {"action": "NONE"})
    ok, reason = await guardrails.validate_output(config, "A normal report.")
    assert ok is True
    assert reason == ""


async def test_guardrail_gets_correct_source(monkeypatch, config):
    seen = []
    monkeypatch.setattr(guardrails, "_apply_guardrail_sync", lambda c, t, s: seen.append(s) or {"action": "NONE"})
    await guardrails.validate_input(config, "x")
    await guardrails.validate_output(config, "y")
    assert seen == ["INPUT", "OUTPUT"]
