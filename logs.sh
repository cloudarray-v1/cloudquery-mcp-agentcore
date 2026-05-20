#!/usr/bin/env bash
# =============================================================================
# scripts/logs.sh — Tail CloudWatch logs for the AgentCore runtime
#
# Usage:
#   ./scripts/logs.sh
# =============================================================================
set -euo pipefail

REGION="us-east-1"
LOG_GROUP="/aws/bedrock-agentcore/cloudquery_mcp"

echo "Tailing logs from ${LOG_GROUP}..."
echo "Press Ctrl+C to stop."
echo ""

aws logs tail "${LOG_GROUP}" \
    --follow \
    --format short \
    --region "${REGION}"
