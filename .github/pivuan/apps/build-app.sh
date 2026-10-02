#!/bin/bash
#
# Build one of Pivuan's audio applications (apps.conf) as a .deb for this machine's
# architecture. Meant for an arm64 Debian trixie build environment: trixie has the same
# libraries as Devuan excalibur, so dpkg-shlibdeps writes Depends that resolve on Pivuan.
#
# Usage: build-app.sh <package> [out-dir]      (out-dir default: ./out)
#
# Each app is built with its own build system and release scripts, at the commit pinned in
# apps.conf, and staged into Debian paths:
#   programs            /usr/bin
#   LV2 and VST3        /usr/lib/lv2/<bundle>.lv2, /usr/lib/vst3/<bundle>.vst3
#   menu entries, icons /usr/share/applications, /usr/share/icons/hicolor
# Needs: git, dpkg-dev (dpkg-shlibdeps), file, and each app's build dependencies.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg="${1:?usage: build-app.sh <package> [out-dir]}"
out="$(mkdir -p "${2:-out}" && cd "${2:-out}" && pwd)"

die() {
	echo "::error::${pkg}: $*" >&2
	exit 1
}

read -r _ repo commit upstream revision < <(awk -v p="${pkg}" '$1 == p' "${here}/apps.conf") || die "not in apps.conf"
[[ "${commit}" =~ ^[0-9a-f]{40}$ ]] || die "apps.conf needs a full commit hash"
version="${upstream}-pivuan${revision}"
arch="$(dpkg --print-architecture)"
jobs="$(nproc)"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
src="${work}/src"
stage="${work}/stage"
mkdir -p "${stage}"

# The source at the pinned commit; submodules at the commits it pins (only those named).
git init -q "${src}"
git -C "${src}" remote add origin "${repo}"
git -C "${src}" fetch -q --depth 1 origin "${commit}"
git -C "${src}" checkout -q FETCH_HEAD
submodules() { # <dir> <path>...
	local dir="$1"
	shift
	git -C "${dir}" submodule update --init --depth 1 "$@" 2> /dev/null || git -C "${dir}" submodule update --init "$@"
}

# Filled in by the recipe.
summary=""
description=""
section="sound"
depends=""    # added to what dpkg-shlibdeps finds
recommends=""
conffiles=""  # one path per line
maint_dir=""  # directory with postinst/postrm to keep

desktop_entry() { # <file> <name> <comment> <exec> <icon>
	install -d "$(dirname "$1")"
	cat > "$1" <<- EOF
	[Desktop Entry]
	Type=Application
	Name=$2
	Comment=$3
	Exec=$4
	Icon=$5
	Terminal=false
	Categories=AudioVideo;Audio;
	EOF
}

# Run a project's own build-deb.sh and take its package tree (maintainer scripts included).
from_project_deb() { # <build-deb.sh arguments>...
	(cd "${src}" && "$@")
	local deb
	deb="$(ls "${src}"/*_"${arch}".deb)"
	dpkg-deb -R "${deb}" "${stage}"
	mv "${stage}/DEBIAN" "${work}/project-DEBIAN"
	maint_dir="${work}/project-DEBIAN"
	[[ ! -f "${maint_dir}/conffiles" ]] || conffiles="$(cat "${maint_dir}/conffiles")"
}

# A project's release tarball (scripts/makedist-linux.sh), unpacked.
from_tarball() { # <glob in dist/>
	local tarball
	# shellcheck disable=SC2206 # $1 is a glob
	local matches=("${src}"/dist/$1)
	tarball="${matches[0]}"
	[[ -f "${tarball}" ]] || die "no release tarball matching dist/$1"
	mkdir -p "${work}/dist"
	tar -xzf "${tarball}" -C "${work}/dist"
	find "${work}/dist" -mindepth 1 -maxdepth 1 -type d
}

case "${pkg}" in
	audio-gui)
		summary="ALSA mixer and audio routing without PulseAudio or PipeWire"
		description="A mixer for ALSA devices and a switch between three routings for programs
 that play through PulseAudio: its own small PulseAudio-protocol bridge to ALSA,
 plain ALSA, or a bridge into JACK. No PulseAudio or PipeWire server is used."
		recommends="alsa-utils"
		from_project_deb packaging/build-deb.sh "${upstream}"
		;;
	jack-graph)
		summary="Connection manager for JACK and ALSA MIDI"
		description="Shows JACK audio and MIDI ports and ALSA sequencer clients as a graph and
 connects them. Also starts and stops the JACK server."
		depends="jackd2 | jackd"
		from_project_deb env WERROR=1 packaging/build-deb.sh "${upstream}"
		;;
	jackdaw)
		summary="Multitrack audio and MIDI workstation for JACK"
		description="A digital audio workstation on JACK that hosts LV2, VST3, CLAP and
 LADSPA plug-ins."
		submodules "${src}" ext/vst3sdk
		submodules "${src}/ext/vst3sdk" base pluginterfaces public.sdk
		make -C "${src}" -j"${jobs}" VST3=1
		for bin in jackdaw jackdaw-lv2ui-x11 jackdaw-lv2ui-gtk2; do
			[[ ! -f "${src}/src/${bin}" ]] || install -Dm 0755 "${src}/src/${bin}" "${stage}/usr/bin/${bin}"
		done
		[[ -f "${stage}/usr/bin/jackdaw" ]] || die "jackdaw was not built"
		(cd "${src}/icons/hicolor" && find . -name jackdaw.png -exec install -Dm 0644 {} "${stage}/usr/share/icons/hicolor/{}" \;)
		sed 's|@bindir@|/usr/bin|g' "${src}/jackdaw.desktop.in" | install -Dm 0644 /dev/stdin "${stage}/usr/share/applications/jackdaw.desktop"
		;;
	namp-rations)
		summary="Neural Amp Modeler amp head, plug-in rack and pedals"
		description="NAMp Rack, a four-channel Neural Amp Modeler amp head for JACK with a
 VST3 and LV2 plug-in rack, and the NAMp Rations amp and Rations pedals as VST3
 (and LV2) plug-ins. No amp captures are included."
		submodules "${src}" NeuralAmpModelerCore AudioDSPTools eigen rations-pedals
		submodules "${src}" vst3sdk
		submodules "${src}/vst3sdk" base cmake pluginterfaces public.sdk
		(cd "${src}" && scripts/makedist-linux.sh)
		dist="$(from_tarball 'NAMp-*-linux-*.tar.gz')"
		install -d "${stage}/usr/lib/vst3" "${stage}/usr/lib/lv2"
		cp -a "${dist}"/plugin/*.vst3 "${dist}"/pedals/*.vst3 "${stage}/usr/lib/vst3/"
		cp -a "${dist}"/plugin/*.lv2 "${stage}/usr/lib/lv2/"
		install -Dm 0755 "${dist}/rack/namp-rack" "${stage}/usr/bin/namp-rack"
		install -Dm 0644 "${dist}/rack/desktop/namp-rack.desktop" "${stage}/usr/share/applications/namp-rack.desktop"
		for size in 48 64 128 256; do
			install -Dm 0644 "${dist}/rack/desktop/namp-rack-${size}.png" "${stage}/usr/share/icons/hicolor/${size}x${size}/apps/namp-rack.png"
		done
		;;
	namix)
		summary="Neural Amp Modeler plug-in (VST3, LV2) and JACK standalone"
		description="Loads Neural Amp Modeler (.nam) captures. The same amp as a VST3 plug-in,
 an LV2 plug-in and a standalone JACK program. No captures are included."
		submodules "${src}" NeuralAmpModelerCore AudioDSPTools eigen vst3sdk
		submodules "${src}/vst3sdk" base cmake pluginterfaces public.sdk
		(cd "${src}" && scripts/makedist-linux.sh)
		dist="$(from_tarball 'NAMix-*-linux-*.tar.gz')"
		install -d "${stage}/usr/lib/vst3" "${stage}/usr/lib/lv2"
		cp -a "${dist}/NAMix.vst3" "${stage}/usr/lib/vst3/"
		cp -a "${dist}/NAMix.lv2" "${stage}/usr/lib/lv2/"
		install -Dm 0755 "${dist}/namix-standalone" "${stage}/usr/bin/namix-standalone"
		desktop_entry "${stage}/usr/share/applications/namix.desktop" NAMix "Neural Amp Modeler (JACK)" namix-standalone audio-card
		;;
	lvtuner)
		summary="Chromatic tuner LV2 plug-in"
		description="A chromatic tuner as an LV2 plug-in with its own X11 interface. Load it in
 an LV2 host such as JackDAW."
		make -C "${src}" -j"${jobs}"
		make -C "${src}" test
		make -C "${src}" install PREFIX=/usr DESTDIR="${stage}"
		;;
	drumix)
		summary="MIDI drum sampler (VST3 and JACK standalone)"
		description="Loads a WAV file per pad and plays the pads from MIDI notes. A VST3
 plug-in and a standalone JACK program. No samples are included."
		submodules "${src}" vst3sdk
		submodules "${src}/vst3sdk" base cmake pluginterfaces public.sdk
		(cd "${src}" && scripts/makedist-linux.sh)
		dist="$(from_tarball 'DRUMix-*-linux-*.tar.gz')"
		install -d "${stage}/usr/lib/vst3"
		cp -a "${dist}/DRUMix.vst3" "${stage}/usr/lib/vst3/"
		install -Dm 0755 "${dist}/drumix-standalone" "${stage}/usr/bin/drumix-standalone"
		desktop_entry "${stage}/usr/share/applications/drumix.desktop" DRUMix "MIDI drum sampler (JACK)" drumix-standalone audio-card
		;;
	cpu-power)
		summary="CPU governor and low-latency (DAW mode) switch"
		description="A window to set the CPU frequency governor, energy preference and turbo, and
 a DAW mode that keeps the CPU out of deep idle states. Changes go through a small
 helper started with pkexec, and are undone when switched off."
		section="admin"
		depends="pkexec, polkitd"
		cmake -S "${src}" -B "${src}/build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr
		cmake --build "${src}/build" -j"${jobs}"
		# coretest finds tests/fixtures relative to the working directory (CMakeLists add_test).
		[[ ! -x "${src}/build/coretest" ]] || (cd "${src}" && build/coretest)
		DESTDIR="${stage}" cmake --install "${src}/build"
		;;
	simple-login-gui)
		summary="Graphical login on tty1 without a display manager (xlogin)"
		description="Replaces the text login on tty1 with a full-screen window: authenticates
 with PAM, registers the session with elogind when present, and runs the user's
 ~/.xinitrc. Started from /etc/inittab through xlogin-launcher."
		section="x11"
		depends="seatd, xinit, x11-xserver-utils"
		make -C "${src}" -j"${jobs}" PREFIX=/usr xlogin
		make -C "${src}" install PREFIX=/usr DESTDIR="${stage}"
		! grep -q '/usr/local/bin/xlogin' "${stage}/usr/bin/xlogin-launcher" || die "xlogin-launcher still starts /usr/local/bin/xlogin"
		# Pivuan starts it from /etc/inittab (pivuan-config) and has its own polkit power rule.
		rm -rf "${stage}/etc/init.d" "${stage}/etc/polkit-1"
		conffiles="/etc/pam.d/xlogin
/etc/pam.d/xlogin-autologin"
		;;
	*)
		die "no recipe"
		;;
esac

# Documentation and licence.
install -d "${stage}/usr/share/doc/${pkg}"
{
	echo "${pkg} ${version}, built by Pivuan from ${repo} at ${commit}."
	for f in LICENSE LICENSE.txt NOTICE; do
		[[ -f "${src}/${f}" ]] || continue
		printf '\n==> %s <==\n\n' "${f}"
		cat "${src}/${f}"
	done
} > "${stage}/usr/share/doc/${pkg}/copyright"
rm -f "${stage}/usr/share/doc/${pkg}/copyright.gz"
# changelog.Debian (unless the project's own .deb has one), dated from the pinned commit so
# rebuilds are identical.
[[ -f "${stage}/usr/share/doc/${pkg}/changelog.Debian.gz" ]] || printf '%s (%s) excalibur; urgency=medium\n\n  * Built from %s at %s.\n\n -- Pivuan <https://github.com/rations/pivuan>  %s\n' \
	"${pkg}" "${version}" "${repo}" "${commit}" "$(git -C "${src}" log -1 --format=%cD "${commit}")" \
	| gzip -9n > "${stage}/usr/share/doc/${pkg}/changelog.Debian.gz"

# Every ELF must be for this architecture; strip them.
mapfile -t elfs < <(find "${stage}" -type f -exec sh -c 'file -b "$1" | grep -q "^ELF" && echo "$1"' _ {} \;)
((${#elfs[@]})) || die "no ELF files staged"
case "${arch}" in
	arm64) want="ARM aarch64" ;;
	amd64) want="x86-64" ;;
	*) want="" ;;
esac
for elf in "${elfs[@]}"; do
	[[ -z "${want}" ]] || file -b "${elf}" | grep -q "${want}" || die "${elf#"${stage}"} is not ${want}: $(file -b "${elf}")"
	strip --strip-unneeded "${elf}" 2> /dev/null || true
done

# Depends from the libraries the ELF files link (dpkg-shlibdeps needs a debian/control).
mkdir -p "${work}/shlibs/debian"
printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "${pkg}" "${pkg}" > "${work}/shlibs/debian/control"
shlibs="$(cd "${work}/shlibs" && dpkg-shlibdeps -O --ignore-missing-info "${elfs[@]/#/-e}" 2> "${work}/shlibdeps.log" | sed -n 's/^shlibs:Depends=//p')" \
	|| { cat "${work}/shlibdeps.log" >&2; die "dpkg-shlibdeps failed"; }
[[ -n "${shlibs}" ]] || die "dpkg-shlibdeps found no dependencies"
if grep -qiE '(^|[ ,])libsystemd-shared|(^|[ ,])systemd($|[ ,(])' <<< "${shlibs}, ${depends}"; then
	die "depends on systemd: ${shlibs}"
fi

mkdir -p "${stage}/DEBIAN"
for script in preinst postinst prerm postrm; do
	[[ -z "${maint_dir}" || ! -f "${maint_dir}/${script}" ]] || install -m 0755 "${maint_dir}/${script}" "${stage}/DEBIAN/${script}"
done
[[ -z "${conffiles}" ]] || printf '%s\n' "${conffiles}" > "${stage}/DEBIAN/conffiles"
(cd "${stage}" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | xargs -0 -r md5sum > DEBIAN/md5sums)
{
	echo "Package: ${pkg}"
	echo "Version: ${version}"
	echo "Architecture: ${arch}"
	echo "Maintainer: Pivuan <https://github.com/rations/pivuan>"
	echo "Installed-Size: $(du -sk --exclude=DEBIAN "${stage}" | cut -f1)"
	echo "Depends: ${shlibs}${depends:+, ${depends}}"
	[[ -z "${recommends}" ]] || echo "Recommends: ${recommends}"
	echo "Section: ${section}"
	echo "Priority: optional"
	echo "Homepage: ${repo}"
	echo "Description: ${summary}"
	echo " ${description}"
} > "${stage}/DEBIAN/control"

deb="${out}/${pkg}_${version}_${arch}.deb"
dpkg-deb --root-owner-group -Zxz --build "${stage}" "${deb}" > /dev/null
echo "== ${deb##*/}"
dpkg-deb -I "${deb}" | sed -n '/^ Package:/,$p'
dpkg-deb -c "${deb}" | awk '{print "   " $6}'
