#!/bin/bash
#
# Install the Pivuan Audio package set in a Devuan excalibur arm64 root and check it.
# Runs as root inside that root (pivuan-audio-check.yml imports it as a container).
#
# Environment:
#   PACKAGES        packages to install (no recommends, as pivuan-config installs desktops)
#   PIVUAN_APPS     the Pivuan audio applications among them (from apps.conf)
#   PIVUAN_APT_URL  the Pivuan apt repository
#   KEYS            directory with pivuan-archive-keyring.gpg and NexusSfan.pgp (binary keyrings)
#
# Fails if apt can't resolve the set, if systemd, PulseAudio, PipeWire, LightDM or Xorg's own
# server get installed, if the X server isn't XLibre's (with modesetting and libinput), or if
# any program or plug-in of the Pivuan apps misses a library.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${PACKAGES:?}" "${PIVUAN_APPS:?}" "${PIVUAN_APT_URL:?}" "${KEYS:?}"
fail=0
error() {
	echo "::error::$*"
	fail=1
}
summary() { [[ -z "${SUMMARY:-}" ]] || echo "$*" >> "${SUMMARY}"; }
# The archive an installed version came from: origin <package> <version>
origin() {
	apt-cache policy "$1" | awk -v v="$2" '
		/^        / { if (f && $2 ~ /^https?:/) { print $2; exit } next }
		{ f = ($1 == v || ($1 == "***" && $2 == v)) }'
}

# 1. Sources, as the Pivuan Audio install will write them. The user's own XLibre setup uses
#    the same xlibre-debian source and key file name.
install -m 0644 "${KEYS}/pivuan-archive-keyring.gpg" /usr/share/keyrings/pivuan-archive-keyring.gpg
install -m 0644 "${KEYS}/NexusSfan.pgp" /usr/share/keyrings/NexusSfan.pgp
cat > /etc/apt/sources.list.d/pivuan.sources << EOF
Types: deb
URIs: ${PIVUAN_APT_URL}
Suites: excalibur
Components: main
Signed-By: /usr/share/keyrings/pivuan-archive-keyring.gpg
EOF
cat > /etc/apt/sources.list.d/xlibre-debian.sources << EOF
Types: deb
URIs: https://xlibre-debian.github.io/devuan/
Suites: main
Components: stable
Architectures: arm64
Signed-By: /usr/share/keyrings/NexusSfan.pgp
EOF
apt-get update -q

echo "::group::XLibre packages for arm64 in xlibre-debian"
xlibre_index="$(ls /var/lib/apt/lists/*xlibre-debian*_binary-arm64_Packages 2> /dev/null)" \
	|| { echo "::error::xlibre-debian has no arm64 package index"; exit 1; }
awk '/^Package: /{p=$2} /^Version: /{print p " " $2}' "${xlibre_index}" | sort
echo "::endgroup::"
{
	echo "## XLibre packages for arm64 (xlibre-debian)"
	echo ""
	echo '```'
	awk '/^Package: /{p=$2} /^Version: /{print p " " $2}' "${xlibre_index}" | sort
	echo '```'
	echo ""
	echo "### xlibre"
	echo ""
	echo '```'
	apt-cache show xlibre 2> /dev/null | grep -E '^(Version|Depends|Recommends|Conflicts|Replaces|Provides):' || echo "no package xlibre"
	echo '```'
} | while IFS= read -r line; do summary "${line}"; done

# 2. The real install.
# shellcheck disable=SC2086 # a word list
if ! apt-get install -y -q --no-install-recommends ${PACKAGES} 2>&1 | tee /tmp/install.log; then
	echo "::error::apt-get could not install the Pivuan Audio package set"
	exit 1
fi

# 3. What must not be there.
for pkg in systemd systemd-sysv pulseaudio pipewire pipewire-bin pipewire-pulse wireplumber lightdm xserver-xorg-core; do
	if dpkg-query -W -f '${db:Status-Status}' "${pkg}" 2> /dev/null | grep -qx installed; then
		error "${pkg} is installed"
	fi
done

# 4. The X server comes from xlibre-debian, with the drivers the Pi 5 needs (99-vc4.conf:
#    modesetting; input: libinput).
xserver=""
for bin in /usr/bin/Xlibre /usr/bin/Xorg /usr/lib/xorg/Xorg; do
	[[ -x "${bin}" ]] && { xserver="${bin}"; break; }
done
if [[ -z "${xserver}" ]]; then
	error "no X server (Xlibre or Xorg) installed"
else
	xpkg="$(dpkg -S "$(realpath "${xserver}")" 2> /dev/null | cut -d: -f1 || true)"
	xver="$(dpkg-query -W -f '${Version}' "${xpkg}" 2> /dev/null || true)"
	origin="$(origin "${xpkg}" "${xver}")"
	echo "X server: ${xserver} from ${xpkg} ${xver} (${origin})"
	summary "- X server: \`${xserver}\` from \`${xpkg} ${xver}\` (${origin})"
	[[ "${origin}" == *xlibre-debian* ]] || error "the X server ${xpkg} ${xver} does not come from xlibre-debian (${origin})"
	"${xserver}" -version 2>&1 | head -5 || error "${xserver} -version failed"
fi
for drv in modesetting_drv.so libinput_drv.so; do
	found="$(find /usr/lib/xorg/modules /usr/lib/xlibre -name "${drv}" 2> /dev/null | head -1)"
	if [[ -z "${found}" ]]; then
		error "no ${drv} installed"
	else
		summary "- ${drv}: \`${found}\` ($(dpkg -S "${found}" | cut -d: -f1))"
	fi
done

# 5. The Pivuan apps come from the Pivuan repository and find all their libraries.
for app in ${PIVUAN_APPS}; do
	ver="$(dpkg-query -W -f '${Version}' "${app}" 2> /dev/null || true)"
	[[ -n "${ver}" ]] || { error "${app} is not installed"; continue; }
	summary "- ${app} ${ver}"
	while IFS= read -r f; do
		if [[ ! -f "${f}" ]] || ! file -b "${f}" | grep -q '^ELF'; then continue; fi
		missing="$(ldd "${f}" 2>&1 | grep 'not found' || true)"
		[[ -z "${missing}" ]] || error "${app}: ${f}: $(tr -s ' \t\n' ' ' <<< "${missing}")"
	done < <(dpkg -L "${app}")
done
[[ -x /usr/bin/xlogin-launcher ]] || error "no /usr/bin/xlogin-launcher"
jackd --version 2>&1 | head -2 || error "jackd does not run"

# 6. What was installed: every package whose version isn't from Devuan, and the totals.
{
	echo ""
	echo "### Packages not from Devuan"
	echo ""
	echo '```'
	dpkg-query -W -f '${Package} ${Version}\n' | while read -r p v; do
		o="$(origin "${p}" "${v}")"
		[[ "${o}" == *devuan.org* ]] || echo "${p} ${v} ${o:-local}"
	done
	echo '```'
	echo ""
	echo "- Installed packages: $(dpkg-query -W | wc -l)"
	echo "- Init: $(dpkg-query -W -f '${Package} ${Version}' sysvinit-core 2> /dev/null || echo 'no sysvinit-core')"
} | while IFS= read -r line; do summary "${line}"; done

exit "${fail}"
