# cloudquery-mcp-agentcore

Deploy the official [CloudQuery MCP Server](https://www.cloudquery.io/docs/platform/features/mcp-server) (PostgreSQL mode) onto **Amazon Bedrock AgentCore Runtime** and expose it to your developers via Claude Desktop, Cursor, and VS Code.

No LLM is bundled — the MCP server is a pure data layer that translates AI tool calls into SQL queries against your CloudQuery asset inventory database. The LLM is whatever your IDE provides (Claude, Copilot, etc.).

---

## How it works

Developers connect their IDE to the AgentCore-hosted MCP server using `mcp-remote`. When they ask a question like _"which EC2 instances have a public IP?"_, their IDE's AI calls the MCP tool, which runs the equivalent SQL against your CloudQuery PostgreSQL database and returns the rows.

```
Developer IDE (Claude Desktop / Cursor / VS Code)
        │
        │  stdio → mcp-remote (npm) → Streamable HTTP + AWS SigV4
        ▼
Amazon Bedrock AgentCore Runtime  (us-east-1)
  └── MicroVM: cq-platform-mcp v1.8.1  (arm64, port 8080, path /mcp)
        │  entrypoint.sh fetches POSTGRES_CONNECTION_STRING
        │  from Secrets Manager via IAM role at cold start
        ▼  (VPC — same subnet as RDS)
RDS / Aurora PostgreSQL
  └── cq_inventory database  (synced by CloudQuery CLI)
```

---

## Infrastructure components

### Amazon ECR
Stores the Docker container image. The image wraps the official `cq-platform-mcp` Go binary (arm64). Built by `deploy.sh` and pulled by AgentCore at cold start.

### Amazon Bedrock AgentCore Runtime
The serverless MicroVM host. Key properties:
- **Protocol:** MCP — AgentCore acts as a transparent proxy, routing `/mcp` POST requests directly to the container
- **Architecture:** arm64 (required by AgentCore)
- **Port:** 8080
- **Autoscaling:** min 1, max 5 instances
- **Session routing:** `Mcp-Session-Id` header ensures a developer's requests always hit the same MicroVM instance
- **Network:** VPC mode — MicroVMs run in the same VPC and subnet as your RDS instance
- **Auth:** AWS IAM SigV4 — developers sign requests with their AWS credentials via `mcp-remote`

### AgentCore Runtime Endpoint
A named endpoint (`default`) that sits in front of the runtime and provides the stable invoke URL. AgentCore automatically creates a `DEFAULT` endpoint; `deploy.sh` creates an additional `default` endpoint.

### AWS Secrets Manager
Holds the RDS connection credentials as a JSON secret:
```json
{
  "username": "cloudquery",
  "password": "...",
  "host": "mydb.cluster-xyz.us-east-1.rds.amazonaws.com",
  "port": 5432,
  "dbname": "cq_inventory"
}
```
`entrypoint.sh` fetches this at container startup via the IAM execution role — no credentials are stored in the image or passed as build arguments.

### IAM Execution Role
Attached to the AgentCore MicroVM. Grants:
- `secretsmanager:GetSecretValue` — fetch the RDS credentials at startup
- `ecr:*` — pull the container image from ECR
- `logs:*` — write container logs to CloudWatch
- `bedrock-agentcore:*` — control plane operations

### RDS / Aurora PostgreSQL
Your cloud asset inventory database, populated by the CloudQuery CLI. The AgentCore MicroVMs connect to it over port 5432 inside the VPC. The RDS security group must allow inbound TCP 5432 from the AgentCore security group.

### CloudQuery CLI (run separately)
Syncs your AWS (and optionally GCP, Azure) resources into the `cq_inventory` database on a schedule. This is not part of this repo — it runs as a separate process (Lambda, ECS task, cron job, etc.).

### VPC / Networking
```
VPC
├── Subnet(s)  ← AgentCore MicroVMs run here
│     └── Security group: AgentCore-SG
│           outbound: 5432 → RDS-SG
│           outbound: 443  → Secrets Manager, ECR (via VPC endpoints or NAT)
└── Subnet(s)  ← RDS runs here
      └── Security group: RDS-SG
            inbound: 5432 from AgentCore-SG
```

### mcp-remote (developer-side, npm)
A local npm proxy that bridges stdio (what IDEs use for MCP) to Streamable HTTP (what AgentCore exposes). It handles AWS SigV4 request signing automatically using the developer's local AWS credentials (`~/.aws/credentials`, SSO, or environment variables).

---

## Quick start

### Prerequisites
- AWS CLI v2 configured
- Docker with buildx
- Python 3
- RDS/Aurora PostgreSQL instance synced by CloudQuery CLI
- Secrets Manager secret containing RDS credentials (see format above)

### 1. Create the secret
```bash
aws secretsmanager create-secret \
  --name cloudquery/pg-conn \
  --secret-string '{"username":"cloudquery","password":"...","host":"...","port":5432,"dbname":"cq_inventory"}' \
  --region us-east-1
```

### 2. Set environment variables
```bash
export POSTGRES_SECRET_ARN=arn:aws:secretsmanager:us-east-1:ACCOUNT:secret:cloudquery/pg-conn-XxXxXx

# Optional — only if your secret is encrypted with a custom KMS key
export KMS_KEY_ID=your-kms-key-id
```

### 3. Deploy
```bash
chmod +x deploy.sh && ./deploy.sh
```

`deploy.sh` runs these steps in order:
1. Create ECR repository (idempotent)
2. Build Docker image for `linux/arm64` and push to ECR
3. Create IAM execution role with least-privilege permissions
4. Create AgentCore Runtime with VPC network config, MCP protocol, arm64 container
5. Create AgentCore Runtime Endpoint (`default`)
6. Write resolved IDE configs to `developer-configs/`

---

## Developer setup (one time per developer)

### Step 1 — Install mcp-remote
```bash
npm install -g mcp-remote
```

### Step 2 — Configure AWS credentials
Developers need `bedrock-agentcore:InvokeAgentRuntime` permission on the runtime ARN. Add this inline policy to their IAM user or role:
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

### Step 3 — Copy the IDE config

After `deploy.sh` completes, configs with the real endpoint URL are written to `developer-configs/`.

**Claude Desktop** — merge into:
- macOS: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Linux: `~/.config/Claude/claude_desktop_config.json`

Then restart Claude Desktop.

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

## Available MCP tools (PostgreSQL mode)

| Tool | Description |
|---|---|
| `postgres-list-plugins` | List CloudQuery integrations present in the DB |
| `postgres-table-search-regex` | Search for tables by regex (e.g. `aws_ec2.*`) |
| `postgres-table-schemas` | Get column definitions and types for given tables |
| `postgres-column-search` | Search for columns by regex across all tables |
| `execute-postgres-query` | Run a SQL query against the CloudQuery inventory DB |

### Example prompts
- _"List all EC2 instances that have a public IP address"_
- _"Show me all S3 buckets with public access enabled"_
- _"Find all IAM roles with AdministratorAccess attached"_
- _"Which RDS instances don't have encryption at rest enabled?"_
- _"List all security groups with port 22 open to 0.0.0.0/0"_

---

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Downloads official `cq-platform-mcp` binary (arm64), runs as non-root |
| `entrypoint.sh` | Fetches RDS credentials from Secrets Manager at startup, exec's binary |
| `.bedrock_agentcore.yaml` | AgentCore runtime config reference |
| `deploy.sh` | Full provisioning: ECR → IAM → AgentCore Runtime → Endpoint → dev configs |
| `iam/execution-role.json` | IAM trust policy + permissions policy template |
| `developer-configs/` | IDE configs for Claude Desktop, Cursor, VS Code (written by deploy.sh) |

---

## Security notes

- No credentials are stored in the Docker image, passed as build args, or written to disk
- The IAM execution role is the only auth surface — revoking it instantly cuts all DB access
- RDS is in a VPC — AgentCore MicroVMs connect over private networking, not the public internet
- Developers authenticate via AWS SigV4 — no shared API keys to distribute or rotate
- The container runs as a non-root user (uid 10001)

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
