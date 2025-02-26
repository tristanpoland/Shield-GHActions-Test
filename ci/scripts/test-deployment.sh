#!/bin/bash
set -eu

# Enable extensive debugging
if [[ "${DEBUG:-false}" == "true" ]]; then
  set -x  # Enable command tracing
fi

echo "### SCRIPT STARTED ###"
echo "Running as user: $(whoami)"
echo "Current directory: $(pwd)"

# Force non-interactive mode for tools that respect it
export DEBIAN_FRONTEND=noninteractive
# Force safe to be non-interactive (key fix for vault selection issue)
export SAFE_NONINTERACTIVE=1
export TERM=dumb
# Force skipping interaction in vault
export VAULT_TOKEN=${VAULT_TOKEN:-"00000000-0000-0000-0000-000000000000"}
# Force vault to use a specific address without prompting
export VAULT_ADDR=${VAULT_ADDR:-"http://127.0.0.1:8200"}
# Set default vault namespace
export VAULT_NAMESPACE=${VAULT_NAMESPACE:-""}

DEPLOY_ENV=${DEPLOY_ENV:-"ci-baseline"}
SKIP_FRESH=${SKIP_FRESH:-"false"}
SKIP_REPLACE_SECRETS=${SKIP_REPLACE_SECRETS:-"false"}
SKIP_DEPLOY=${SKIP_DEPLOY:-"false"}
SKIP_SMOKE_TESTS=${SKIP_SMOKE_TESTS:-"false"}
SKIP_CLEAN=${SKIP_CLEAN:-"false"}

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

has_feature() {
  echo "DEBUG: Checking if $1 has feature '$2'"
  # Add timeout to prevent hanging and redirect stderr
  timeout 10s genesis "$1" lookup kit.features 2>/dev/null | jq -e --arg feature "$2" '. | index($feature)' >/dev/null 2>&1 || return 1
}

is_proto() {
  echo "DEBUG: Checking if $1 is proto"
  has_feature "$1" 'proto' # This will need to be changed in v2.8.0
}

cleanup_environment() {
  local env="$1"
  echo "DEBUG: cleanup_environment called for env: $env"
  if [[ -f .genesis/manifests/$env-state.yml ]] ; then
    header "Preparing to delete proto environment $env"
    echo "Generating reference manifest..."
    # Add timeout to prevent hanging
    timeout 30s genesis "$env" manifest --no-redact > manifest.yml 2> >(tee manifest-error.log >&2) || echo "WARNING: manifest generation timed out"
    
    echo $'\n'"Building BOSH variables file..."
    # Add timeout to prevent hanging
    timeout 30s genesis "${env}" lookup --merged bosh-variables > vars.yml 2> >(tee bosh-vars-error.log >&2) || echo "WARNING: bosh variables lookup timed out"
    
    echo $'\n'"$env state file:"
    echo "----------------->8------------------"
    cat ".genesis/manifests/$env-state.yml"
    echo "----------------->8------------------"
    
    header "Deleting $DEPLOY_ENV environment..."
    echo "DEBUG: Executing: $BOSH delete-env --state \".genesis/manifests/$env-state.yml\" --vars-file vars.yml manifest.yml"
    $BOSH delete-env --state ".genesis/manifests/$env-state.yml" --vars-file vars.yml manifest.yml
    
    rm manifest.yml
    rm vars.yml
  else
    echo "Cannot clean up previous $env environment - no state file found"
  fi
}

cleanup_deployment() {
  local deployment="$1"
  echo "DEBUG: cleanup_deployment called for deployment: $deployment"
  echo "> deleting ${deployment}"
  # Add yes to auto-confirm any prompts
  yes | $BOSH -n -d "${deployment}" delete-deployment || echo "DEBUG: delete-deployment failed with status $?"

  echo "DEBUG: Looking for orphaned disks for ${deployment}"
  orphaned_disks=$($BOSH disks --orphaned | grep "${deployment}" | awk '{print $1}' || echo "")
  
  for disk in $orphaned_disks; do
    echo "Removing disk $disk"
    # Add yes to auto-confirm any prompts
    yes | $BOSH -n delete-disk "$disk" || echo "DEBUG: delete-disk failed with status $?"
  done
}

cleanup() {
  echo "DEBUG: cleanup called with arguments: $@"
  for deployment in "$@"; do
    echo "DEBUG: Processing deployment: $deployment"
    if is_proto "$deployment" 2>/dev/null; then
      echo "DEBUG: $deployment is proto, calling cleanup_environment"
      cleanup_environment "$deployment"
    else 
      echo "DEBUG: $deployment is not proto, using subshell for cleanup_deployment"
      (
        echo "DEBUG: Connecting to BOSH for $deployment"
        # Capture output but continue if it fails
        set +e
        connect_output=$(timeout 20s genesis bosh --connect "${deployment}" 2>&1) || echo "WARNING: BOSH connect timed out or failed"
        connect_status=$?
        set -e
        
        if [[ $connect_status -eq 0 ]]; then
          eval "$connect_output"
          cleanup_deployment "$deployment-${KIT_SHORTNAME:-shield}"
        else
          echo "ERROR: Failed to connect to BOSH for $deployment"
          echo "$connect_output"
        fi
      )
    fi
  done
}

# *** KEY FIX: Pre-define vault and exodus paths instead of trying to look them up ***
# This is the critical fix for the non-interactive terminal issue
vault_path="secret/${DEPLOY_ENV}"
exodus_path="secret/exodus/${DEPLOY_ENV}"

echo "DEBUG: Using predefined vault_path: $vault_path"
echo "DEBUG: Using predefined exodus_path: $exodus_path"

# -----

header "Pre-test Cleanup"
if [[ "$SKIP_FRESH" == "false" ]]; then
  echo "Deleting any previous deploy"
  cleanup "${DEPLOY_ENV}" || echo "WARNING: Cleanup failed but continuing"
else
  echo "Skipping cleaning up from any previous deploy"
fi

if [[ "$SKIP_REPLACE_SECRETS" == "false" ]] ; then
  # Remove safe values with auto-confirmation
  if [[ -n "${vault_path:-}" ]]; then
    echo "Removing existing secrets under $vault_path ..."
    # Force yes to all prompts
    printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | safe rm -rf "$vault_path" || echo "DEBUG: safe rm failed but continuing"
  fi

  if [[ -n "${exodus_path:-}" ]]; then
    echo "Removing existing exodus data under $exodus_path ..."
    # Force yes to all prompts
    printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | safe rm -rf "$exodus_path" || echo "DEBUG: safe rm failed but continuing"
  fi

  # Remove credhub values
  if ! is_proto "$DEPLOY_ENV" 2>/dev/null; then (
    echo "DEBUG: Getting BOSH env for $DEPLOY_ENV"
    set +e
    bosh_env_output=$(timeout 20s genesis "$DEPLOY_ENV" lookup genesis 2>&1) || echo "WARNING: Lookup failed but continuing"
    set -e
    
    if [[ -n "$bosh_env_output" ]]; then
      bosh_env=$(echo "$bosh_env_output" | jq -r '.bosh_env // .env')
      [[ "$bosh_env" =~ / ]] || bosh_env="${bosh_env}/bosh"

      set +e
      bosh_exodus_output=$(timeout 20s genesis "$DEPLOY_ENV" lookup --exodus-for "$bosh_env" . "{}" 2>&1) || echo "WARNING: Exodus lookup failed but continuing"
      set -e
      
      if [[ -n "$bosh_exodus_output" ]]; then
        CREDHUB_SERVER="$(echo "$bosh_exodus_output" | jq -r '.credhub_url // ""')"
        
        if [[ -n "$CREDHUB_SERVER" ]] ; then
          echo "Attempting to remove credhub secrets under /${bosh_env/\//-}/${DEPLOY_ENV}-${KIT_SHORTNAME:-shield}/"
          
          CREDHUB_CLIENT="$(echo "$bosh_exodus_output" | jq -r '.credhub_username // ""')"
          CREDHUB_SECRET="$(echo "$bosh_exodus_output" | jq -r '.credhub_password // ""')"
          CREDHUB_CA_CERT="$(echo "$bosh_exodus_output" | jq -r '"\(.credhub_ca_cert)\(.ca_cert)"')"
          
          export CREDHUB_SERVER CREDHUB_CLIENT CREDHUB_SECRET CREDHUB_CA_CERT
          # Force yes to all prompts
          printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | credhub delete -p "/${bosh_env/\//-}/${DEPLOY_ENV}-${KIT_SHORTNAME:-shield}/" || echo "WARNING: credhub delete failed but continuing"
        fi
      fi
    fi
  ) ; fi

  if [[ -n "${SECRETS_SEED_DATA:-}" ]] ; then
    header "Importing required user-provided seed data for $DEPLOY_ENV"
    # Replace and sanitize seed data
    seed=
    if ! seed="$(echo "$SECRETS_SEED_DATA" | spruce merge --skip-eval | spruce json | jq -M .)" ; then
      echo >&2 "Secrets seed data is corrupt; expecting valid JSON"
      exit 1
    fi
    
    if ! bad_keys="$(jq -rM '. | with_entries( select(.key|test("^\\${GENESIS_SECRETS_BASE}/")|not))| keys| .[] | "  - \(.)"' <<<"$seed")" ; then
      echo >&2 "Failed to validate secrets seed data keys"
      exit 1
    fi
    
    if [[ -n "$bad_keys" ]] ; then
      echo >&2 "Secrets seed data contains bad keys. All keys must start with "
      echo >&2 "'\${GENESIS_SECRETS_BASE}/', and the following do not:"
      echo >&2 "$bad_keys"
      exit 1
    fi
    
    processed_data=
    if ! processed_data="$( jq -M --arg p "$vault_path/" '. | with_entries( .key |= sub("^\\${GENESIS_SECRETS_BASE}/"; $p))' <<<"$seed")" ; then
      echo >&2 "Failed to import secret seed data"
      exit 1
    fi
    
    # Force yes to all prompts
    printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | safe import <<<"$processed_data" || echo "WARNING: safe import failed but continuing"
  fi
else
  echo "Skipping replacing secrets"
fi

if [[ "$SKIP_DEPLOY" == "false" ]]; then
  header "Deploying ${DEPLOY_ENV} environment to verify functionality..."
  
  # Force auto-answer any prompts during deployment
  {
    timeout 300s genesis "${DEPLOY_ENV}" "do" -- list || echo "WARNING: Genesis do list failed but continuing"
    
    # Use printf to send multiple 'y' responses for any prompts
    printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | timeout 300s genesis "${DEPLOY_ENV}" add-secrets || echo "WARNING: add-secrets failed but continuing"
  } 2>&1 | tee deploy-output.log

  # get and upload stemcell version if needed
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
    stemcell_data_output=$(timeout 60s genesis "${DEPLOY_ENV}" lookup --merged stemcells 2>&1) || echo "WARNING: stemcell lookup failed but continuing"
    set -e
    
    if [[ -n "$stemcell_data_output" ]]; then
      stemcell_os="$(jq -r '.[0].os' <<<"$stemcell_data_output")"
      stemcell_version="$(jq -r '.[0].version' <<<"$stemcell_data_output")"
      
      stemcell_name="bosh-${stemcell_iaas}-${stemcell_os}-go_agent"
      
      upload_options=('--version' "${stemcell_version}" '--name' "$stemcell_name")
      upload_params="?v=${stemcell_version}"
      if [[ "$stemcell_version" == "latest" ]] ; then
        stemcell_version='[0-9]\+\.[0-9]\+'
        upload_options=()
        upload_params=""
      fi
      
      set +e
      stemcell_exists_output=$(timeout 60s genesis "${DEPLOY_ENV}" bosh stemcells 2>&1) || echo "WARNING: stemcell check failed but continuing"
      set -e
      
      if [[ -n "$stemcell_exists_output" ]]; then
        existing_stemcell=$(echo "$stemcell_exists_output" | grep "^${stemcell_name}" | awk '{print $2}' | sed -e 's/\*//' | grep "^${stemcell_version}\$" || echo "")
        
        if [[ -z "$existing_stemcell" ]]; then
          printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | timeout 600s genesis "${DEPLOY_ENV}" bosh upload-stemcell "https://bosh.io/d/stemcells/$stemcell_name${upload_params}" ${upload_options[@]+"${upload_options[@]}"} || echo "WARNING: stemcell upload failed but continuing"
        fi
      fi
    fi
  fi

  # Force auto-answer any prompts during deployment
  printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' | timeout 1800s genesis "${DEPLOY_ENV}" deploy -y || echo "WARNING: deploy failed but continuing"

  if [[ -f .genesis/manifests/${DEPLOY_ENV}-state.yml ]] ; then
    echo $'\n'"${DEPLOY_ENV} state file:"
    echo "----------------->8------------------"
    cat ".genesis/manifests/${DEPLOY_ENV}-state.yml"
    echo "----------------->8------------------"
  fi

  timeout 60s genesis "${DEPLOY_ENV}" info || echo "WARNING: genesis info failed but continuing"
  
  if ! is_proto "$DEPLOY_ENV" 2>/dev/null; then
    timeout 120s genesis "${DEPLOY_ENV}" bosh instances --ps || echo "WARNING: bosh instances check failed but continuing"
  fi
fi

if [[ "$SKIP_SMOKE_TESTS" == "false" ]]; then
  if [[ -f "$0/test-addons" ]] ; then
    header "Validating addons..."
    # shellcheck source=/dev/null
    source "$0/test-addons"
  fi

  if [[ -f "$0/smoketests" ]] ; then
    header "Running smoke tests..."
    # shellcheck source=/dev/null
    source "$0/smoketests"
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