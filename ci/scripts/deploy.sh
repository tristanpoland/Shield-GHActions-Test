#!/bin/bash

# Enable strict mode
set -eu

# Setup logging
LOG_FILE="/tmp/deployment-$(date +%Y%m%d-%H%M%S).log"
exec 1> >(tee -a "$LOG_FILE")
exec 2> >(tee -a "$LOG_FILE" >&2)

# Trap errors
trap 'error_handler $? $LINENO $BASH_LINENO "$BASH_COMMAND" $(printf "::%s" ${FUNCNAME[@]:-})' ERR

# Error handler function
error_handler() {
    local exit_code=$1
    local line_no=$2
    local bash_lineno=$3
    local last_command=$4
    local func_trace=$5
    echo "Error occurred in script at line: $line_no"
    echo "Last command executed: $last_command"
    echo "Exit code: $exit_code"
    echo "Function trace: $func_trace"
    echo "Error timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    exit "$exit_code"
}

# Enhanced logging function
log() {
    local level=$1
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $*"
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }
debug() { log "DEBUG" "$@"; }

# Resource Directories
export CI_ROOT="git-ci"
export DEPLOY_ENV="${DEPLOY_ENV:-"ci-baseline"}"
export KEEP_STATE="${KEEP_STATE:-"false"}"
export VERSION_FROM="version/number"
export GIT_NAME="${GIT_NAME:-"Genesis CI Bot"}"
export GIT_EMAIL="${GIT_EMAIL:-"genesis-ci@rubidiumstudios.com"}"

# Enhanced header function with logging
header() {
    local msg=$1
    info "=================================="
    info "$msg"
    info "=================================="
    echo
    echo "================================================================================"
    echo "$msg"
    echo "--------------------------------------------------------------------------------"
    echo
}

# Enhanced bail function with logging
bail() {
    error "$*  Did you misconfigure Concourse?"
    echo >&2 "$*  Did you misconfigure Concourse?"
    exit 2
}

# Validate required environment variables
validate_env_vars() {
    info "Validating environment variables..."
    
    local required_vars=(
        "KIT_SHORTNAME:short name of this kit"
        "VAULT_URI:address for connecting to Vault"
        "VAULT_TOKEN:token for connecting to Vault"
    )
    
    local errors=0
    for var in "${required_vars[@]}"; do
        local var_name="${var%%:*}"
        local var_desc="${var##*:}"
        if [[ -z "${!var_name:-}" ]]; then
            error "$var_name must be set to the $var_desc."
            ((errors++))
        else
            debug "Found required variable $var_name"
        fi
    done
    
    # Validate TAG_ROOT and BUILD_ROOT
    if [[ -n "${TAG_ROOT:-}" && -n "${BUILD_ROOT:-}" ]]; then
        error "Cannot specify both 'TAG_ROOT' and 'BUILD_ROOT'"
        ((errors++))
    fi
    if [[ -z "${TAG_ROOT:-}" && -z "${BUILD_ROOT:-}" ]]; then
        error "Must specify one of 'TAG_ROOT' or 'BUILD_ROOT'"
        ((errors++))
    fi
    
    [[ $errors -gt 0 ]] && bail "Failed environment validation with $errors errors"
    info "Environment validation successful"
}

# Version validation function
validate_version() {
    local version=$1
    info "Validating version: $version"
    local re='^[0-9]+\.[0-9]+\.[0-9]+'
    if [[ ! "${version}" =~ $re ]]; then
        error "Invalid version format: $version"
        bail "Version must be in semver format (x.y.z)"
    fi
    debug "Version validation successful: $version"
}

# Setup workspace
setup_workspace() {
    info "Setting up workspace..."
    WORKDIR="work/${KIT_SHORTNAME}-deployments"
    
    if [[ -n "${TAG_ROOT:-}" ]]; then
        debug "Processing TAG_ROOT configuration"
        if [[ ! -f "${TAG_ROOT}/.git/ref" ]]; then
            error "Version reference file not found: ${TAG_ROOT}/.git/ref"
            bail "Version reference for $TAG_ROOT repo not found."
        fi
        
        VERSION="$(sed -e 's/^v//' < "${TAG_ROOT}/.git/ref")"
        validate_version "$VERSION"
        KIT="$KIT_SHORTNAME/$VERSION"
        info "Using kit version from TAG_ROOT: $KIT"
    else
        debug "Processing BUILD_ROOT configuration"
        if [[ ! -f "${VERSION_FROM}" ]]; then
            error "Version file not found: ${VERSION_FROM}"
            bail "Version file (${VERSION_FROM}) not found."
        fi
        
        VERSION=$(cat "${VERSION_FROM}")
        if [[ -z "${VERSION}" ]]; then
            error "Empty version file: ${VERSION_FROM}"
            bail "Version file (${VERSION_FROM}) was empty."
        }
        validate_version "$VERSION"
        KIT="$(cd "$BUILD_ROOT" && pwd)/${KIT_SHORTNAME}-${VERSION}.tar.gz"
        info "Using kit version from BUILD_ROOT: $KIT"
    fi
}

# Git setup
setup_git() {
    header "Setting up git..."
    info "Configuring git with name: $GIT_NAME and email: $GIT_EMAIL"
    git config --global user.name "$GIT_NAME"
    git config --global user.email "$GIT_EMAIL"
    debug "Git configuration complete"
}

# Vault connection
connect_vault() {
    header "Connecting to vault..."
    info "Targeting vault at: $VAULT_URI"
    if ! safe target da-vault "$VAULT_URI" -k; then
        error "Failed to target vault"
        bail "Could not target vault at $VAULT_URI"
    fi
    
    debug "Authenticating with vault token"
    if ! echo "$VAULT_TOKEN" | safe auth token; then
        error "Vault authentication failed"
        bail "Could not authenticate with vault"
    fi
    
    debug "Verifying vault connection"
    if ! safe read secret/handshake; then
        error "Failed to read vault test path"
        bail "Could not verify vault connection"
    fi
    
    info "Vault connection established successfully"
}

# Setup Genesis deployment
setup_genesis() {
    if [[ "${KEEP_STATE}" == "true" && -d "${WORKDIR}" ]] ; then
        header "Updating Genesis deployment directory for $KIT_SHORTNAME v$VERSION..."
        info "Checking Genesis version"
        genesis -v
        
        if [[ -n "${TAG_ROOT:-}" ]] ; then
            info "Fetching kit from TAG_ROOT"
            genesis -C "${WORKDIR}" fetch-kit "${KIT}"
        else
            info "Copying kit from BUILD_ROOT"
            cp -av "$KIT" "${WORKDIR}/.genesis/kits/"
        fi
    else
        header "Setting up Genesis deployment directory for $KIT_SHORTNAME v$VERSION..."
        info "Cleaning work directory"
        rm -rf work/*
        mkdir -p work/
        
        info "Checking Genesis version"
        genesis -v
        
        info "Initializing Genesis with kit: $KIT"
        genesis -C work/ init -k "$KIT" --vault da-vault
    fi
}

# Copy and validate environment files
setup_environments() {
    header "Copying test environment YAMLs from $CI_ROOT/ci/envs..."
    CI_PATH="$(cd "${CI_ROOT}" && pwd)"
    info "CI path: $CI_PATH"
    
    debug "Copying environment files"
    cp -av "$CI_PATH"/ci/envs/*.yml "${WORKDIR}/"
    
    if [[ ! -f "${WORKDIR}/${DEPLOY_ENV}.yml" ]]; then
        error "Deployment environment file not found: ${DEPLOY_ENV}.yml"
        bail "Environment $DEPLOY_ENV.yml was not found in the $CI_ROOT ci/envs/ directory"
    fi
    
    info "Creating target configuration"
    target="$(cat <<EOF
---
kit:
  name: $KIT_SHORTNAME
  version: $VERSION
EOF
)"
    
    echo
    info "Merging kit configuration"
    spruce merge --skip-eval "$CI_PATH/ci/envs/ci.yml" <(echo "$target") > "${WORKDIR}/ci.yml"
    cat "${WORKDIR}/ci.yml"
}

# Main execution
main() {
    info "Starting deployment script"
    debug "Script started with PID $$"
    
    validate_env_vars
    setup_workspace
    setup_git
    connect_vault
    setup_genesis
    setup_environments
    
    export PATH="$PATH:$CI_PATH/ci/scripts"
    info "Executing test deployment"
    cd "${WORKDIR}"
    BOSH=bosh "$CI_PATH/ci/scripts/test-deployment"
    
    info "Deployment completed successfully"
    echo
    echo "SUCCESS"
}

# Execute main function
main "$@"
