from app import duckdns


def test_clean_domain_accepts_any_form():
    assert duckdns.clean_domain("research-relay") == "research-relay"
    assert duckdns.clean_domain(" Research-Relay.duckdns.org ") == "research-relay"
    assert duckdns.clean_domain("https://research-relay.duckdns.org/") == "research-relay"


class FakeResponse:
    def __init__(self, body):
        self.body = body

    def read(self):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


def test_update_sends_domain_and_token_and_reads_ok(monkeypatch):
    seen = {}

    def fake_urlopen(url, timeout):
        seen["url"] = url
        return FakeResponse(b"OK")

    monkeypatch.setattr(duckdns.urllib.request, "urlopen", fake_urlopen)
    assert duckdns.update("research-relay", "tok123") is True
    assert "domains=research-relay" in seen["url"]
    assert "token=tok123" in seen["url"]
    assert seen["url"].endswith("&ip=")  # empty ip = DuckDNS uses the caller's public IP


def test_update_returns_false_on_ko(monkeypatch):
    monkeypatch.setattr(duckdns.urllib.request, "urlopen", lambda url, timeout: FakeResponse(b"KO"))
    assert duckdns.update("research-relay", "wrong") is False


def test_main_stops_quietly_when_not_configured(monkeypatch):
    monkeypatch.setattr(duckdns, "load_settings", lambda: ("", ""))
    duckdns.main()  # returns instead of looping forever
