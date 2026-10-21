#!/bin/bash
#
# Build the Pivuan kernel on this PC and push it to ghcr.io/rations/build, where "Pivuan image
# build" fetches it. The image build never compiles a kernel (GitHub stopped this repository's
# Actions for using too much compute), so run this first whenever the kernel's version changes:
#
#   - after "Pivuan kernel pin" moves the pin,
#   - after a change to the kernel config or patches (config/kernel/linux-bcm2711-*.config,
#     patch/kernel/archive/bcm2711-*),
#   - after an Armbian merge: the version is also a hash of parts of the framework (the driver
#     patches, lib/functions/compilation/kernel*.sh), so a merge can ask for a new build of the
#     same kernel.
#
# When ghcr.io already has the kernel's version it says so and builds nothing. An x86-64 PC
# cross-compiles (no Docker: compile.sh runs as root through sudo, and the first run installs its
# build dependencies with apt). Everything it downloads (the kernel source, the toolchain) stays
# in cache/ of this checkout, so later builds only fetch what changed.
#
# Usage: kernel-build.sh [--push] [current|edge|legacy]
#   --push    push the kernel to ghcr.io once it is built (it is kept in output/packages-hashed,
#             so running again with --push does not compile it again)
#   branch    the kernel branch, current by default
# Needs sudo, python3 and oras (sudo apt install oras). Before the first push, log in once with a
# classic GitHub token that has write:packages (oras keeps it in ~/.docker/config.json):
#   oras login ghcr.io -u rations
# The first push makes a private package. Make it public once (github.com/rations/build ->
# Packages -> build/kernel-bcm2711-current -> Package settings -> Change visibility), or image
# builds cannot fetch it.
# Exit status: 0 when ghcr.io has the kernel or it was built, 1 on an error.
#
set -euo pipefail

push=no
branch=current
for arg in "$@"; do
	case "${arg}" in
		--push) push=yes ;;
		current | edge | legacy) branch="${arg}" ;;
		*)
			echo "Usage: $0 [--push] [current|edge|legacy]" >&2
			exit 1
			;;
	esac
done

src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v oras > /dev/null || {
	echo "oras is missing: sudo apt install oras" >&2
	exit 1
}

# KERNEL_GIT=shallow: start the kernel source from Armbian's shallow tree of this kernel series
# (about 330 MB, once) instead of the whole Linux history (about 3.9 GB). Pivuan builds one
# series, so the history is not needed. The tree stays in cache/git-bare/ for later builds.
compile() {
	"${src}/compile.sh" kernel BOARD=rpi4b BRANCH="${branch}" KERNEL_CONFIGURE=no PREFER_DOCKER=no KERNEL_GIT=shallow "$@"
}

# The version, local file and ghcr.io name this checkout gives the kernel (one JSON line on stdout).
info="$(compile CONFIG_DEFS_ONLY=yes)"
read -r version file target < <(python3 -c 'import json, sys
for line in reversed(sys.stdin.read().splitlines()):
    if line.startswith("{"):
        d = json.loads(line)
        print(d["artifact_version"], d["artifact_final_file"], d["artifact_full_oci_target"])
        break
else:
    sys.exit("compile.sh gave no kernel information")' <<< "${info}")
echo "Kernel ${branch}: ${version}"

if oras manifest fetch "${target}" > /dev/null 2>&1; then
	echo "ghcr.io has it (${target}): nothing to build."
	exit 0
fi

echo "Not on ghcr.io: building it (or taking it from output/packages-hashed)."
compile
[[ -f "${file}" ]] || {
	echo "compile.sh finished but ${file} is missing" >&2
	exit 1
}

if [[ "${push}" != yes ]]; then
	echo "Built: ${file}"
	echo "Run again with --push to put it on ghcr.io."
	exit 0
fi

# The same layout as the framework's own push (oras_push_artifact_file), so image builds can pull it.
(
	cd "$(dirname "${file}")"
	oras push \
		--annotation "org.opencontainers.image.description=Pivuan kernel ${branch} ${version}" \
		--annotation "org.opencontainers.image.source=https://github.com/rations/build" \
		"${target}" "$(basename "${file}"):application/vnd.unknown.layer.v1+tar"
)
oras manifest fetch "${target}" > /dev/null
echo "Pushed: ${target}"
