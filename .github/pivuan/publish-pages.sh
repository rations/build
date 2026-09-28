#!/bin/bash
#
# Update the Pivuan apt repository on the gh-pages branch of PIVUAN_REPO: clone it, add the
# packages (publish-apt.sh), and replace the branch with one new commit.
#
# Usage: publish-pages.sh <revision> <deb-dir>...     (arguments as for publish-apt.sh)
# Environment:
#   PIVUAN_REPO                owner/name of the repository whose gh-pages branch is the site
#   REPO_TOKEN                 token with Contents read/write on PIVUAN_REPO
#   GNUPGHOME, PIVUAN_APT_*    as for publish-apt.sh
#   PIVUAN_PAGES_REMOTE        optional: the remote URL (default: GitHub with REPO_TOKEN)
#   PIVUAN_PAGES_LIST          optional: file to write the published "package version" list to
#
# The image build and the audio-app build both publish here. The push is a force push
# (old package versions leave the branch instead of piling up in its history), leased on
# the commit that was cloned: if the other workflow published in between, the push is
# refused rather than dropping its packages. Run the job again then.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
revision="${1:?usage: publish-pages.sh <revision> <deb-dir>...}"
shift
remote="${PIVUAN_PAGES_REMOTE:-https://x-access-token:${REPO_TOKEN:?REPO_TOKEN is not set}@github.com/${PIVUAN_REPO:?PIVUAN_REPO is not set}.git}"
site="$(mktemp -d)"
trap 'rm -rf "${site}"' EXIT

base="$(git ls-remote "${remote}" refs/heads/gh-pages | cut -f1)"
if [[ -n "${base}" ]]; then
	git clone --quiet --depth 1 --branch gh-pages "${remote}" "${site}"
	[[ "$(git -C "${site}" rev-parse HEAD)" == "${base}" ]] || {
		echo "::error::gh-pages moved while it was being cloned; run the job again" >&2
		exit 1
	}
	rm -rf "${site}/.git"
fi

bash "${here}/publish-apt.sh" "${site}" "${revision}" "$@"

cd "${site}"
git init --quiet -b gh-pages
git add -A
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
	commit --quiet -m "Pivuan apt repository ${revision}${GITHUB_RUN_ID:+ (${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID})}"
# An empty lease value means "the branch must not exist yet".
if ! git push --quiet --force-with-lease="gh-pages:${base}" "${remote}" gh-pages; then
	echo "::error::gh-pages changed since it was cloned (another Pivuan workflow published); run the job again" >&2
	exit 1
fi

awk '/^Package: /{p=$2} /^Version: /{print p " " $2}' dists/*/main/binary-*/Packages | sort > "${PIVUAN_PAGES_LIST:-/dev/stdout}"
