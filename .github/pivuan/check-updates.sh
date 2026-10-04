#!/bin/bash
#
# Say which pinned Pivuan packages have something newer upstream. Run it before the
# "Pivuan audio apps" and "XLibre for Pivuan" workflows; it only reports and changes nothing.
#
#   apps.conf     each app's commit against the head of its master branch, with the new commits
#   xlibre.conf   each XLibre tag against the newest release tag, and the packaging commit
#                 against the head of the packaging repository
#
# Not checked: vstbridge (its workflow always builds the head of rations/vstbridge's arm64
# branch) and the kernel ("Pivuan kernel pin" moves that pin every week).
#
# Usage: check-updates.sh [xlibre.conf]
#   xlibre.conf defaults to ../pivuan/xlibre/xlibre.conf next to this checkout of rations/build,
#   or else the copy on rations/pivuan master.
# Needs git, curl and python3. Set GITHUB_TOKEN to raise GitHub's API limit (60 requests an hour
# without it; each app with new commits uses one).
# Exit status: 0 when everything is up to date, 1 when something is newer, 2 on an error.
#
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apps_conf="${here}/apps/apps.conf"
xlibre_conf="${1:-${here}/../../../pivuan/xlibre/xlibre.conf}"
newer=0
failed=0

# Prints "- <sha> <subject>" for each commit after $2 up to $3 in GitHub repository $1.
commits_between() {
	local auth=()
	[[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	curl -fsS "${auth[@]}" "https://api.github.com/repos/$1/compare/$2...$3" 2>/dev/null |
		python3 -c 'import json, sys
for c in json.load(sys.stdin)["commits"]:
    print("      " + c["sha"][:7] + "  " + c["commit"]["message"].splitlines()[0])' 2>/dev/null ||
		echo "      (could not list the commits)"
}

# The commit a branch (or HEAD) of a repository points to.
remote_head() {
	git ls-remote "$1" "$2" 2>/dev/null | awk 'NR == 1 { print $1 }'
}

echo "Audio apps (${apps_conf#"${here}/"}):"
while read -r pkg url commit ver rev; do
	head="$(remote_head "${url}" refs/heads/master)"
	if [[ -z "${head}" ]]; then
		echo "  ${pkg}: could not read master of ${url}"
		failed=1
	elif [[ "${head}" == "${commit}" ]]; then
		echo "  ${pkg} ${ver}-pivuan${rev}: up to date"
	else
		newer=1
		echo "  ${pkg} ${ver}-pivuan${rev}: master is newer, ${head}"
		commits_between "${url#https://github.com/}" "${commit}" "${head}"
	fi
done < <(awk '!/^#/ && NF' "${apps_conf}")

echo
if [[ -f "${xlibre_conf}" ]]; then
	echo "XLibre (${xlibre_conf}):"
	xlibre="$(cat "${xlibre_conf}")"
else
	echo "XLibre (rations/pivuan master, xlibre/xlibre.conf):"
	xlibre="$(curl -fsS https://raw.githubusercontent.com/rations/pivuan/master/xlibre/xlibre.conf)" || {
		echo "  could not read xlibre.conf"
		failed=1
	}
fi
while read -r name source tag _ packaging packaging_commit version; do
	# Release tags are <prefix><version>, e.g. xlibre-xserver-25.2.2; release candidates are left out.
	prefix="$(sed -E 's/[0-9]+(\.[0-9]+)*$//' <<< "${tag}")"
	latest="$(git ls-remote --tags --refs "${source}" "refs/tags/${prefix}*" 2>/dev/null |
		sed 's|.*refs/tags/||' | grep -E "^${prefix}[0-9]+(\.[0-9]+)*$" | sort -V | tail -1)"
	if [[ -z "${latest}" ]]; then
		echo "  ${name}: could not read the tags of ${source}"
		failed=1
	elif [[ "${latest}" == "${tag}" ]]; then
		echo "  ${name} ${version}: ${tag} is the newest release"
	else
		newer=1
		echo "  ${name} ${version}: newer release ${latest} (pinned ${tag})"
	fi
	head="$(remote_head "${packaging}" HEAD)"
	if [[ -z "${head}" ]]; then
		echo "  ${name} packaging: could not read ${packaging}"
		failed=1
	elif [[ "${head}" == "${packaging_commit}" ]]; then
		echo "  ${name} packaging: up to date"
	else
		newer=1
		echo "  ${name} packaging: newer, ${head}"
		commits_between "${packaging#https://github.com/}" "${packaging_commit}" "${head}"
	fi
done < <(awk '!/^#/ && NF' <<< "${xlibre:-}")

echo
if ((failed)); then
	echo "Some checks failed (see above)."
	exit 2
elif ((newer)); then
	echo "To update an app: in apps.conf set the new commit and version (revision 1), or bump only"
	echo "the revision if the version did not change. To update XLibre, see the top of xlibre.conf."
	exit 1
fi
echo "Everything is up to date."
