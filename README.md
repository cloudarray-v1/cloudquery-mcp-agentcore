# cloudquery-mcp-agentcore

Deploy the official [CloudQuery MCP Server](https://www.cloudquery.io/docs/platform/features/mcp-server) (PostgreSQL mode) onto **Amazon Bedrock AgentCore Runtime** so your developers can query your cloud asset inventory by asking plain-English questions directly inside Claude Desktop, Cursor, or VS Code.

No custom code. No LLM bundled. Just the official CloudQuery binary, wrapped in a container, running on AWS serverless infrastructure.

---

## What this actually does

CloudQuery syncs your AWS (and GCP, Azure) resources into a PostgreSQL database on a schedule. This project puts an MCP server in front of that database and hosts it on Bedrock AgentCore so your developers can talk to it from their IDEs.

When a developer asks _"which EC2 instances have a public IP?"_ — their IDE's AI (Claude, Copilot, etc.) calls the MCP tool, which runs the equivalent SQL against your CloudQuery inventory and returns the rows. The AI never touches your database directly.

```
Developer IDE (Claude Desktop / Cursor / VS Code)
        │
        │  stdio → mcp-remote (npm) → HTTPS + AWS SigV4
        ▼
Amazon Bedrock AgentCore Runtime  (us-east-1)
  └── MicroVM: cq-platform-mcp v1.8.1  (arm64, port 8000, path /mcp)
        │
        │  entrypoint.sh calls Secrets Manager via IAM role at startup
        │  builds POSTGRES_CONNECTION_STRING in memory, never on disk
        │  os.execv() replaces Python with the Go binary (PID 1)
        ▼
RDS / Aurora PostgreSQL  (same VPC, private subnet)
  └── cq_inventory database  ← synced by CloudQuery CLI on a schedule
```

---

## Infrastructure components

### Amazon ECR
Stores the Docker container image. The image downloads the official `cq-platform-mcp` Go binary at build time (arm64 — required by AgentCore). Built and pushed by `deploy.sh`.

### Amazon Bedrock AgentCore Runtime
The serverless MicroVM host for the MCP server. Key facts:
- **Port:** 8000 (AgentCore hardcodes this for MCP — do not change)
- **Path:** `/mcp` (required by AgentCore MCP protocol contract)
- **Architecture:** arm64 (required — amd64 will fail at deploy time)
- **Protocol:** MCP over Streamable HTTP
- **Session routing:** AgentCore stamps every request with `Mcp-Session-Id` and routes the same session to the same MicroVM instance
- **Scaling:** min 1, max 5 MicroVM instances (configurable)
- **Network:** VPC mode — MicroVMs run in the same VPC and subnet as RDS so no traffic leaves your network

### AgentCore Runtime Endpoint
AgentCore automatically creates a `DEFAULT` endpoint when the runtime is created. `deploy.sh` creates an additional `default` endpoint. Use the `default` endpoint URL in developer configs.

The invoke URL pattern is:
```
https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/YOUR_RUNTIME_ID/invoke
```

### AWS Secrets Manager
Holds your RDS credentials as a JSON secret. `entrypoint.sh` fetches this at container startup using the MicroVM's IAM role — no passwords in the image, no build args, no environment variable injection at deploy time.

Expected secret format:
```json
{
  "username": "cloudquery",
  "password": "...",
  "host":     "mydb.cluster-xyz.us-east-1.rds.amazonaws.com",
  "port":     5432,
  "dbname":   "cq_inventory"
}
```

### IAM Execution Role
Attached to the AgentCore MicroVM at runtime. Grants the minimum permissions needed:
- `secretsmanager:GetSecretValue` — fetch RDS credentials at startup
- `ecr:GetDownloadUrlForLayer`, `ecr:BatchGetImage` etc. — pull the image from ECR
- `logs:CreateLogStream`, `logs:PutLogEvents` — write to CloudWatch
- `bedrock-agentcore:*` — control plane operations

Developers also need `bedrock-agentcore:InvokeAgentRuntime` on their personal IAM user/role to call the endpoint.

### RDS / Aurora PostgreSQL
Your cloud asset inventory database. The AgentCore MicroVMs connect to it over port 5432 inside the VPC.

**Security group requirement:** the RDS security group must allow inbound TCP 5432 from the AgentCore security group. Since both run in the same VPC this stays entirely private.

### VPC / Networking
```
VPC
├── Subnets  ← AgentCore MicroVMs run here
│     └── AgentCore security group
│           outbound 5432 → RDS security group
│           outbound 443  → Secrets Manager (VPC endpoint or NAT)
│           outbound 443  → ECR (VPC endpoint or NAT)
└── Subnets  ← RDS runs here
      └── RDS security group
            inbound 5432 from AgentCore security group
```

If your VPC has no NAT gateway, add VPC Interface Endpoints for:
- `com.amazonaws.us-east-1.secretsmanager`
- `com.amazonaws.us-east-1.ecr.api`
- `com.amazonaws.us-east-1.ecr.dkr`

Without these, `entrypoint.sh` will hang on the Secrets Manager call and AgentCore will time out with `jsonrpc -32011 initialization time exceeded`.

### CloudQuery CLI (runs separately)
Syncs your AWS/GCP/Azure resources into `cq_inventory` on a schedule. Not part of this repo — run it as a Lambda, ECS task, or cron job. See the [CloudQuery AWS integration guide](https://www.cloudquery.io/docs/platform/integration-guides/setting-up-an-aws-integration).

### mcp-remote (developer-side)
An npm package that bridges stdio (what IDEs use for MCP) to Streamable HTTP (what AgentCore exposes). Handles AWS SigV4 request signing automatically from the developer's local credential chain (`~/.aws/credentials`, SSO, environment variables).

---

## Prerequisites

- AWS CLI v2 (`aws --version`)
- Docker with buildx support
- Python 3
- An RDS/Aurora PostgreSQL instance already synced by CloudQuery CLI
- Your deploying IAM user needs: `ecr:*`, `iam:CreateRole`, `iam:PutRolePolicy`, `secretsmanager:CreateSecret`, `bedrock-agentcore:*`

---

## Deployment

### 1. Create the Secrets Manager secret
```bash
aws secretsmanager create-secret \
  --name cloudquery/pg-conn \
  --secret-string '{
    "username": "cloudquery",
    "password": "your-password",
    "host":     "mydb.cluster-xyz.us-east-1.rds.amazonaws.com",
    "port":     5432,
    "dbname":   "cq_inventory"
  }' \
  --region us-east-1
```

### 2. Export required variables
```bash
export POSTGRES_SECRET_ARN=arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:cloudquery/pg-conn-XxXxXx
export SUBNET_ID=subnet-xxxxxxxx          # same subnet as your RDS instance
export SECURITY_GROUP_ID=sg-xxxxxxxx      # security group for the AgentCore MicroVMs

# Only needed if your secret uses a custom KMS key
export KMS_KEY_ID=your-kms-key-id
```

### 3. Run deploy.sh
```bash
chmod +x deploy.sh && ./deploy.sh
```

What `deploy.sh` does in order:
1. Creates the ECR repository (idempotent)
2. Builds the Docker image for `linux/arm64` and pushes to ECR
3. Creates the IAM execution role from `iam/execution-role.json`
4. Creates the AgentCore Runtime (`bedrock-agentcore-control create-agent-runtime`)
5. Creates the AgentCore Runtime Endpoint (`bedrock-agentcore-control create-agent-runtime-endpoint`)
6. Writes resolved IDE configs to `developer-configs/`

### 4. Save your runtime ID
After deploy completes, save the printed `RUNTIME_ID` to a local `.env` file (already in `.gitignore`):
```bash
echo "RUNTIME_ID=cloudquery_mcp-xxxxxxxx" >> .env
echo "POSTGRES_SECRET_ARN=arn:aws:..." >> .env
```

---

## Developer setup

### Step 1 — Install mcp-remote (one time)
```bash
npm install -g mcp-remote
```

### Step 2 — Get AWS credentials
Developers need this IAM permission on their user or role:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": "bedrock-agentcore:InvokeAgentRuntime",
    "Resource": "arn:aws:bedrock-agentcore:us-east-1:ACCOUNT:agent/YOUR_RUNTIME_ID:*"
  }]
}
```

### Step 3 — Configure your IDE

After `deploy.sh` completes, configs with the real endpoint URL are written to `developer-configs/`.

**Claude Desktop** — merge into `~/Library/Application Support/Claude/claude_desktop_config.json` then restart:
```json
{
  "mcpServers": {
    "cloudquery": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/YOUR_RUNTIME_ID/invoke",
        "--header",
        "x-aws-region:us-east-1"
      ]
    }
  }
}
```

**Cursor** — Settings → Cursor Settings → Tools and Integrations → Add MCP Server → paste `developer-configs/cursor_mcp.json`

**VS Code** — `Cmd+Shift+P` → Preferences: Open User Settings (JSON) → add:
```json
{
  "mcp": {
    "servers": {
      "CloudQuery": {
        "type": "stdio",
        "command": "npx",
        "args": [
          "mcp-remote",
          "https://bedrock-agentcore.us-east-1.amazonaws.com/runtimes/YOUR_RUNTIME_ID/invoke",
          "--header",
          "x-aws-region:us-east-1"
        ]
      }
    }
  }
}
```

---

## Available MCP tools

| Tool | Description |
|---|---|
| `postgres-list-plugins` | List CloudQuery integrations present in the DB |
| `postgres-table-search-regex` | Search for tables by regex (e.g. `aws_ec2.*`) |
| `postgres-table-schemas` | Get column definitions and types for a table |
| `postgres-column-search` | Search for columns by regex across all tables |
| `execute-postgres-query` | Run a SQL query against the inventory DB |

### Example prompts
- _"List all EC2 instances that have a public IP address"_
- _"Show me all S3 buckets with public access enabled"_
- _"Find all IAM roles with AdministratorAccess attached"_
- _"Which RDS instances don't have encryption at rest enabled?"_
- _"List all security groups with port 22 open to 0.0.0.0/0"_
- _"How many resources do I have per AWS region?"_

---

## Debugging

Log level can be changed **without rebuilding the container** by updating the runtime environment variables directly.

### Enable debug logging
```bash
export RUNTIME_ID=cloudquery_mcp-xxxxxxxx
export POSTGRES_SECRET_ARN=arn:aws:secretsmanager:...
./scripts/debug-on.sh
```

### Restore info logging
```bash
./scripts/debug-off.sh
```

### Tail live logs
```bash
./scripts/logs.sh
```

Or manually:
```bash
aws logs tail /aws/bedrock-agentcore/cloudquery_mcp --follow --region us-east-1
```

---

## Common issues

| Error | Cause | Fix |
|---|---|---|
| `jsonrpc -32011 initialization time exceeded` | Wrong port or no route to Secrets Manager | Ensure port is 8000, add VPC endpoints for Secrets Manager and ECR |
| `architecture incompatible` | Image built for amd64 | Build with `--platform linux/arm64`, use `arm64` binary URL in Dockerfile |
| `KeyError: AWS_ACCOUNT_ID` | Python subprocess not inheriting env vars | Add `export AWS_ACCOUNT_ID` before python3 calls in deploy.sh |
| `invalid argument --agent-runtime-id` | Wrong CLI argument structure | Use `--agent-runtime-artifact` with `containerConfiguration.containerUri` |
| Two endpoints `default` and `DEFAULT` | deploy.sh ran twice | Delete with `aws bedrock-agentcore-control delete-agent-runtime-endpoint --name DEFAULT` |
| `-` not allowed in runtime name | AgentCore name pattern is `[a-zA-Z][a-zA-Z0-9_]*` | Use underscores: `cloudquery_mcp` |
| `no permission list agent runtime endpoint` | Deployer IAM user missing permissions | Add `bedrock-agentcore:*` to your personal IAM user or role |

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Downloads `cq-platform-mcp` binary (arm64), non-root, port 8000 |
| `entrypoint.sh` | Fetches secret from Secrets Manager, builds conn string, exec's binary |
| `.bedrock_agentcore.yaml` | AgentCore runtime config reference |
| `deploy.sh` | Full provisioning: ECR → Docker → IAM → Runtime → Endpoint → dev configs |
| `iam/execution-role.json` | IAM trust + permissions policy template |
| `developer-configs/` | IDE configs written by deploy.sh with real endpoint URL |
| `scripts/debug-on.sh` | Enable debug logging without rebuilding the container |
| `scripts/debug-off.sh` | Restore info logging without rebuilding the container |
| `scripts/logs.sh` | Tail live CloudWatch logs for the runtime |

---

## Security

- No credentials in the image, build args, or environment variable injection
- The IAM execution role is the only credential surface — revoke it to cut all DB access instantly
- RDS is in a VPC — MicroVMs connect over private networking only
- Developers authenticate via AWS SigV4 — no shared API keys to distribute or rotate
- Container runs as non-root user (uid 10001)
- Connection string is built in memory by `entrypoint.sh` and never written to disk

---

## Diagrams

### System overview
![Architecture](docs/architecture.svg)

### Container startup
![Startup](docs/startup.svg)

### Request lifecycle
![Request](docs/request.svg)

### Deployment steps
![Deploy](docs/deploy.svg)
