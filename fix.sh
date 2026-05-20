cd /Users/rtransfer/Documents/cloudquery-mcp-agentcore

# Fix deploy.sh Step 5b fallback
sed -i '' \
  's/list-agent-runtime-endpoints \\/get-agent-runtime-endpoint \\/' \
  deploy.sh

sed -i '' \
  's/--query "agentRuntimeEndpoints\[0\]\.liveVersion"/--name "default" --query "liveVersion"/' \
  deploy.sh
