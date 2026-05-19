#!/usr/bin/env python3
"""
entrypoint.sh
=============
1. Reads POSTGRES_SECRET_ARN from the environment.
2. Fetches the secret from AWS Secrets Manager via IAM role (no hardcoded keys).
3. Builds POSTGRES_CONNECTION_STRING and exec's cq-platform-mcp.

Expected secret format (JSON):
  { "username": "...", "password": "...", "host": "...", "port": 5432, "dbname": "..." }
OR a plain connection string under key "connection_string".
"""
import json, os, sys
import boto3

def get_connection_string():
    secret_arn = os.environ.get("POSTGRES_SECRET_ARN")
    if not secret_arn:
        print("[entrypoint] FATAL: POSTGRES_SECRET_ARN is not set.", file=sys.stderr)
        sys.exit(1)

    region = os.environ.get("AWS_REGION", "us-east-1")
    print(f"[entrypoint] Fetching secret: {secret_arn}", flush=True)

    try:
        response = boto3.client("secretsmanager", region_name=region) \
                        .get_secret_value(SecretId=secret_arn)
    except Exception as exc:
        print(f"[entrypoint] FATAL: {exc}", file=sys.stderr)
        sys.exit(1)

    raw = response.get("SecretString", "")
    try:
        secret = json.loads(raw)
    except json.JSONDecodeError:
        return raw.strip()

    if "connection_string" in secret:
        return secret["connection_string"]

    for k in ("username", "password", "host", "dbname"):
        if k not in secret:
            print(f"[entrypoint] FATAL: secret missing field '{k}'", file=sys.stderr)
            sys.exit(1)

    u, p, h = secret["username"], secret["password"], secret["host"]
    port    = secret.get("port", 5432)
    db      = secret["dbname"]
    print(f"[entrypoint] Built connection string for host={h} db={db}", flush=True)
    return f"postgres://{u}:{p}@{h}:{port}/{db}?sslmode=require"

os.environ["POSTGRES_CONNECTION_STRING"] = get_connection_string()
os.environ.setdefault("HTTP_ADDRESS", ":8080")
os.environ.setdefault("CQAPI_LOG_LEVEL", "info")
print(f"[entrypoint] Starting cq-platform-mcp on {os.environ['HTTP_ADDRESS']}", flush=True)
os.execv("/usr/local/bin/cq-platform-mcp", ["/usr/local/bin/cq-platform-mcp"])
