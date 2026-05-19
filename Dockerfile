# =============================================================================
# CloudQuery MCP Server — Bedrock AgentCore Container
# Base : debian:bookworm-slim  (needed for glibc; the CQ binary is a Go binary)
# Binary: cq-platform-mcp v1.8.1 (official CloudQuery release, linux/amd64)
# Mode  : PostgreSQL  (POSTGRES_CONNECTION_STRING injected at runtime)
# =============================================================================

# ── Stage 1: download & verify the binary ────────────────────────────────────
FROM debian:bookworm-slim AS downloader

ARG CQ_MCP_VERSION=1.8.1

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
    "https://github.com/cloudquery/mcp-releases/releases/download/v${CQ_MCP_VERSION}/cq-platform-mcp_${CQ_MCP_VERSION}_linux_amd64.zip" \
    -o /tmp/cq-mcp.zip \
    && unzip /tmp/cq-mcp.zip -d /tmp/cq-mcp \
    && mv /tmp/cq-mcp/cq-platform-mcp /usr/local/bin/cq-platform-mcp \
    && chmod 755 /usr/local/bin/cq-platform-mcp \
    && rm -rf /tmp/cq-mcp /tmp/cq-mcp.zip

# ── Stage 2: runtime image ───────────────────────────────────────────────────
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        python3 \
        python3-boto3 \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

COPY --from=downloader /usr/local/bin/cq-platform-mcp /usr/local/bin/cq-platform-mcp
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

RUN groupadd --gid 10001 cqmcp \
    && useradd  --uid 10001 --gid cqmcp --no-create-home --shell /usr/sbin/nologin cqmcp

USER cqmcp

EXPOSE 8080

ENV HTTP_ADDRESS=":8080" \
    CQAPI_LOG_LEVEL="info"

ENTRYPOINT ["/entrypoint.sh"]
