#!/usr/bin/env bash
# =============================================================================
# scripts/debug-on.sh — Enable debug logging on the AgentCore runtime
# No rebuild required — updates env vars in place.
#
# Usage:
#   export RUNTIME_ID=cloudquery_mcp-xxxxxxxx
#   export POSTGRES_SECRET_ARN=arn:aws:secretsmanager:...
#   ./scripts/debug-on.sh
# =============================================================================
set -euo pipefail

REGION="us-east-1"

: "${RUNTIME_ID:?ERROR: export RUNTIME_ID before running}"
: "${POSTGRES_SECRET_ARN:?ERROR: export POSTGRES_SECRET_ARN before running}"

echo "Enabling debug logging on runtime: ${RUNTIME_ID}..."

aws bedrock-agentcore-control update-agent-runtime \
    --agent-runtime-id "${RUNTIME_ID}" \
    --environment-variables "{
        \"AWS_REGION\":           \"${REGION}\",
        \"HTTP_ADDRESS\":         \":8000\",
        \"CQAPI_LOG_LEVEL\":      \"debug\",
        \"POSTGRES_SECRET_ARN\":  \"${POSTGRES_SECRET_ARN}\"
    }" \
    --region "${REGION}" \
    --output text > /dev/null

echo "✓ Debug logging ON"
echo ""
echo "Tail logs with:"
echo "  aws logs tail /aws/bedrock-agentcore/cloudquery_mcp --follow --region ${REGION}"
