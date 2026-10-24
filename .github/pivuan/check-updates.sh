#!/bin/bash
#
# Say which pinned Pivuan packages have something newer upstream. Run it before the
# "Pivuan audio apps", "XLibre for Pivuan" and "Onboard for Pivuan" workflows; it only reports
# and changes nothing.
#
#   apps.conf     each app's commit against the head of its default branch, with the new commits;
#                 for an upstream app pinned at a release tag (TONE3000), the newest release tag;
#                 for an app that follows its branch, whether its VERSION is published yet
#   xlibre.conf   each XLibre tag against the newest release tag, and the packaging commit
#                 against the head of the packaging repository
#   onboard.conf  Devuan's onboard version that Pivuan rebuilds, against the newest in excalibur,
#                 excalibur-updates and excalibur-security (Pivuan's would hide a newer one)
#
# Not checked: vstbridge (its workflow always builds the head of rations/vstbridge's arm64
# branch) and the kernel ("Pivuan kernel pin" checks that pin, then kernel-build.sh builds it).
#
# Usage: check-updates.sh [xlibre.conf]
#   xlibre.conf defaults to ../pivuan/xlibre/xlibre.conf next to this checkout of rations/build,
#   or else the copy on rations/pivuan master; onboard.conf likewise from ../pivuan/onboard/.
# Needs git, curl, xz and python3. Set GITHUB_TOKEN to raise GitHub's API limit (60 requests an hour
# without it; each app with new commits uses one).
# Exit status: 0 when everything is up to date, 1 when something is newer, 2 on an error.
#
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apps_conf="${here}/apps/apps.conf"
xlibre_conf="${1:-${here}/../../../pivuan/xlibre/xlibre.conf}"
onboard_conf="$(dirname "${xlibre_conf}")/../onboard/onboard.conf"
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
	# Pivuan: an app that follows a branch ("master VERSION") is up to date once the version in
	# that branch's VERSION file is published.
	if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
		head="$(remote_head "${url}" "refs/heads/${commit}")"
		[[ "${ver}" != VERSION ]] || ver="$(curl -fsS "https://raw.githubusercontent.com/${url#https://github.com/}/${head:-${commit}}/VERSION" 2>/dev/null | tr -d '[:space:]')"
		published="$(curl -fsS https://rations.github.io/pivuan/dists/excalibur/main/binary-arm64/Packages 2>/dev/null |
			awk -v p="${pkg}" '/^Package: /{n=$2} /^Version: /{ if (n == p) print $2 }')"
		if [[ -z "${head}" || -z "${ver}" ]]; then
			echo "  ${pkg}: could not read ${commit} or its VERSION in ${url}"
			failed=1
		elif grep -qxF "${ver}-pivuan${rev}" <<< "${published}"; then
			echo "  ${pkg} ${ver}-pivuan${rev}: published (follows ${commit}, now ${head:0:7})"
		else
			newer=1
			echo "  ${pkg} ${ver}-pivuan${rev}: not published yet (follows ${commit}, now ${head:0:7})"
		fi
		continue
	fi
	# Pivuan: an app from outside rations pinned at a release tag's commit (TONE3000) is checked
	# against its newest release tag (vX.Y.Z, no -beta or -alpha), not its branch, which moves
	# between releases. Pivuan's own apps are checked against their branch.
	tags=""
	[[ "${url}" == https://github.com/rations/* ]] || tags="$(git ls-remote --tags "${url}" 2>/dev/null)"
	pinned="$(awk -v c="${commit}" '$1 == c { sub(".*refs/tags/", "", $2); sub(/\^\{\}$/, "", $2); print $2 }' <<< "${tags}" |
		grep -E '^v?[0-9]+(\.[0-9]+)*$' | head -1)"
	if [[ -n "${pinned}" ]]; then
		latest="$(sed -E 's|.*refs/tags/||; s|\^\{\}$||' <<< "${tags}" | grep -E '^v?[0-9]+(\.[0-9]+)*$' | sort -uV | tail -1)"
		if [[ "${latest}" == "${pinned}" ]]; then
			echo "  ${pkg} ${ver}-pivuan${rev}: ${pinned} is the newest release"
		else
			newer=1
			echo "  ${pkg} ${ver}-pivuan${rev}: newer release ${latest} (pinned ${pinned})"
		fi
		continue
	fi
	# The default branch (master, or main upstream).
	head="$(remote_head "${url}" HEAD)"
	if [[ -z "${head}" ]]; then
		echo "  ${pkg}: could not read the default branch of ${url}"
		failed=1
	elif [[ "${head}" == "${commit}" ]]; then
		echo "  ${pkg} ${ver}-pivuan${rev}: up to date"
	else
		newer=1
		echo "  ${pkg} ${ver}-pivuan${rev}: the default branch is newer, ${head}"
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
while read -r name source tag commit packaging packaging_commit version; do
	# Release tags are <prefix><version>, e.g. xlibre-xserver-25.2.2; release candidates are left out.
	prefix="$(sed -E 's/[0-9]+(\.[0-9]+)*$//' <<< "${tag}")"
	# Pivuan: a pin on a release branch (release/25.2): its prefix comes from the repository
	# (xlibre-xserver-), and the release it is based on from the version (2:25.2.2+git...).
	branch=""
	if [[ "${tag}" == release/* ]]; then
		branch="${tag}"
		prefix="xlibre-${source##*/}-"
		tag="${prefix}$(sed -E 's/^[0-9]+://; s/[+~-].*$//' <<< "${version}")"
	fi
	latest="$(git ls-remote --tags --refs "${source}" "refs/tags/${prefix}*" 2>/dev/null |
		sed 's|.*refs/tags/||' | grep -E "^${prefix}[0-9]+(\.[0-9]+)*$" | sort -V | tail -1)"
	if [[ -n "${branch}" ]]; then
		head="$(remote_head "${source}" "refs/heads/${branch}")"
		if [[ -z "${head}" ]]; then
			echo "  ${name}: could not read ${branch} of ${source}"
			failed=1
		elif [[ "${head}" == "${commit}" ]]; then
			echo "  ${name} ${version}: ${branch} has nothing newer"
		else
			newer=1
			echo "  ${name} ${version}: ${branch} is newer, ${head}"
			commits_between "${source#https://github.com/}" "${commit}" "${head}"
		fi
		if [[ -n "${latest}" && "${latest}" != "${tag}" ]]; then
			newer=1
			echo "  ${name}: newer release ${latest}: pin it instead of ${branch} if it has the fixes"
		fi
	elif [[ -z "${latest}" ]]; then
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

# Pivuan: Onboard, rebuilt from Devuan's source with Pivuan's patches.
echo
if [[ -f "${onboard_conf}" ]]; then
	echo "Onboard (${onboard_conf}):"
	onboard="$(cat "${onboard_conf}")"
else
	echo "Onboard (rations/pivuan master, onboard/onboard.conf):"
	onboard="$(curl -fsS https://raw.githubusercontent.com/rations/pivuan/master/onboard/onboard.conf)" || {
		echo "  could not read onboard.conf"
		failed=1
	}
fi
read -r onboard_devuan onboard_version < <(awk '!/^#/ && NF' <<< "${onboard:-}")
if [[ -n "${onboard_devuan:-}" ]]; then
	devuan=""
	for suite in excalibur excalibur-updates excalibur-security; do
		devuan+="$(curl -fsS "http://deb.devuan.org/merged/dists/${suite}/main/binary-arm64/Packages.xz" 2>/dev/null |
			xz -dc 2>/dev/null | awk '/^Package: onboard$/ { p = 1 } p && /^Version:/ { print $2; p = 0 }')"$'\n'
	done
	latest="$(grep . <<< "${devuan}" | sort -V | tail -1)"
	if [[ -z "${latest}" ]]; then
		echo "  onboard: could not read Devuan's onboard version"
		failed=1
	elif dpkg --compare-versions "${latest}" le "${onboard_devuan}" 2>/dev/null ||
		[[ "${latest}" == "${onboard_devuan}" ]]; then
		echo "  onboard ${onboard_version}: Devuan's ${onboard_devuan} is the newest"
	else
		newer=1
		echo "  onboard ${onboard_version}: Devuan has ${latest} (pinned ${onboard_devuan}): rebuild from it"
	fi
fi

echo
if ((failed)); then
	echo "Some checks failed (see above)."
	exit 2
elif ((newer)); then
	echo "To update an app: in apps.conf set the new commit and version (revision 1), or bump only"
	echo "the revision if the version did not change. To update XLibre or Onboard, see the top of"
	echo "xlibre.conf or onboard.conf."
	exit 1
fi
echo "Everything is up to date."
