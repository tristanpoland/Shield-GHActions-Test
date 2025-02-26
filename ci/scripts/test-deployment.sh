#!/bin/bash
set -eu

# Enable extensive debugging
if [[ "${DEBUG:-false}" == "true" ]]; then
  set -x  # Enable command tracing
fi

echo "### SCRIPT STARTED ###"
echo "Running as user: $(whoami)"
echo "Current directory: $(pwd)"
echo "Environment variables:"
env | sort

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

# Force non-interactive mode for tools that respect it
export DEBIAN_FRONTEND=noninteractive
# Try to force safe to be non-interactive 
export SAFE_NONINTERACTIVE=1
export TERM=dumb

header() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "--------------------------------------------------------------------------------"
  echo
}

has_feature() {
  echo "DEBUG: Checking if $1 has feature '$2'"
  result=$(genesis "$1" lookup kit.features 2>/dev/null | jq -e --arg feature "$2" '. | index($feature)' >/dev/null 2>&1 || echo "false")
  echo "DEBUG: Feature check result: $result"
  genesis "$1" lookup kit.features 2>/dev/null | jq -e --arg feature "$2" '. | index($feature)' >/dev/null
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
    echo "DEBUG: Executing: genesis \"$env\" manifest --no-redact > manifest.yml"
    genesis "$env" manifest --no-redact > manifest.yml 2> >(tee manifest-error.log >&2)
    
    echo $'\n'"Building BOSH variables file..."
    echo "DEBUG: Executing: genesis \"${env}\" lookup --merged bosh-variables > vars.yml"
    genesis "${env}" lookup --merged bosh-variables > vars.yml 2> >(tee bosh-vars-error.log >&2)
    
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
    echo "DEBUG: State file not found: .genesis/manifests/$env-state.yml"
  fi
}

cleanup_deployment() {
  local deployment="$1"
  echo "DEBUG: cleanup_deployment called for deployment: $deployment"
  echo "> deleting ${deployment}"
  echo "DEBUG: Executing: $BOSH -n -d \"${deployment}\" delete-deployment"
  $BOSH -n -d "${deployment}" delete-deployment

  echo "DEBUG: Looking for orphaned disks for ${deployment}"
  orphaned_disks=$($BOSH disks --orphaned | grep "${deployment}" | awk '{print $1}' || echo "")
  echo "DEBUG: Orphaned disks: $orphaned_disks"
  
  for disk in $orphaned_disks; do
    echo
    echo "Removing disk $disk"
    echo "DEBUG: Executing: $BOSH -n delete-disk \"$disk\""
    $BOSH -n delete-disk "$disk"
  done
}

cleanup() {
  echo "DEBUG: cleanup called with arguments: $@"
  for deployment in "$@"; do
    echo "DEBUG: Processing deployment: $deployment"
    echo "DEBUG: Checking if $deployment is proto"
    if is_proto "$deployment" ; then
      echo "DEBUG: $deployment is proto, calling cleanup_environment"
      cleanup_environment "$deployment"
    else 
      echo "DEBUG: $deployment is not proto, using subshell for cleanup_deployment"
      (
        echo "DEBUG: Connecting to BOSH for $deployment"
        echo "DEBUG: Executing: genesis bosh --connect \"${deployment}\""
        set +e
        connect_output=$(genesis bosh --connect "${deployment}" 2>&1)
        connect_status=$?
        set -e
        echo "DEBUG: BOSH connect status: $connect_status"
        echo "DEBUG: BOSH connect output: $connect_output"
        
        if [[ $connect_status -eq 0 ]]; then
          eval "$connect_output"
          echo "DEBUG: KIT_SHORTNAME=$KIT_SHORTNAME"
          cleanup_deployment "$deployment-${KIT_SHORTNAME}"
        else
          echo "ERROR: Failed to connect to BOSH for $deployment"
          echo "$connect_output"
        fi
      )
    fi
  done
}

# Try to determine vault path before any vault operations
echo "DEBUG: Getting vault path for $DEPLOY_ENV"
# Redirecting stderr to capture potential errors
vault_path_output=$(genesis "$DEPLOY_ENV" lookup --env GENESIS_SECRETS_BASE 2>&1)
vault_path_status=$?
echo "DEBUG: vault_path command exit status: $vault_path_status"
echo "DEBUG: vault_path output: $vault_path_output"

if [[ $vault_path_status -eq 0 ]]; then
  vault_path="$vault_path_output"
else
  echo "WARNING: Failed to determine vault path on first attempt, retrying with defaults"
  # Try with default or let a failure happen later
  vault_path="${GENESIS_SECRETS_BASE:-secret/$DEPLOY_ENV}"
fi

echo "DEBUG: Getting exodus path for $DEPLOY_ENV"
exodus_path_output=$(genesis "$DEPLOY_ENV" lookup --env GENESIS_EXODUS_BASE 2>&1)
exodus_path_status=$?
echo "DEBUG: exodus_path command exit status: $exodus_path_status"
echo "DEBUG: exodus_path output: $exodus_path_output"

if [[ $exodus_path_status -eq 0 ]]; then
  exodus_path="$exodus_path_output"
else
  echo "WARNING: Failed to determine exodus path"
  # Default fallback
  exodus_path="${GENESIS_EXODUS_BASE:-secret/exodus/$DEPLOY_ENV}"
fi

vault_path="${vault_path%/}" # trim any trailing slash
echo "DEBUG: Final vault_path: $vault_path"
echo "DEBUG: Final exodus_path: $exodus_path"

# -----

header "Pre-test Cleanup"
if [[ "$SKIP_FRESH" == "false" ]]; then
  echo "Deleting any previous deploy"
  echo "DEBUG: Calling cleanup for ${DEPLOY_ENV}"
  cleanup "${DEPLOY_ENV}"
else
  echo "Skipping cleaning up from any previous deploy"
fi

if [[ -z "$vault_path" ]] ; then
  echo >&2 "Failed to determine vault path.  Cannot continue!"
  exit 2
fi

if [[ "$SKIP_REPLACE_SECRETS" == "false" ]] ; then
  # Remove safe values
  if [[ -n "${vault_path:-}" ]]; then
    echo "Removing existing secrets under $vault_path ..."
    echo "DEBUG: Executing: safe rm -rf \"$vault_path\""
    # Use yes to auto-confirm any prompts
    yes | safe rm -rf "$vault_path" || echo "DEBUG: safe rm failed with status $?"
  fi

  if [[ -n "${exodus_path:-}" ]]; then
    echo "Removing existing exodus data under $exodus_path ..."
    echo "DEBUG: Executing: safe rm -rf \"$exodus_path\""
    # Use yes to auto-confirm any prompts
    yes | safe rm -rf "$exodus_path" || echo "DEBUG: safe rm failed with status $?"
  fi

  # Remove credhub values
  if ! is_proto "$DEPLOY_ENV" ; then (
    echo "DEBUG: Getting BOSH env for $DEPLOY_ENV"
    bosh_env_output=$(genesis "$DEPLOY_ENV" lookup genesis 2>&1)
    bosh_env_status=$?
    echo "DEBUG: bosh_env command status: $bosh_env_status"
    echo "DEBUG: bosh_env output: $bosh_env_output"
    
    if [[ $bosh_env_status -eq 0 ]]; then
      bosh_env=$(echo "$bosh_env_output" | jq -r '.bosh_env // .env')
      echo "DEBUG: bosh_env: $bosh_env"
      
      [[ "$bosh_env" =~ / ]] || bosh_env="${bosh_env}/bosh"
      echo "DEBUG: adjusted bosh_env: $bosh_env"

      echo "DEBUG: Getting exodus data for $bosh_env"
      bosh_exodus_output=$(genesis "$DEPLOY_ENV" lookup --exodus-for "$bosh_env" . "{}" 2>&1)
      bosh_exodus_status=$?
      echo "DEBUG: bosh_exodus command status: $bosh_exodus_status"
      echo "DEBUG: bosh_exodus output: $bosh_exodus_output"
      
      if [[ $bosh_exodus_status -eq 0 ]]; then
        bosh_exodus="$bosh_exodus_output"
        CREDHUB_SERVER="$(echo "$bosh_exodus" | jq -r '.credhub_url // ""')"
        echo "DEBUG: CREDHUB_SERVER: $CREDHUB_SERVER"
        
        if [[ -n "$CREDHUB_SERVER" ]] ; then
          echo
          credhub_path="/${bosh_env/\//-}/${DEPLOY_ENV}-${KIT_SHORTNAME}/"
          echo "DEBUG: credhub_path: $credhub_path"
          echo "Attempting to remove credhub secrets under $credhub_path"
          
          CREDHUB_CLIENT="$(echo "$bosh_exodus" | jq -r '.credhub_username // ""')"
          CREDHUB_SECRET="$(echo "$bosh_exodus" | jq -r '.credhub_password // ""')"
          CREDHUB_CA_CERT="$(echo "$bosh_exodus" | jq -r '"\(.credhub_ca_cert)\(.ca_cert)"')"
          echo "DEBUG: CREDHUB_CLIENT: $CREDHUB_CLIENT"
          echo "DEBUG: CREDHUB_SECRET length: ${#CREDHUB_SECRET}"
          echo "DEBUG: CREDHUB_CA_CERT length: ${#CREDHUB_CA_CERT}"
          
          export CREDHUB_SERVER CREDHUB_CLIENT CREDHUB_SECRET CREDHUB_CA_CERT
          echo "DEBUG: Executing: credhub delete -p \"$credhub_path\""
          yes | credhub delete -p "$credhub_path" || echo "DEBUG: credhub delete failed with status $?"
          echo
        fi
      else
        echo "WARNING: Failed to get exodus data for $bosh_env"
      fi
    else
      echo "WARNING: Failed to determine BOSH environment"
    fi
  ) ; fi

  if [[ -n "${SECRETS_SEED_DATA:-}" ]] ; then
    header "Importing required user-provided seed data for $DEPLOY_ENV"
    echo "DEBUG: Processing SECRETS_SEED_DATA"
    # Replace and sanitize seed data
    seed=
    echo "DEBUG: Validating seed data format"
    if ! seed="$(echo "$SECRETS_SEED_DATA" | spruce merge --skip-eval | spruce json | jq -M .)" ; then
      echo >&2 "Secrets seed data is corrupt; expecting valid JSON"
      exit 1
    fi
    
    echo "DEBUG: Validating seed data keys"
    if ! bad_keys="$(jq -rM '. | with_entries( select(.key|test("^\\${GENESIS_SECRETS_BASE}/")|not))| keys| .[] | "  - \(.)"' <<<"$seed")" ; then
      echo >&2 "Failed to validate secrets seed data keys: $bad_keys"
      exit 1
    fi
    
    if [[ -n "$bad_keys" ]] ; then
      echo >&2 "Secrets seed data contains bad keys.  All keys must start with "
      echo >&2 "'\${GENESIS_SECRETS_BASE}/', and the following do not:"
      echo >&2 "$bad_keys"
      exit 1
    fi
    
    echo "DEBUG: Processing seed data for import"
    processed_data=
    if ! processed_data="$( jq -M --arg p "$vault_path/" '. | with_entries( .key |= sub("^\\${GENESIS_SECRETS_BASE}/"; $p))' <<<"$seed")" ; then
      echo >&2 "Failed to import secret seed data"
      exit 1
    fi
    
    echo "DEBUG: Importing processed seed data into safe"
    echo "DEBUG: Processed data (first 100 chars): ${processed_data:0:100}..."
    if ! yes | safe import <<<"$processed_data" ; then
      echo >&2 "Failed to import secrets seed data"
      exit 1
    fi
  fi
else
  echo "Skipping replacing secrets"
fi

if [[ "$SKIP_DEPLOY" == "false" ]]; then
  header "Deploying ${DEPLOY_ENV} environment to verify functionality..."
  echo "DEBUG: Executing: genesis \"${DEPLOY_ENV}\" \"do\" -- list"
  genesis "${DEPLOY_ENV}" "do" -- list
  
  echo "DEBUG: Executing: genesis \"${DEPLOY_ENV}\" add-secrets"
  # Use yes to answer any prompts from add-secrets
  yes | genesis "${DEPLOY_ENV}" add-secrets || echo "DEBUG: add-secrets failed with status $?"

  # get and upload stemcell version if needed (handled by bosh cli if version and name are supplied)
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
    echo "DEBUG: Getting stemcell data for $DEPLOY_ENV"
    stemcell_data_output=$(genesis "${DEPLOY_ENV}" lookup --merged stemcells 2>&1)
    stemcell_data_status=$?
    echo "DEBUG: stemcell_data command status: $stemcell_data_status"
    echo "DEBUG: stemcell_data output: $stemcell_data_output"
    
    if [[ $stemcell_data_status -eq 0 ]]; then
      stemcell_data="$stemcell_data_output"
      stemcell_os="$(jq -r '.[0].os' <<<"$stemcell_data")"
      stemcell_version="$(jq -r '.[0].version' <<<"$stemcell_data")"
      echo "DEBUG: stemcell_os: $stemcell_os"
      echo "DEBUG: stemcell_version: $stemcell_version"
      
      stemcell_name="bosh-${stemcell_iaas}-${stemcell_os}-go_agent"
      echo "DEBUG: stemcell_name: $stemcell_name"
      
      upload_options=('--version' "${stemcell_version}" '--name' "$stemcell_name")
      upload_params="?v=${stemcell_version}"
      if [[ "$stemcell_version" == "latest" ]] ; then
        stemcell_version='[0-9]\+\.[0-9]\+'
        upload_options=()
        upload_params=""
      fi
      
      echo "DEBUG: Checking if stemcell exists"
      stemcell_exists_output=$(genesis "${DEPLOY_ENV}" bosh stemcells 2>&1)
      stemcell_exists_status=$?
      echo "DEBUG: stemcell_exists command status: $stemcell_exists_status"
      echo "DEBUG: stemcell_exists output: $stemcell_exists_output"
      
      if [[ $stemcell_exists_status -eq 0 ]]; then
        existing_stemcell=$(echo "$stemcell_exists_output" | grep "^${stemcell_name}" | awk '{print $2}' | sed -e 's/\*//' | grep "^${stemcell_version}\$" || echo "")
        echo "DEBUG: existing_stemcell: $existing_stemcell"
        
        if [[ -z "$existing_stemcell" ]]; then
          echo "DEBUG: Stemcell not found, uploading"
          echo "DEBUG: Executing: genesis \"${DEPLOY_ENV}\" bosh upload-stemcell with options: ${upload_options[*]}"
          genesis "${DEPLOY_ENV}" bosh upload-stemcell "https://bosh.io/d/stemcells/$stemcell_name${upload_params}" ${upload_options[@]+"${upload_options[@]}"}
        else
          echo "DEBUG: Stemcell already exists, skipping upload"
        fi
      else
        echo "WARNING: Failed to check for existing stemcells"
      fi
    else
      echo "WARNING: Failed to get stemcell data"
    fi
  fi

  echo "DEBUG: Executing: genesis \"${DEPLOY_ENV}\" deploy -y"
  genesis "${DEPLOY_ENV}" deploy -y

  if [[ -f .genesis/manifests/${DEPLOY_ENV}-state.yml ]] ; then
    echo $'\n'"${DEPLOY_ENV} state file:"
    echo "----------------->8------------------"
    cat ".genesis/manifests/${DEPLOY_ENV}-state.yml"
    echo "----------------->8------------------"
  else
    echo "DEBUG: State file not found: .genesis/manifests/${DEPLOY_ENV}-state.yml"
  fi

  echo "DEBUG: Executing: genesis \"${DEPLOY_ENV}\" info"
  genesis "${DEPLOY_ENV}" info
  
  if ! is_proto "$DEPLOY_ENV" ; then
    echo "DEBUG: Executing: genesis \"${DEPLOY_ENV}\" bosh instances --ps"
    genesis "${DEPLOY_ENV}" bosh instances --ps
  fi
fi

if [[ "$SKIP_SMOKE_TESTS" == "false" ]]; then
  if [[ -f "$0/test-addons" ]] ; then
    header "Validating addons..."
    echo "DEBUG: Sourcing $0/test-addons"
    # shellcheck source=/dev/null
    source "$0/test-addons"
  else
    echo "DEBUG: No test-addons file found at $0/test-addons"
  fi

  if [[ -f "$0/smoketests" ]] ; then
    header "Running smoke tests..."
    echo "DEBUG: Sourcing $0/smoketests"
    # shellcheck source=/dev/null
    source "$0/smoketests"
  else
    echo "DEBUG: No smoketests file found at $0/smoketests"
  fi
else
  echo "Skipping smoke_tests"
fi

if [[ "$SKIP_CLEAN" == "false" ]]; then
  echo "DEBUG: Executing final cleanup for ${DEPLOY_ENV}"
  cleanup "${DEPLOY_ENV}"
else
  echo "Skipping CLEANUP"
fi

echo "### SCRIPT COMPLETED SUCCESSFULLY ###"