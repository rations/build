#!/usr/bin/env bash
#
# What merging Armbian's upstream into Pivuan's branch would bring. Run in a full clone of
# rations/build or rations/configng, on the Pivuan branch; changes nothing (the merge is tried
# with git merge-tree, which writes no branch or working tree).
#
#   upstream-check.sh build|configng
#
# Environment: UPSTREAM_URL (default https://github.com/armbian/<repo>), UPSTREAM_BRANCH (main),
# REPORT (default upstream-report.md); SUMMARY, if set, also receives the report
# (GitHub's step summary).
#
# The report lists:
#  - the upstream commits not in Pivuan yet;
#  - merge conflicts. A file Pivuan deleted (such as Armbian's own CI workflows) and upstream
#    changed stays deleted: listed, not counted as a problem;
#  - upstream changes to files Pivuan changed too (they may undo or clash with a Pivuan change);
#  - upstream changes in the areas Pivuan images use (build: Raspberry Pi family and boards,
#    lib/, common BSP files and package lists; configng: everything the tool runs);
#  - added lines there that mention systemd (systemctl, journalctl, logind, units, networkd,
#    resolved, timesyncd, udev rules for systemd), and, in configng, new menu entries and module
#    code that calls systemctl directly instead of Pivuan's srv_* helpers (module_service.sh);
#  - package lists upstream changed, which could pull in systemd (the Pivuan checks catch that).
#
# Exit status: 0 nothing needs attention, 1 something does (conflicts, or systemd in the areas
# Pivuan uses), 2 the check itself failed.
#
set -euo pipefail

kind="${1:-}"
case "${kind}" in
	build | configng) ;;
	*)
		echo "usage: $0 build|configng" >&2
		exit 2
		;;
esac
upstream_url="${UPSTREAM_URL:-https://github.com/armbian/${kind}}"
upstream_branch="${UPSTREAM_BRANCH:-main}"
report="${REPORT:-upstream-report.md}"
upstream_ref="refs/remotes/upstream/${upstream_branch}"

git fetch --quiet --no-tags "${upstream_url}" "+refs/heads/${upstream_branch}:${upstream_ref}" || exit 2
head="$(git rev-parse HEAD)"
base="$(git merge-base HEAD "${upstream_ref}")" || exit 2
upstream="$(git rev-parse "${upstream_ref}")"

# Areas Pivuan images and pivuan-config use (extended regular expressions on paths).
if [[ "${kind}" == build ]]; then
	relevant='^(lib/|packages/bsp/common/|packages/bsp/sysvinit/|config/sources/families/bcm2711\.conf|config/boards/rpi|config/kernel/linux-bcm2711|config/distributions/|config/cli/common/|config/cli/excalibur/|config/optional/|extensions/|compile\.sh)'
	package_lists='^config/(cli|desktop|optional)/.*packages|^config/distributions/'
else
	relevant='^(tools/|bin/|debian/|lib/)'
	package_lists='^tools/modules/desktops/yaml/|^debian/control'
fi
systemd_words='systemd|systemctl|journalctl|logind|timesyncd|resolved|networkd|\.service\b|\.timer\b|\.socket\b|\.target\b|WantedBy='
attention=0

out() { printf '%s\n' "$*" >> "${report}"; }
: > "${report}"

behind="$(git rev-list --count "${base}..${upstream}")"
out "## Upstream check: ${kind}"
out ""
out "Pivuan \`$(git rev-parse --short "${head}")\`, upstream ${upstream_url} ${upstream_branch} \`$(git rev-parse --short "${upstream}")\`, common base \`$(git rev-parse --short "${base}")\` ($(git log -1 --format=%cs "${base}"))."
out ""
if ((behind == 0)); then
	out "**Up to date:** no upstream commits to merge."
	[[ -z "${SUMMARY:-}" ]] || cat "${report}" >> "${SUMMARY}"
	cat "${report}"
	exit 0
fi
out "**${behind} upstream commits** to merge."
out ""

# Files Pivuan deleted since the common base: upstream changes to them are dropped on merge.
mapfile -t pivuan_deleted < <(git diff --name-only --diff-filter=D "${base}" "${head}")
mapfile -t pivuan_changed < <(git diff --name-only "${base}" "${head}")
mapfile -t upstream_changed < <(git diff --name-only "${base}" "${upstream}")
is_in() {
	local needle="$1" item
	shift
	for item in "$@"; do [[ "${item}" == "${needle}" ]] && return 0; done
	return 1
}

# 1. Trial merge.
conflicts=()
kept_deleted=()
merge_output="$(git merge-tree --write-tree --name-only --no-messages "${head}" "${upstream}" 2> /dev/null)" && merge_status=0 || merge_status=$?
if ((merge_status > 1)); then
	echo "git merge-tree failed" >&2
	exit 2
fi
if ((merge_status == 1)); then
	while IFS= read -r file; do
		[[ -n "${file}" ]] || continue
		if is_in "${file}" "${pivuan_deleted[@]}"; then
			kept_deleted+=("${file}")
		else
			conflicts+=("${file}")
		fi
	done < <(tail -n +2 <<< "${merge_output}")
fi
out "### Merge"
if ((${#conflicts[@]})); then
	attention=1
	out "**Conflicts to resolve by hand:**"
	for f in "${conflicts[@]}"; do out "- \`${f}\`"; done
else
	out "The merge applies without conflicts that need a decision."
fi
if ((${#kept_deleted[@]})); then
	out ""
	out "Changed upstream but deleted in Pivuan (stay deleted when merging):"
	for f in "${kept_deleted[@]}"; do out "- \`${f}\`"; done
fi
out ""

# 2. Files both sides changed (not counting the ones Pivuan deleted).
overlap=()
for f in "${upstream_changed[@]}"; do
	is_in "${f}" "${pivuan_changed[@]}" && ! is_in "${f}" "${pivuan_deleted[@]}" && overlap+=("${f}")
done
out "### Files Pivuan changed that upstream changed too"
if ((${#overlap[@]})); then
	out "Check that these upstream changes keep what Pivuan changed there:"
	for f in "${overlap[@]}"; do
		out "- \`${f}\`: $(git log --format='%h %s' "${base}..${upstream}" -- "${f}" | head -n 3 | sed 's/`/'"'"'/g' | paste -sd ';' - | sed 's/;/; /g')"
	done
else
	out "None."
fi
out ""

# 3. Upstream changes in the areas Pivuan uses.
relevant_changed=()
for f in "${upstream_changed[@]}"; do
	[[ "${f}" =~ ${relevant} ]] && relevant_changed+=("${f}")
done
out "### Upstream changes in the areas Pivuan uses"
if ((${#relevant_changed[@]})); then
	out "${#relevant_changed[@]} of ${#upstream_changed[@]} changed files:"
	for f in "${relevant_changed[@]}"; do out "- \`${f}\`"; done
else
	out "None of the ${#upstream_changed[@]} changed files is in these areas."
fi
out ""

# 4. systemd in added lines. "relevant" hits need attention; the others are counted only.
declare -A hits=()
other_hits=0
current=""
while IFS= read -r line; do
	if [[ "${line}" == "+++ b/"* ]]; then
		current="${line#+++ b/}"
		continue
	fi
	[[ "${line}" == "+"* && "${line}" != "+++"* ]] || continue
	grep -qiE "${systemd_words}" <<< "${line}" || continue
	if [[ "${current}" =~ ${relevant} && ! "${current}" =~ (^|/)tests?/ && "${current}" != *.md ]]; then
		hits["${current}"]+="${line:1:160}"$'\n'
	else
		((other_hits += 1))
	fi
done < <(git diff --unified=0 "${base}" "${upstream}")
out "### systemd in upstream's added lines"
if ((${#hits[@]})); then
	attention=1
	out "In the areas Pivuan uses (Pivuan has no systemd: these need a sysvinit way, srv_* helpers, or hiding on Pivuan):"
	for f in $(printf '%s\n' "${!hits[@]}" | sort); do
		out ""
		out "\`${f}\`:"
		out '```'
		printf '%s' "${hits[${f}]}" | head -n 8 >> "${report}"
		out '```'
	done
else
	out "None in the areas Pivuan uses."
fi
if ((other_hits)); then
	out ""
	out "(${other_hits} added lines elsewhere mention systemd: other boards, patches, tests or documentation.)"
fi
out ""

# 5. configng: new menu entries, and module code calling systemctl directly.
if [[ "${kind}" == configng ]]; then
	out "### New menu entries"
	new_ids="$(git diff --unified=0 "${base}" "${upstream}" -- 'tools/json/*.json' | sed -n 's/^+.*"id": *"\([^"]*\)".*/\1/p' | sort -u)"
	old_ids="$(git diff --unified=0 "${base}" "${upstream}" -- 'tools/json/*.json' | sed -n 's/^-.*"id": *"\([^"]*\)".*/\1/p' | sort -u)"
	added_ids="$(comm -23 <(printf '%s\n' "${new_ids}") <(printf '%s\n' "${old_ids}") | grep . || true)"
	if [[ -n "${added_ids}" ]]; then
		out "Check each works on Pivuan (sysvinit) or is hidden there:"
		while IFS= read -r id; do out "- ${id}"; done <<< "${added_ids}"
	else
		out "None."
	fi
	out ""
	direct="$(git diff --unified=0 "${base}" "${upstream}" -- 'tools/modules/' | awk '/^\+\+\+ b\//{f=substr($0,7)} /^\+[^+]/ && /(^|[^_[:alnum:]])(systemctl|journalctl)[[:space:]]/{print f}' | sort | uniq -c)"
	out "### Module code calling systemctl or journalctl directly"
	if [[ -n "${direct}" ]]; then
		attention=1
		out "These added lines bypass Pivuan's srv_* helpers (module_service.sh):"
		while read -r n f; do out "- \`${f}\`: ${n} lines"; done <<< "${direct}"
	else
		out "None."
	fi
	out ""
fi

# 6. Package lists.
lists=()
for f in "${upstream_changed[@]}"; do
	[[ "${f}" =~ ${package_lists} ]] && lists+=("${f}")
done
out "### Package lists"
if ((${#lists[@]})); then
	out "Changed upstream; a new package could depend on systemd. After merging, the Pivuan checks (install check, image build) fail if systemd gets installed:"
	for f in "${lists[@]}"; do out "- \`${f}\`"; done
else
	out "No package list changed."
fi
out ""

out "### Upstream commits"
out '```'
git log --format='%h %cs %s' "${base}..${upstream}" | head -n 150 >> "${report}"
((behind <= 150)) || out "... and $((behind - 150)) more"
out '```'
out ""
if ((attention)); then
	out "**Needs attention before merging** (see above)."
else
	out "**Nothing needs attention:** safe to merge, then run the Pivuan checks."
fi

[[ -z "${SUMMARY:-}" ]] || cat "${report}" >> "${SUMMARY}"
cat "${report}"
exit "${attention}"
