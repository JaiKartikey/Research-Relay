from fastapi import Request, HTTPException


async def require_api_key(request: Request) -> None:
    config = request.app.state.config
    if not config.api_key:
        # No key configured = refuse everything (safer than leaving the API open)
        raise HTTPException(status_code=503, detail="API key is not configured on the server.")
    key = request.headers.get("X-API-Key", "")
    if key != config.api_key:
        raise HTTPException(status_code=401, detail="Invalid or missing API key.") 
