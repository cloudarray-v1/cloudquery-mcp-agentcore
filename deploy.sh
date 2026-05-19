#!/usr/bin/env bash
# =============================================================================
# deploy.sh — Build, push to ECR, create IAM role, register AgentCore endpoint
# Usage:
#   export POSTGRES_SECRET_ARN=arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:NAME
#   ./deploy.sh
# =============================================================================
set -euo pipefail

REGION="us-east-1"
ECR_REPO_NAME="cloudquery-mcp"
AGENTCORE_ENDPOINT_NAME="cloudquery-mcp"
IAM_ROLE_NAME="AgentCoreCloudQueryMCPRole"
CQ_MCP_VERSION="1.8.1"

: "${POSTGRES_SECRET_ARN:?ERROR: export POSTGRES_SECRET_ARN before running}"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ECR_IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO_NAME}:${CQ_MCP_VERSION}"
POSTGRES_SECRET_NAME=$(echo "${POSTGRES_SECRET_ARN}" | awk -F':' '{print $7}' | sed 's/-[A-Za-z0-9]*$//')

echo "======================================================================"
echo " CloudQuery MCP → Bedrock AgentCore Deployment"
echo " Account : ${AWS_ACCOUNT_ID}  |  Region: ${REGION}"
echo " Image   : ${ECR_IMAGE_URI}"
echo "======================================================================"

# 1. ECR repo
echo "[1/5] Ensuring ECR repository..."
aws ecr describe-repositories --repository-names "${ECR_REPO_NAME}" \
    --region "${REGION}" --output text > /dev/null 2>&1 \
|| aws ecr create-repository --repository-name "${ECR_REPO_NAME}" \
    --region "${REGION}" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --output text > /dev/null
echo "    ✓ ${ECR_REGISTRY}/${ECR_REPO_NAME}"

# 2. Build
echo "[2/5] Building Docker image..."
docker buildx build --platform linux/amd64 \
    --build-arg CQ_MCP_VERSION="${CQ_MCP_VERSION}" \
    --tag "${ECR_IMAGE_URI}" --load .
echo "    ✓ Image built"

# 3. Push
echo "[3/5] Pushing to ECR..."
aws ecr get-login-password --region "${REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"
docker push "${ECR_IMAGE_URI}"
echo "    ✓ Image pushed"

# 4. IAM role
echo "[4/5] Creating IAM execution role..."
TRUST=$(python3 -c "
import json,sys,os
d=json.load(sys.stdin)
t=json.dumps(d['trust_policy']).replace('\${AWS_ACCOUNT_ID}',os.environ['AWS_ACCOUNT_ID'])
print(t)" AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" < iam/execution-role.json)

PERMS=$(python3 -c "
import json,sys,os
d=json.load(sys.stdin)
p=json.dumps(d['permissions_policy'])
p=p.replace('\${AWS_ACCOUNT_ID}',os.environ['AWS_ACCOUNT_ID'])
p=p.replace('\${POSTGRES_SECRET_NAME}',os.environ['POSTGRES_SECRET_NAME'])
p=p.replace('\${KMS_KEY_ID}',os.environ.get('KMS_KEY_ID','*'))
print(p)" AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID}" \
  POSTGRES_SECRET_NAME="${POSTGRES_SECRET_NAME}" \
  KMS_KEY_ID="${KMS_KEY_ID:-*}" < iam/execution-role.json)

ROLE_ARN=$(aws iam create-role \
    --role-name "${IAM_ROLE_NAME}" \
    --assume-role-policy-document "${TRUST}" \
    --query Role.Arn --output text 2>/dev/null \
  || aws iam get-role --role-name "${IAM_ROLE_NAME}" --query Role.Arn --output text)

aws iam put-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-name "CloudQueryMCPPermissions" \
    --policy-document "${PERMS}"
echo "    ✓ ${ROLE_ARN}"

# 5. Register AgentCore endpoint
echo "[5/5] Registering AgentCore endpoint..."
ENDPOINT_URL=$(aws bedrock-agentcore create-agent-runtime \
    --agent-runtime-name "${AGENTCORE_ENDPOINT_NAME}" \
    --container-configuration "{
        \"imageUri\": \"${ECR_IMAGE_URI}\",
        \"executionRoleArn\": \"${ROLE_ARN}\",
        \"environment\": [
            {\"name\": \"AWS_REGION\",         \"value\": \"${REGION}\"},
            {\"name\": \"HTTP_ADDRESS\",        \"value\": \":8080\"},
            {\"name\": \"CQAPI_LOG_LEVEL\",     \"value\": \"info\"},
            {\"name\": \"POSTGRES_SECRET_ARN\", \"value\": \"${POSTGRES_SECRET_ARN}\"}
        ],
        \"port\": 8080,
        \"protocol\": \"MCP\"
    }" \
    --region "${REGION}" \
    --query agentRuntimeEndpoint --output text 2>/dev/null \
  || aws bedrock-agentcore describe-agent-runtime \
    --agent-runtime-name "${AGENTCORE_ENDPOINT_NAME}" \
    --region "${REGION}" \
    --query agentRuntimeEndpoint --output text)

# Write resolved developer configs
python3 - <<PYEOF
import json, os
ep = "${ENDPOINT_URL}/mcp"
region = "${REGION}"

claude = {"mcpServers": {"cloudquery": {"command": "npx", "args": ["mcp-remote", ep, "--header", f"x-aws-region:{region}"]}}}
cursor = {"name": "cloudquery", "command": "npx", "args": ["mcp-remote", ep, "--header", f"x-aws-region:{region}"]}
vscode = {
    "inputs": [{"type": "promptString", "id": "aws-profile", "description": "AWS profile (blank = default)", "password": False}],
    "servers": {"CloudQuery": {"type": "stdio", "command": "npx", "args": ["mcp-remote", ep, "--header", f"x-aws-region:{region}"], "env": {"AWS_PROFILE": "\${input:aws-profile}"}}}
}
for name, data in [("developer-configs/claude_desktop_config.json", claude),
                   ("developer-configs/cursor_mcp.json", cursor),
                   ("developer-configs/vscode_mcp.json", vscode)]:
    with open(name, "w") as f:
        json.dump(data, f, indent=2)
print("Developer configs written.")
PYEOF

echo ""
echo "======================================================================"
echo " DONE — MCP endpoint: ${ENDPOINT_URL}/mcp"
echo " Developer configs updated in developer-configs/"
echo " Developers need: npm install -g mcp-remote"
echo "======================================================================"
