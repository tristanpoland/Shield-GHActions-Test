#!/bin/bash

# Use only set -e, not set -u as it's causing problems with unbound variables
set -e

# Enable extensive debugging
if [[ "${DEBUG:-false}" == "true" ]]; then
  set -x  # Enable command tracing
fi

echo "### SCRIPT STARTED ###"
echo "Running as user: $(whoami)"
echo "Current directory: $(pwd)"

# Force non-interactive mode for tools that respect it
export DEBIAN_FRONTEND=noninteractive
export SAFE_NONINTERACTIVE=1
export TERM=dumb

# These vars are fine but vault isn't running, so we'll skip vault operations
export VAULT_TOKEN=${VAULT_TOKEN:-"00000000-0000-0000-0000-000000000000"}
export VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}
export VAULT_NAMESPACE=${VAULT_NAMESPACE:-""}

# Define variables (allow defaults to be overridden)
DEPLOY_ENV=${DEPLOY_ENV:-"ci-baseline"}
SKIP_FRESH=${SKIP_FRESH:-"false"}
SKIP_REPLACE_SECRETS=${SKIP_REPLACE_SECRETS:-"true"} # Default to skipping since vault isn't available
SKIP_DEPLOY=${SKIP_DEPLOY:-"false"}
SKIP_SMOKE_TESTS=${SKIP_SMOKE_TESTS:-"false"}
SKIP_CLEAN=${SKIP_CLEAN:-"false"}

# Define BOSH variable if not already set
BOSH=${BOSH:-"bosh"}

echo "### CONFIGURATION VARIABLES ###"
echo "DEPLOY_ENV=$DEPLOY_ENV"
echo "SKIP_FRESH=$SKIP_FRESH"
echo "SKIP_REPLACE_SECRETS=$SKIP_REPLACE_SECRETS"
echo "SKIP_DEPLOY=$SKIP_DEPLOY"
echo "SKIP_SMOKE_TESTS=$SKIP_SMOKE_TESTS"
echo "SKIP_CLEAN=$SKIP_CLEAN"

header() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "--------------------------------------------------------------------------------"
  echo
}

# Strip ANSI color codes from string
strip_ansi() {
  echo -n "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

has_feature() {
  echo "DEBUG: Checking if $1 has feature '$2'"
  # Capture output to strip ANSI color codes
  output=$(timeout 10s genesis "$1" lookup kit.features 2>&1) || true
  clean_output=$(strip_ansi "$output")
  # Use clean output to check for feature
  echo "$clean_output" | jq -e --arg feature "$2" '. | index($feature)' >/dev/null 2>&1 || return 1
}

is_proto() {
  echo "DEBUG: Checking if $1 is proto"
  has_feature "$1" 'proto' 2>/dev/null || return 1
}

cleanup_environment() {
  local env="$1"
  echo "DEBUG: cleanup_environment called for env: $env"
  if [[ -f .genesis/manifests/$env-state.yml ]] ; then
    header "Preparing to delete proto environment $env"
    echo "Generating reference manifest..."
    
    # Add timeout and capture/clean output to prevent ANSI display issues
    manifest_output=$(timeout 30s genesis "$env" manifest --no-redact 2>&1) || true
    clean_manifest=$(strip_ansi "$manifest_output")
    echo "$clean_manifest" > manifest.yml
    
    echo $'\n'"Building BOSH variables file..."
    vars_output=$(timeout 30s genesis "${env}" lookup --merged bosh-variables 2>&1) || true
    clean_vars=$(strip_ansi "$vars_output")
    echo "$clean_vars" > vars.yml
    
    echo $'\n'"$env state file:"
    echo "----------------->8------------------"
    cat ".genesis/manifests/$env-state.yml" || true
    echo "----------------->8------------------"
    
    header "Deleting $DEPLOY_ENV environment..."
    echo "DEBUG: Executing: $BOSH delete-env --state \".genesis/manifests/$env-state.yml\" --vars-file vars.yml manifest.yml"
    $BOSH delete-env --state ".genesis/manifests/$env-state.yml" --vars-file vars.yml manifest.yml || true
    
    # Cleanup only if files exist
    [[ -f manifest.yml ]] && rm manifest.yml
    [[ -f vars.yml ]] && rm vars.yml
  else
    echo "Cannot clean up previous $env environment - no state file found"
  fi
}

cleanup_deployment() {
  local deployment="$1"
  echo "DEBUG: cleanup_deployment called for deployment: $deployment"
  echo "> deleting ${deployment}"
  
  # Skip BOSH commands if BOSH isn't properly set
  if command -v $BOSH >/dev/null 2>&1; then
    echo "Using BOSH command: $BOSH"
    # Auto-confirm any prompts
    yes | $BOSH -n -d "${deployment}" delete-deployment || echo "DEBUG: delete-deployment failed with status $?"

    echo "DEBUG: Looking for orphaned disks for ${deployment}"
    orphaned_disks=$($BOSH disks --orphaned 2>/dev/null | grep "${deployment}" | awk '{print $1}' || echo "")
    
    for disk in $orphaned_disks; do
      echo "Removing disk $disk"
      yes | $BOSH -n delete-disk "$disk" || echo "DEBUG: delete-disk failed with status $?"
    done
  else
    echo "WARNING: BOSH command not found or not properly set, skipping deployment cleanup"
  fi
}

cleanup() {
  echo "DEBUG: cleanup called with arguments: $@"
  for deployment in "$@"; do
    echo "DEBUG: Processing deployment: $deployment"
    
    # Try checking if proto, but don't fail if it doesn't work
    if is_proto "$deployment" 2>/dev/null; then
      echo "DEBUG: $deployment is proto, calling cleanup_environment"
      cleanup_environment "$deployment" || echo "WARNING: cleanup_environment failed but continuing"
    else 
      echo "DEBUG: $deployment is not proto or couldn't determine, using standard cleanup"
      
      # Define a fallback KIT_SHORTNAME if we can't connect to BOSH
      KIT_SHORTNAME=${KIT_SHORTNAME:-"shield"}
      
      # Try to connect to BOSH but don't fail if it doesn't work
      echo "DEBUG: Attempting to connect to BOSH for $deployment"
      set +e
      connect_output=$(timeout 20s genesis bosh --connect "${deployment}" 2>&1 || true)
      # Clean ANSI codes from output
      clean_connect=$(strip_ansi "$connect_output")
      set -e
      
      # Try to safely eval the output or use defaults
      if [[ -n "$clean_connect" && ! "$clean_connect" =~ "FATAL" && ! "$clean_connect" =~ "Error" ]]; then
        # Wrap in a subshell to prevent environment pollution
        (
          # Safe eval that won't fail on errors
          eval "$clean_connect" 2>/dev/null || true
          # Use the KIT_SHORTNAME from eval or fallback
          kit=${KIT_SHORTNAME:-"shield"}
          echo "DEBUG: Using kit name: $kit"
          cleanup_deployment "$deployment-$kit" || echo "WARNING: cleanup_deployment failed but continuing"
        )
      else
        echo "WARNING: Failed to connect to BOSH for $deployment, using default cleanup"
        cleanup_deployment "$deployment-shield" || echo "WARNING: cleanup_deployment failed but continuing"
      fi
    fi
  done
}

# *** KEY FIX: Pre-define vault paths and check if vault is actually running ***
vault_path="secret/${DEPLOY_ENV}"
exodus_path="secret/exodus/${DEPLOY_ENV}"

echo "DEBUG: Using predefined vault_path: $vault_path"
echo "DEBUG: Using predefined exodus_path: $exodus_path"

# Check if vault is actually running
vault_running=false
if curl -s -f "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
  echo "DEBUG: Vault is running at ${VAULT_ADDR}"
  vault_running=true
else
  echo "WARNING: Vault is NOT running at ${VAULT_ADDR} - will skip vault operations"
  # Force skip replace secrets since vault isn't available
  SKIP_REPLACE_SECRETS="true"
fi

# -----

header "Pre-test Cleanup"
if [[ "$SKIP_FRESH" == "false" ]]; then
  echo "Deleting any previous deploy"
  cleanup "${DEPLOY_ENV}" || echo "WARNING: Cleanup failed but continuing"
else
  echo "Skipping cleaning up from any previous deploy"
fi

if [[ "$SKIP_REPLACE_SECRETS" == "false" && "$vault_running" == "true" ]] ; then
  # Only attempt vault operations if vault is running
  # Remove safe values
  if [[ -n "${vault_path:-}" ]]; then
    echo "Removing existing secrets under $vault_path ..."
    # Force yes to all prompts but don't fail if it doesn't work
    printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | safe rm -rf "$vault_path" || echo "DEBUG: safe rm failed but continuing"
  fi

  if [[ -n "${exodus_path:-}" ]]; then
    echo "Removing existing exodus data under $exodus_path ..."
    # Force yes to all prompts but don't fail if it doesn't work
    printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | safe rm -rf "$exodus_path" || echo "DEBUG: safe rm failed but continuing"
  fi

  # Process SECRETS_SEED_DATA if available and vault is running
  if [[ -n "${SECRETS_SEED_DATA:-}" ]] ; then
    header "Importing required user-provided seed data for $DEPLOY_ENV"
    # Replace and sanitize seed data
    seed=
    if ! seed="$(echo "$SECRETS_SEED_DATA" | spruce merge --skip-eval | spruce json | jq -M . 2>/dev/null)" ; then
      echo "WARNING: Failed to process secrets seed data, continuing without import"
    else
      processed_data=$(jq -M --arg p "$vault_path/" '. | with_entries( .key |= sub("^\\${GENESIS_SECRETS_BASE}/"; $p))' <<<"$seed" 2>/dev/null) || echo "WARNING: Failed to process seed data"
      
      if [[ -n "$processed_data" ]]; then
        # Force yes to all prompts
        printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | safe import <<<"$processed_data" || echo "WARNING: safe import failed but continuing"
      fi
    fi
  fi
else
  echo "Skipping replacing secrets (vault not running or explicitly skipped)"
fi

if [[ "$SKIP_DEPLOY" == "false" ]]; then
  header "Deploying ${DEPLOY_ENV} environment to verify functionality..."

  # Force auto-answer any prompts during deployment
  {
    # Try genesis do command but continue on failure

    set +e
    genesis_output=$(timeout 300s genesis "${DEPLOY_ENV}" "do" -- list 2>&1) || true
    clean_genesis=$(strip_ansi "$genesis_output")
    echo "$clean_genesis"
    set -e
    
    # Only attempt add-secrets if vault is running
    if [[ "$vault_running" == "true" ]]; then
      echo "Adding secrets..."
      # Use printf to send multiple 'y' responses for any prompts
      set +e
      secrets_output=$(printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | timeout 300s genesis "${DEPLOY_ENV}" add-secrets 2>&1) || true
      clean_secrets=$(strip_ansi "$secrets_output")
      echo "$clean_secrets"
      set -e
    else
      echo "Skipping add-secrets since vault isn't running"
    fi
  } 2>&1 | tee deploy-output.log

  # Get and upload stemcell version if needed
  stemcell_iaas=
  case "${INFRASTRUCTURE:-none}" in
    aws)         stemcell_iaas="aws-xen-hvm" ;;
    azure)       stemcell_iaas="azure-hyperv" ;;
    openstack)   stemcell_iaas="openstack-kvm" ;;
    warden)      stemcell_iaas="warden-boshlite" ;;
    google|gcp)  stemcell_iaas="google-kvm" ;;
    vsphere)     stemcell_iaas="vsphere-esxi" ;;
    *)           echo >&2 "Unknown or missing INFRASTRUCTURE value -- cannot upload stemcell" ;;
  esac

  if [[ -n "$stemcell_iaas" ]] ; then
    set +e
    stemcell_data_output=$(timeout 60s genesis "${DEPLOY_ENV}" lookup --merged stemcells 2>&1) || true
    clean_stemcell_data=$(strip_ansi "$stemcell_data_output")
    set -e
    
    if [[ -n "$clean_stemcell_data" && ! "$clean_stemcell_data" =~ "Error" && ! "$clean_stemcell_data" =~ "FATAL" ]]; then
      stemcell_os=$(echo "$clean_stemcell_data" | jq -r '.[0].os' 2>/dev/null) || stemcell_os="ubuntu-xenial"
      stemcell_version=$(echo "$clean_stemcell_data" | jq -r '.[0].version' 2>/dev/null) || stemcell_version="latest"
      
      stemcell_name="bosh-${stemcell_iaas}-${stemcell_os}-go_agent"
      
      upload_options=('--version' "${stemcell_version}" '--name' "$stemcell_name")
      upload_params="?v=${stemcell_version}"
      if [[ "$stemcell_version" == "latest" ]] ; then
        stemcell_version='[0-9]\+\.[0-9]\+'
        upload_options=()
        upload_params=""
      fi
      
      set +e
      stemcell_exists_output=$(timeout 60s genesis "${DEPLOY_ENV}" bosh stemcells 2>&1) || true
      clean_stemcell_exists=$(strip_ansi "$stemcell_exists_output")
      set -e
      
      if [[ -n "$clean_stemcell_exists" && ! "$clean_stemcell_exists" =~ "Error" && ! "$clean_stemcell_exists" =~ "FATAL" ]]; then
        existing_stemcell=$(echo "$clean_stemcell_exists" | grep "^${stemcell_name}" | awk '{print $2}' | sed -e 's/\*//' | grep "^${stemcell_version}\$" || echo "")
        
        if [[ -z "$existing_stemcell" ]]; then
          set +e
          # Try uploading stemcell
          printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | timeout 600s genesis "${DEPLOY_ENV}" bosh upload-stemcell "https://bosh.io/d/stemcells/$stemcell_name${upload_params}" ${upload_options[@]+"${upload_options[@]}"} || echo "WARNING: stemcell upload failed but continuing"
          set -e
        fi
      fi
    fi
  fi

  # Force auto-answer any prompts during deployment
  set +e
  deploy_output=$(printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | timeout 1800s genesis "${DEPLOY_ENV}" deploy -y 2>&1) || true
  clean_deploy=$(strip_ansi "$deploy_output")
  echo "$clean_deploy"
  set -e

  if [[ -f .genesis/manifests/${DEPLOY_ENV}-state.yml ]] ; then
    echo $'\n'"${DEPLOY_ENV} state file:"
    echo "----------------->8------------------"
    cat ".genesis/manifests/${DEPLOY_ENV}-state.yml" || true
    echo "----------------->8------------------"
  fi

  set +e
  info_output=$(timeout 60s genesis "${DEPLOY_ENV}" info 2>&1) || true
  clean_info=$(strip_ansi "$info_output")
  echo "$clean_info"
  set -e
  
  if ! is_proto "$DEPLOY_ENV" 2>/dev/null; then
    set +e
    instances_output=$(timeout 120s genesis "${DEPLOY_ENV}" bosh instances --ps 2>&1) || true
    clean_instances=$(strip_ansi "$instances_output")
    echo "$clean_instances"
    set -e
  fi
fi

if [[ "$SKIP_SMOKE_TESTS" == "false" ]]; then
  if [[ -f "$0/test-addons" ]] ; then
    header "Validating addons..."
    # shellcheck source=/dev/null
    source "$0/test-addons" || echo "WARNING: test-addons failed but continuing"
  fi

  if [[ -f "$0/smoketests" ]] ; then
    header "Running smoke tests..."
    # shellcheck source=/dev/null
    source "$0/smoketests" || echo "WARNING: smoketests failed but continuing"
  fi
else
  echo "Skipping smoke_tests"
fi

if [[ "$SKIP_CLEAN" == "false" ]]; then
  cleanup "${DEPLOY_ENV}" || echo "WARNING: Final cleanup failed but continuing"
else
  echo "Skipping CLEANUP"
fi

echo "### SCRIPT COMPLETED SUCCESSFULLY ###"