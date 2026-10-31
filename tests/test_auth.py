from types import SimpleNamespace

import pytest
from fastapi import HTTPException

from app.auth import require_api_key


def fake_request(api_key_in_config, header_value=None):
    headers = {"X-API-Key": header_value} if header_value is not None else {}
    app = SimpleNamespace(state=SimpleNamespace(config=SimpleNamespace(api_key=api_key_in_config)))
    return SimpleNamespace(app=app, headers=headers)


async def test_correct_key_is_allowed():
    await require_api_key(fake_request("secret", "secret"))  # no error = allowed


async def test_wrong_key_is_rejected():
    with pytest.raises(HTTPException) as err:
        await require_api_key(fake_request("secret", "wrong"))
    assert err.value.status_code == 401


async def test_missing_key_is_rejected():
    with pytest.raises(HTTPException):
        await require_api_key(fake_request("secret"))


async def test_empty_api_key_in_config_blocks_everyone():
    # No API_KEY in the secret = nobody gets in (the backup used to leave the API open here)
    with pytest.raises(HTTPException) as err:
        await require_api_key(fake_request("", None))
    assert err.value.status_code == 503
