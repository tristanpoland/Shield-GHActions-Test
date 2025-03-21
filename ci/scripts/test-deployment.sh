#!/bin/bash
set -eux

DEPLOY_ENV=${DEPLOY_ENV:-"ci-baseline"}
SKIP_FRESH=${SKIP_FRESH:-"false"}
SKIP_REPLACE_SECRETS=${SKIP_REPLACE_SECRETS:-"false"}
SKIP_DEPLOY=${SKIP_DEPLOY:-"false"}
SKIP_SMOKE_TESTS=${SKIP_SMOKE_TESTS:-"false"}
SKIP_CLEAN=${SKIP_CLEAN:-"false"}

header() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "--------------------------------------------------------------------------------"
  echo
}

has_feature() {
	genesis "$1" lookup kit.features 2>/dev/null | jq -e --arg feature "$2" '. | index($feature)' >/dev/null
}

is_proto() {
	has_feature "$1" 'proto' # This will need to be changed in v2.8.0
}

cleanup_environment() {
	local env="$1"
	if [[ -f .genesis/manifests/$env-state.yml ]] ; then
		header "Preparing to delete proto environment $env"
		echo "Generating reference manifest..."
		genesis "$env" manifest --no-redact > manifest.yml 2>/dev/null
		echo $'\n'"Building BOSH variables file..."
		genesis "${env}" lookup --merged bosh-variables > vars.yml 2>/dev/null
		echo $'\n'"$env state file:"
		echo "----------------->8------------------"
		cat ".genesis/manifests/$env-state.yml"
		echo "----------------->8------------------"
		header "Deleting $DEPLOY_ENV environment..."
		$BOSH delete-env --state ".genesis/manifests/$env-state.yml" --vars-file vars.yml manifest.yml
		rm manifest.yml
		rm vars.yml
	else
		echo "Cannot clean up previous $env environment - no state file found"
	fi
}

cleanup_deployment() {
	local deployment="$1"
	echo "> deleting ${deployment}"
	$BOSH -n -d "${deployment}" delete-deployment

	for disk in $($BOSH disks --orphaned | grep "${deployment}" | awk '{print $1}'); do
		echo
		echo "Removing disk $disk"
		$BOSH -n delete-disk "$disk"
	done
}

cleanup() {
	for deployment in "$@"; do
		if is_proto "$deployment" ; then
			cleanup_environment "$deployment"
		else ( # run in a subshell to prevent pollution
			eval "$(genesis bosh --connect "${deployment}" 2>/dev/null)"
			cleanup_deployment "$deployment-${KIT_SHORTNAME}"
		); fi
	done
}

vault_path="$(genesis "$DEPLOY_ENV" lookup --env GENESIS_SECRETS_BASE)"
exodus_path="$(genesis "$DEPLOY_ENV" lookup --env GENESIS_EXODUS_BASE)"
vault_path="${vault_path%/}" # trim any trailing slash
# -----

header "Pre-test Cleanup"
if [[ "$SKIP_FRESH" == "false" ]]; then
	echo "Deleting any previous deploy"
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
	[[ -n "${vault_path:-}" ]] && \
		echo "Removing existing secrets under $vault_path ..." && \
		safe rm -rf "$vault_path" && true
	[[ -n "${exodus_path:-}" ]] && \
		echo "Removing existing exodus data under $exodus_path ..." && \
		safe rm -rf "$exodus_path" && true

	# Remove credhub values
	if ! is_proto "$DEPLOY_ENV" ; then (
		bosh_env="$(genesis "$DEPLOY_ENV" lookup genesis 2>/dev/null | jq -r '.bosh_env // .env')"
		[[ "$bosh_env" =~ / ]] || bosh_env="${bosh_env}/bosh"

		bosh_exodus="$(genesis "$DEPLOY_ENV" lookup --exodus-for "$bosh_env" . "{}" 2>/dev/null)"
		CREDHUB_SERVER="$(jq -r '.credhub_url // ""' <<<"$bosh_exodus")"
		if [[ -n "$CREDHUB_SERVER" ]] ; then
			echo
			echo "Attempting to remove credhub secrets under /${bosh_env/\//-}/${DEPLOY_ENV}-${KIT_SHORTNAME}/"
			CREDHUB_CLIENT="$(jq -r '.credhub_username // ""' <<<"$bosh_exodus")"
			CREDHUB_SECRET="$(jq -r '.credhub_password // ""' <<<"$bosh_exodus")"
			CREDHUB_CA_CERT="$(jq -r '"\(.credhub_ca_cert)\(.ca_cert)"' <<<"$bosh_exodus")"
			export CREDHUB_SERVER CREDHUB_CLIENT CREDHUB_SECRET CREDHUB_CA_CERT
			credhub delete -p "/${bosh_env/\//-}/${DEPLOY_ENV}-${KIT_SHORTNAME}/"
			echo
		fi
	) ; fi

  if [[ -n "$SECRETS_SEED_DATA" ]] ; then

    header "Importing required user-provided seed data for $DEPLOY_ENV"
    # Replace and sanitize seed data
    seed=
    if ! seed="$(echo "$SECRETS_SEED_DATA" | spruce merge --skip-eval | spruce json | jq -M .)" ; then
      echo >&2 "Secrets seed data is corrupt; expecting valid JSON"
      exit 1
    fi
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
    processed_data=
    if ! processed_data="$( jq -M --arg p "$vault_path/" '. | with_entries( .key |= sub("^\\${GENESIS_SECRETS_BASE}/"; $p))' <<<"$seed")" ; then
      echo >&2 "Failed to import secret seed data"
      exit 1
    fi
    if ! safe import <<<"$processed_data" ; then
      echo >&2 "Failed to import secrets seed data"
      exit 1
    fi
  fi
else
	echo "Skipping replacing secrets"
fi

if [[ "$SKIP_DEPLOY" == "false" ]]; then
	header "Deploying ${DEPLOY_ENV} environment to verify functionality..."
	genesis "${DEPLOY_ENV}" "do" -- list
	genesis "${DEPLOY_ENV}" add-secrets

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
		stemcell_data="$(genesis "${DEPLOY_ENV}" lookup --merged stemcells)"
		stemcell_os="$(jq -r '.[0].os' <<<"$stemcell_data")"
		stemcell_version="$(jq -r '.[0].version' <<<"$stemcell_data")"
		stemcell_name="bosh-${stemcell_iaas}-${stemcell_os}-go_agent"
		upload_options=('--version' "${stemcell_version}" '--name' "$stemcell_name")
		upload_params="?v=${stemcell_version}"
		if [[ "$stemcell_version" == "latest" ]] ; then
			stemcell_version='[0-9]\+\.[0-9]\+'
			upload_options=()
			upload_params=""
		fi
		if ! genesis "${DEPLOY_ENV}" bosh stemcells 2>/dev/null \
		   | grep "^${stemcell_name}" \
		   | awk '{print $2}' | sed -e 's/\*//' \
		   | grep "^${stemcell_version}\$" ; then
			genesis "${DEPLOY_ENV}" bosh upload-stemcell "https://bosh.io/d/stemcells/$stemcell_name${upload_params}" ${upload_options[@]+"${upload_options[@]}"}
		fi
	fi

	genesis "${DEPLOY_ENV}" deploy -y

	if [[ -f .genesis/manifests/${DEPLOY_ENV}-state.yml ]] ; then
		echo $'\n'"${DEPLOY_ENV} state file:"
		echo "----------------->8------------------"
		cat ".genesis/manifests/${DEPLOY_ENV}-state.yml"
		echo "----------------->8------------------"
	fi

	genesis "${DEPLOY_ENV}" info
	if ! is_proto "$DEPLOY_ENV" ; then
		genesis "${DEPLOY_ENV}" bosh instances --ps
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
	cleanup "${DEPLOY_ENV}"
else
	echo "Skipping CLEANUP"
fi