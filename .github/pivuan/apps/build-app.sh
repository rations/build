#!/bin/bash
#
# Build one of Pivuan's audio applications (apps.conf) as a .deb for this machine's
# architecture. Meant for an arm64 Debian trixie build environment: trixie has the same
# libraries as Devuan excalibur, so dpkg-shlibdeps writes Depends that resolve on Pivuan.
#
# Usage: build-app.sh <package> [out-dir]      (out-dir default: ./out)
#        build-app.sh --resolve <package>      print "<version> <commit>" it would build
#
# Each app is built with its own build system and release scripts, at the commit pinned in
# apps.conf (or the newest on the branch named there), and staged into Debian paths:
#   programs            /usr/bin
#   LV2 and VST3        /usr/lib/lv2/<bundle>.lv2, /usr/lib/vst3/<bundle>.vst3
#   menu entries, icons /usr/share/applications, /usr/share/icons/hicolor
# Needs: git, dpkg-dev (dpkg-shlibdeps), file, and each app's build dependencies.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resolve=0
[[ "${1:-}" != --resolve ]] || { resolve=1; shift; }
pkg="${1:?usage: build-app.sh [--resolve] <package> [out-dir]}"
((resolve)) || out="$(mkdir -p "${2:-out}" && cd "${2:-out}" && pwd)"

die() {
	echo "::error::${pkg}: $*" >&2
	exit 1
}

read -r _ repo commit upstream revision < <(awk -v p="${pkg}" '$1 == p' "${here}/apps.conf") || die "not in apps.conf"
# Pivuan: a branch name instead of a commit follows that branch (its newest commit when this
# runs), and VERSION instead of a version reads it from the VERSION file at that commit.
[[ "${commit}" =~ ^[0-9a-f]{40}$ || "${commit}" =~ ^(master|main)$ ]] \
	|| die "apps.conf needs a full commit hash, or master or main"
arch="$(dpkg --print-architecture)"
jobs="$(nproc)"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
src="${work}/src"
stage="${work}/stage"
mkdir -p "${stage}"

# The source at the pinned commit (or the branch's newest); submodules at the commits it pins
# (only those named).
git init -q "${src}"
git -C "${src}" remote add origin "${repo}"
git -C "${src}" fetch -q --depth 1 origin "${commit}"
git -C "${src}" checkout -q FETCH_HEAD
commit="$(git -C "${src}" rev-parse HEAD)"
if [[ "${upstream}" == VERSION ]]; then
	[[ -f "${src}/VERSION" ]] || die "no VERSION file at ${commit}"
	upstream="$(tr -d '[:space:]' < "${src}/VERSION")"
fi
# A Debian upstream version: the revision follows the last hyphen, so none in it.
[[ "${upstream}" =~ ^[0-9][0-9A-Za-z.+~]*$ ]] || die "not a version: ${upstream}"
version="${upstream}-pivuan${revision}"
if ((resolve)); then
	echo "${version} ${commit}"
	exit 0
fi
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
licences=()   # more licence texts for the copyright file, as "<what it covers>=<file>"

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
	tone3000)
		summary="TONE3000 amp and effects plug-in (VST3, LV2) and standalone"
		description="Plays Neural Amp Modeler captures and impulse responses from TONE3000 in a
 chain of amp, cabinet and effect blocks: a VST3 and an LV2 plug-in and a standalone
 program. Tones are downloaded from tone3000.com; factory presets are included."
		# JUCE loads these with dlopen, so dpkg-shlibdeps cannot see them: libcurl for the tone
		# downloads (either build), JACK for the standalone, and zenity (or kdialog) for its
		# file dialogs.
		depends="libcurl4t64 | libcurl3t64-gnutls"
		recommends="libjack-jackd2-0 | libjack0, zenity"
		submodules "${src}" plugin/NeuralAmpModelerCore plugin/AudioDSPTools
		submodules "${src}/plugin/NeuralAmpModelerCore" Dependencies/eigen Dependencies/AudioDSPTools
		# CMake fetches JUCE, FreeType and GoogleTest itself (CPM, pinned in CMakeLists.txt).
		# No CLAP: Pivuan's hosts load VST3 and LV2.
		cmake -S "${src}" -B "${src}/build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_TOOLCHAIN_FILE="${src}/cmake/linux-toolchain.cmake" -DBUILD_CLAP=OFF -DBUILD_AAX=OFF
		cmake --build "${src}/build" -j"${jobs}" --target TONE3000_VST3 TONE3000_LV2 TONE3000_Standalone
		art="${src}/build/plugin/TONE3000_artefacts/Release"
		install -d "${stage}/usr/lib/vst3" "${stage}/usr/lib/lv2"
		cp -a "${art}/VST3/TONE3000.vst3" "${stage}/usr/lib/vst3/"
		cp -a "${art}/LV2/TONE3000.lv2" "${stage}/usr/lib/lv2/"
		install -Dm 0755 "${art}/Standalone/TONE3000" "${stage}/usr/bin/TONE3000"
		# The factory presets go where the plug-in looks for a system-wide copy on Linux
		# (plugin/src/PresetManager.cpp); its own tarball copies them into each home instead.
		install -d "${stage}/usr/share/TONE3000/Presets/Factory"
		install -m 0644 "${src}"/resources/factory-presets/*.t3kpreset "${stage}/usr/share/TONE3000/Presets/Factory/"
		install -Dm 0644 "${src}/script/installer/linux/tone3000.png" "${stage}/usr/share/icons/hicolor/512x512/apps/tone3000.png"
		desktop_entry "${stage}/usr/share/applications/tone3000.desktop" TONE3000 "Play NAM captures and IRs from TONE3000" TONE3000 tone3000
		# What is built into the binaries besides TONE3000's own MIT code. JUCE is dual-licensed
		# (AGPLv3 or a commercial licence); a build from the public source uses it under the
		# AGPLv3, so the package is distributed under those terms, its source at the commit above.
		awk '/^\/\*$/ { on = 1 } on { print } on && /\*\/[[:space:]]*$/ { exit }' \
			"${src}/plugin/AudioDSPTools/dsp/ResamplingContainer/Dependencies/LanczosResampler.h" > "${work}/iplug2-licence"
		printf 'The JUCE framework is used under the GNU Affero General Public License version 3:\n/usr/share/common-licenses/AGPL-3\n\n' > "${work}/juce-agpl"
		cat "${src}/libs/juce/LICENSE.md" >> "${work}/juce-agpl"
		licences=(
			"JUCE 9 (modules built in)=${work}/juce-agpl"
			"NeuralAmpModelerCore (MIT)=${src}/plugin/NeuralAmpModelerCore/LICENSE"
			"AudioDSPTools (MIT)=${src}/plugin/AudioDSPTools/LICENSE"
			"AudioDSPTools' Lanczos resampler, from iPlug2 and WDL (zlib-style)=${work}/iplug2-licence"
			"Eigen (MPL-2.0, /usr/share/common-licenses/MPL-2.0)=${src}/plugin/NeuralAmpModelerCore/Dependencies/eigen/COPYING.README"
			"FreeType (built in; the FreeType License)=${src}/libs/freetype/docs/FTL.TXT"
			"Arimo font (Apache-2.0, /usr/share/common-licenses/Apache-2.0)=${src}/plugin/ui/assets/Arimo-LICENSE.txt"
			"Roboto Mono font (Apache-2.0)=${src}/plugin/ui/assets/RobotoMono-LICENSE.txt"
			"QR Code generator library (MIT)=${src}/plugin/ui/vendor/qrcodegen/LICENSE.txt"
		)
		[[ -s "${work}/iplug2-licence" ]] || die "the iPlug2 licence block in LanczosResampler.h moved"
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
	for l in "${licences[@]}"; do
		[[ -f "${l#*=}" ]] || die "licence file missing: ${l#*=}"
		printf '\n==> %s <==\n\n' "${l%%=*}"
		cat "${l#*=}"
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
