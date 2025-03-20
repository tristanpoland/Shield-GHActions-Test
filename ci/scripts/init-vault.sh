#!/bin/bash
set -e

# Configuration
VAULT_VERSION="1.15.2"  # Adjust version as needed
VAULT_PORT=8200
VAULT_TOKEN="vault-test-token"  # This is for local testing only
VAULT_DIR="./vault-data"
GITHUB_SECRETS_FILE="github-secrets.json"  # File containing GitHub secrets

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to check if command exists
check_command() {
  if ! command -v $1 &> /dev/null; then
    echo -e "${RED}Error: $1 is required but not installed.${NC}"
    exit 1
  fi
}

# Function to display status
status() {
  echo -e "${BLUE}==>${NC} $1"
}

# Check for required commands
check_command curl
check_command jq

# Create directory for Vault data
status "Creating Vault data directory"
mkdir -p ${VAULT_DIR}

# Download Vault if not already installed
if ! command -v vault &> /dev/null; then
  status "Downloading Vault ${VAULT_VERSION}"
  
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  if [ "$ARCH" = "x86_64" ]; then
    ARCH="amd64"
  elif [[ "$ARCH" == arm* ]] || [[ "$ARCH" = "aarch64" ]]; then
    ARCH="arm64"
  fi
  
  DOWNLOAD_URL="https://releases.hashicorp.com/vault/${VAULT_VERSION}/vault_${VAULT_VERSION}_${OS}_${ARCH}.zip"
  
  curl -s -o vault.zip ${DOWNLOAD_URL}
  unzip -o vault.zip
  chmod +x vault
  
  # Move to a location in PATH or use locally
  if [ -d "/usr/local/bin" ] && [ -w "/usr/local/bin" ]; then
    mv vault /usr/local/bin/
  else
    status "Vault binary downloaded to current directory. Using local path."
    export PATH=$PATH:$(pwd)
  fi
fi

# Start Vault in development mode as a background process
status "Starting Vault in development mode"
nohup vault server -dev -dev-root-token-id=${VAULT_TOKEN} -dev-listen-address=0.0.0.0:${VAULT_PORT} > ${VAULT_DIR}/vault.log 2>&1 &
VAULT_PID=$!

# Save PID to file for later cleanup
echo $VAULT_PID > ${VAULT_DIR}/vault.pid
status "Vault process started with PID: $VAULT_PID"

# Wait for Vault to start
status "Waiting for Vault to start"
MAX_ATTEMPTS=30
ATTEMPTS=0
while ! curl -s http://127.0.0.1:${VAULT_PORT}/v1/sys/health >/dev/null; do
  ATTEMPTS=$((ATTEMPTS+1))
  if [ $ATTEMPTS -ge $MAX_ATTEMPTS ]; then
    echo -e "${RED}Error: Vault failed to start after $MAX_ATTEMPTS attempts.${NC}"
    kill $VAULT_PID 2>/dev/null || true
    exit 1
  fi
  echo -n "."
  sleep 1
done
echo ""

# Configure environment for vault CLI
export VAULT_ADDR=http://127.0.0.1:${VAULT_PORT}
export VAULT_TOKEN=${VAULT_TOKEN}

status "Vault is running at http://127.0.0.1:${VAULT_PORT}"

# Setup some initial configuration - enable KV secrets engine at secret/ path
status "Enabling KV secrets engine at secret/ path"
vault secrets enable -version=2 -path=secret kv || echo "KV secrets engine already enabled at secret/ path"

# Create a policy for your application
status "Creating app policy"
cat > ${VAULT_DIR}/app-policy.hcl <<EOF
path "secret/data/github/*" {
  capabilities = ["read"]
}
EOF

vault policy write app-policy ${VAULT_DIR}/app-policy.hcl

# Create the handshake secret
status "Creating handshake secret"
vault kv put secret/handshake value="initialized"

# Process and load GitHub secrets
if [ -f "${GITHUB_SECRETS_FILE}" ]; then
  status "Loading GitHub secrets from ${GITHUB_SECRETS_FILE}"
  
  # Process each secret in the JSON file
  jq -c '.[]' ${GITHUB_SECRETS_FILE} | while read -r secret; do
    name=$(echo $secret | jq -r '.name')
    value=$(echo $secret | jq -r '.value')
    
    # Store secret in Vault
    vault kv put secret/github/${name} value="${value}"
    echo "Secret ${name} loaded into Vault"
  done
else
  # If no secrets file exists, we'll load from environment variables
  status "No GitHub secrets file found, attempting to load from environment variables"
  
  # Find all environment variables that start with GITHUB_
  env | grep "^GITHUB_" | while read -r secret; do
    name=${secret%%=*}
    value=${secret#*=}
    
    # Store secret in Vault
    vault kv put secret/github/${name} value="${value}"
    echo "Secret ${name} loaded into Vault from environment"
  done
fi

# Create a helper to load secrets in your CI pipeline
status "Creating helper script for CI pipeline"
cat > load-vault-secrets.sh <<EOF
#!/bin/bash
# This script exports Vault secrets as environment variables for your CI pipeline

export VAULT_ADDR=http://127.0.0.1:${VAULT_PORT}
export VAULT_TOKEN=${VAULT_TOKEN}

# List all secrets in the GitHub path
SECRETS=\$(vault kv list -format=json secret/github/ | jq -r '.[]')

for SECRET in \$SECRETS; do
  # Get the secret value
  VALUE=\$(vault kv get -field=value secret/github/\$SECRET)
  
  # Export as environment variable
  export \$SECRET="\$VALUE"
  echo "Exported \$SECRET to environment"
done
EOF

chmod +x load-vault-secrets.sh

# Create cleanup script
status "Creating cleanup script for Vault"
cat > cleanup-vault.sh <<EOF
#!/bin/bash
# This script stops the Vault server

if [ -f "${VAULT_DIR}/vault.pid" ]; then
  VAULT_PID=\$(cat ${VAULT_DIR}/vault.pid)
  if ps -p \$VAULT_PID > /dev/null; then
    echo "Stopping Vault server (PID: \$VAULT_PID)"
    kill \$VAULT_PID
  else
    echo "Vault server is not running"
  fi
  rm -f ${VAULT_DIR}/vault.pid
else
  echo "No Vault PID file found"
fi
EOF

chmod +x cleanup-vault.sh

# Optional: Create a script to help format GitHub secrets for import
status "Creating helper script for GitHub secrets formatting"
cat > format-github-secrets.sh <<EOF
#!/bin/bash
# This script formats GitHub secrets for import into Vault
# Usage: ./format-github-secrets.sh SECRET_NAME1=value1 SECRET_NAME2=value2

output="["

first=true
for secret in "\$@"; do
  name=\${secret%%=*}
  value=\${secret#*=}
  
  if [ "\$first" = true ]; then
    first=false
  else
    output="\$output,"
  fi
  
  output="\$output{\"name\":\"\$name\",\"value\":\"\$value\"}"
done

output="\$output]"

echo \$output > ${GITHUB_SECRETS_FILE}
echo "Generated ${GITHUB_SECRETS_FILE} with \$# secrets"
EOF

chmod +x format-github-secrets.sh

# Display usage information
echo -e "\n${GREEN}Local Vault successfully deployed in background!${NC}"
echo -e "Vault UI: http://127.0.0.1:${VAULT_PORT}/ui"
echo -e "Vault Token: ${VAULT_TOKEN}"
echo ""
echo "To use Vault in your tests:"
echo "1. Source the environment: export VAULT_ADDR=http://127.0.0.1:${VAULT_PORT} VAULT_TOKEN=${VAULT_TOKEN}"
echo "2. Run './load-vault-secrets.sh' to load secrets as environment variables"
echo ""
echo "To stop Vault when done: ./cleanup-vault.sh"

# Export variables to GitHub Actions environment
echo "VAULT_URI=http://127.0.0.1:${VAULT_PORT}" > vault-env.tmp
echo "VAULT_TOKEN=${VAULT_TOKEN}" >> vault-env.tmp

# Export environment variables for the current GitHub Action workflow
echo "VAULT_ADDR=http://127.0.0.1:${VAULT_PORT}" >> $GITHUB_ENV
echo "VAULT_TOKEN=${VAULT_TOKEN}" >> $GITHUB_ENV

# Script ends here, with Vault running in the background
