"""
Keeps a free DuckDNS name (like research-relay.duckdns.org) pointing at this EC2 instance.

Why: the instance gets a NEW public IP on every Stop/Start. DuckDNS gives you a name that
never changes. This little script tells DuckDNS "my IP is now X" on every boot, and again
every 5 minutes, so the name always points at the instance.

It runs as its own small container (the "duckdns" service in docker-compose.yml).
The token and the name are read from Secrets Manager (research-relay/config), never from code:
  DUCKDNS_DOMAIN = research-relay        (just the first part, ".duckdns.org" is optional)
  DUCKDNS_TOKEN  = the token from duckdns.org
If they are empty, the script prints a message and stops. The app works fine without it.
"""
import json
import os
import time
import urllib.request

import boto3

EVERY_SECONDS = 300   # how often to re-check (cheap: one tiny HTTPS call)
RETRY_SECONDS = 60    # wait time after an error (e.g. network not ready right after boot)


def load_settings() -> tuple[str, str]:
    """Reads DUCKDNS_DOMAIN and DUCKDNS_TOKEN from the same secret the app uses."""
    region = os.environ.get("AWS_REGION", "ap-southeast-2")
    client = boto3.client("secretsmanager", region_name=region)
    secret = json.loads(client.get_secret_value(SecretId="research-relay/config")["SecretString"])
    return clean_domain(secret.get("DUCKDNS_DOMAIN", "")), secret.get("DUCKDNS_TOKEN", "").strip()


def clean_domain(domain: str) -> str:
    """'https://Research-Relay.duckdns.org/' -> 'research-relay' (DuckDNS wants only the first part)."""
    domain = domain.strip().lower()
    domain = domain.removeprefix("https://").removeprefix("http://").rstrip("/")
    return domain.removesuffix(".duckdns.org")


def update(domain: str, token: str) -> bool:
    """Tells DuckDNS our IP. Returns True if DuckDNS answered "OK"."""
    # ip= is left empty on purpose: DuckDNS then uses the IP the request comes from,
    # which is this instance's public IP. So we never have to look the IP up ourselves.
    url = f"https://www.duckdns.org/update?domains={domain}&token={token}&ip="
    with urllib.request.urlopen(url, timeout=15) as response:
        return response.read().decode().strip() == "OK"


def main():
    while True:
        try:
            domain, token = load_settings()
            if not domain or not token:
                print("DuckDNS: DUCKDNS_DOMAIN / DUCKDNS_TOKEN not set in the secret, skipping.", flush=True)
                return  # exit 0 -> docker does not restart it
            if update(domain, token):
                print(f"DuckDNS: {domain}.duckdns.org now points at this instance.", flush=True)
                time.sleep(EVERY_SECONDS)
            else:
                # "KO" = wrong token or a name that is not in your DuckDNS account
                print("DuckDNS: update refused (KO). Check DUCKDNS_TOKEN and DUCKDNS_DOMAIN.", flush=True)
                time.sleep(RETRY_SECONDS)
        except Exception as error:  # never crash-loop; try again in a minute
            # only the error type is printed, so the token can never end up in the logs
            print(f"DuckDNS: update failed ({type(error).__name__}), retrying in {RETRY_SECONDS}s.", flush=True)
            time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    main()
