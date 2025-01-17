#!/usr/bin/env bash
set -e
set -o pipefail

export VERSION_FROM="version/number"
export GIT_NAME="${GIT_NAME:-"Genesis CI Bot"}"
export GIT_EMAIL="${GIT_EMAIL:-"genesis-ci@rubidiumstudios.com"}"

header() {
  echo
  echo "================================================================================"
  echo "$1"
  echo "--------------------------------------------------------------------------------"
  echo
}

bail() {
  echo >&2 "$*  Did you misconfigure Concourse?"
  exit 2
}
test -n "${KIT_SHORTNAME:-}"         || bail "KIT_SHORTNAME must be set to the short name of this kit."
test -n "${RELEASE_NOTES_FILE:-}"    || bail "RELEASE_NOTES_FILE must be set to the filename for the release notes."
test -n "${RELEASE_NOTES_WEB_URL:-}" || bail "RELEASE_NOTES_WEB_URL must be set to the release notes gist edit URL."

test -f "${VERSION_FROM}"            || bail "Version file (${VERSION_FROM}) not found."
VERSION=$(cat "${VERSION_FROM}")
test -n "${VERSION}"                 || bail "Version file (${VERSION_FROM}) was empty."

git-ci/ci/scripts/release-notes "$VERSION" "git" "git-latest-tag" "release-notes/$RELEASE_NOTES_FILE"
cat "release-notes/$RELEASE_NOTES_FILE"

header "Uploading the release notes"

git config --global user.name  "$GIT_NAME"
git config --global user.email "$GIT_EMAIL"

git -C release-notes add "$RELEASE_NOTES_FILE"
git -C release-notes commit -m "Updated release notes for $KIT_SHORTNAME-genesis-kit v$VERSION"

echo $'\n'"The release notes can be edited at ${RELEASE_NOTES_WEB_URL}"
