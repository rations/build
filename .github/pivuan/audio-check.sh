#!/bin/bash
#
# Install Pivuan Audio in a Devuan excalibur arm64 root and check it.
# Runs as root inside that root (pivuan-audio-check.yml imports it as a container).
#
# MODE=packages (default): add the Pivuan source and install PACKAGES (no recommends, as
#   pivuan-config installs desktops).
# MODE=pivuan-config: as on a Pivuan image (Pivuan source only, a user, /etc/inittab),
#   install the pivuan-config package PIVUAN_CONFIG_DEB and run
#   "pivuan-config --api module_desktops install de=audio". Then check what the desktop set
#   up, remove it, and check that /etc/inittab is back as it was.
#
# Environment:
#   PIVUAN_APPS        the Pivuan audio applications (from apps.conf)
#   PIVUAN_APT_URL     the Pivuan apt repository
#   KEYS               directory with pivuan-archive-keyring.gpg (binary keyring)
#   PACKAGES           MODE=packages: the packages to install
#   PIVUAN_CONFIG_DEB  MODE=pivuan-config: the pivuan-config .deb
#
# Fails if the install fails, if systemd, PipeWire, LightDM, Audio-Gui or Xorg's own server
# get installed, if PulseAudio (with its JACK and Bluetooth modules) or the compositor is
# missing, if the X server isn't Pivuan's XLibre build (with modesetting, glamor and
# libinput), if a menu icon is missing, or if any program or plug-in of the Pivuan apps misses
# a library.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${PIVUAN_APPS:?}" "${PIVUAN_APT_URL:?}" "${KEYS:?}"
mode="${MODE:-packages}"
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

# 1. apt as on the image: no recommended packages (the board support package's
#    71-armbian-no-recommends; the build repository is mounted at /src), and the Pivuan
#    source (extensions/pivuan-apt.sh).
install -m 0644 /src/packages/bsp/common/etc/apt/apt.conf.d/71-armbian-no-recommends /etc/apt/apt.conf.d/
install -m 0644 "${KEYS}/pivuan-archive-keyring.gpg" /usr/share/keyrings/pivuan-archive-keyring.gpg
cat > /etc/apt/sources.list.d/pivuan.sources << EOF
Types: deb
URIs: ${PIVUAN_APT_URL}
Suites: excalibur
Components: main
Signed-By: /usr/share/keyrings/pivuan-archive-keyring.gpg
EOF

if [[ "${mode}" == packages ]]; then
	# 2. The package set.
	apt-get update -q
	# shellcheck disable=SC2086 # a word list
	if ! apt-get install -y -q --no-install-recommends ${PACKAGES:?} 2>&1 | tee /tmp/install.log; then
		echo "::error::apt-get could not install the Pivuan Audio package set"
		exit 1
	fi
else
	# 2. As on a Pivuan image: the first user (armbian-firstlogin), then pivuan-config.
	useradd -m -u 1000 -s /bin/bash -G sudo,audio pivuan
	cp -p /etc/inittab /tmp/inittab.orig
	apt-get update -q
	apt-get install -y -q --no-install-recommends "${PIVUAN_CONFIG_DEB:?}"
	rc=0
	DIALOG="read" pivuan-config --debug=2:/tmp/pivuan-config.log --api module_desktops install de=audio tier=minimal \
		< /dev/null 2>&1 | tee /tmp/install.log || rc=$?
	if ((rc)) || ! grep -q '^audio installed\.$' /tmp/install.log; then
		echo "::group::pivuan-config debug log"
		grep -v '^+.*module_options\[' /tmp/pivuan-config.log | tail -n 200 || true
		echo "::endgroup::"
		echo "::error::pivuan-config module_desktops install de=audio failed (exit status ${rc})"
		exit 1
	fi
	# In a container nothing reloads /etc/inittab; on a Pi the login screen starts right away.
	grep -q 'reboot to start the graphical login' /tmp/install.log || error "the install did not report how the login screen starts"
fi

# From here on every check reports through error() and the script goes on, so one run lists
# every problem.
set +e

# 3. What must not be there.
installed() { dpkg-query -W -f '${db:Status-Status}' "$1" 2> /dev/null | grep -qx installed; }
for pkg in systemd systemd-sysv pipewire pipewire-bin pipewire-pulse wireplumber lightdm xserver-xorg-core audio-gui; do
	if installed "${pkg}"; then error "${pkg} is installed"; fi
done
if grep -rhs '^[^#]*\(xlibre-debian\|backports\)' /etc/apt/sources.list /etc/apt/sources.list.d/; then
	error "an xlibre-debian or backports source is configured"
fi
# What must be: PulseAudio for HDMI, Bluetooth and ordinary programs (and into JACK), the
# compositor, the icon theme.
for pkg in pulseaudio pulseaudio-utils pulseaudio-module-bluetooth pulseaudio-module-jack pavucontrol pasystray picom numix-icon-theme; do
	installed "${pkg}" || error "${pkg} is not installed"
done

# 4. The X server is Pivuan's XLibre build (rations/pivuan, xlibre/) from the Pivuan
#    repository, with what the Pi 5 needs (99-vc4.conf: modesetting, with glamor; libinput).
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
	[[ "${origin}" == "${PIVUAN_APT_URL}"* && "${xver}" == *+pivuan* ]] \
		|| error "the X server ${xpkg} ${xver} is not Pivuan's XLibre build from ${PIVUAN_APT_URL} (${origin})"
	if version="$("${xserver}" -version 2>&1)"; then
		head -n 3 <<< "${version}"
	else
		error "${xserver} -version failed: ${version}"
	fi
fi
for drv in modesetting_drv.so libglamoregl.so libinput_drv.so; do
	found="$(find /usr/lib/xorg/modules -name "${drv}" -print -quit 2> /dev/null)"
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
if version="$(jackd --version 2>&1)"; then
	head -n 2 <<< "${version}"
else
	error "jackd does not run: ${version}"
fi

# 6. What pivuan-config set up for the desktop, and that removing it undoes the login change.
if [[ "${mode}" == pivuan-config ]]; then
	home=/home/pivuan
	# Login: xlogin-launcher on tty1, text logins on tty2-6, the original kept.
	grep -qx '1:2345:respawn:/usr/bin/xlogin-launcher' /etc/inittab || error "tty1 does not start xlogin-launcher"
	if grep -qE '^1:[0-9]*:respawn:.*getty' /etc/inittab; then error "tty1 still has an active getty"; fi
	for vt in 2 3 4 5 6; do
		grep -qE "^${vt}:[0-9]*:respawn:.*getty.*tty${vt}" /etc/inittab || error "tty${vt} lost its getty"
	done
	cmp -s /tmp/inittab.orig /etc/armbian/desktop/audio.inittab || error "the inittab backup is not the original"
	grep -q "^XLOGIN_BACKGROUND='pivuan-background.png'" /etc/xlogin.conf 2> /dev/null || error "no /etc/xlogin.conf with the Pivuan background"
	[[ "$(stat -c '%U %a' /usr/share/xlogin/backgrounds/pivuan-background.png 2> /dev/null)" == "root 644" ]] \
		|| error "the login background is missing or not root-owned 0644"
	compgen -G "/etc/rc2.d/S*seatd" > /dev/null || error "seatd is not enabled"
	# Session.
	jwm -p -f /etc/jwm/pivuan.jwmrc > /tmp/jwm-parse.log 2>&1 || true
	if [[ -s /tmp/jwm-parse.log ]]; then cat /tmp/jwm-parse.log; error "jwm reports problems in /etc/jwm/pivuan.jwmrc"; fi
	for f in .xinitrc .jwmrc; do
		[[ "$(stat -c %U "${home}/${f}" 2> /dev/null)" == pivuan ]] || error "${home}/${f} missing or not the user's"
	done
	if [[ ! -x "${home}/.xinitrc" ]] || ! grep -qx 'exec dbus-run-session jwm' "${home}/.xinitrc"; then
		error "${home}/.xinitrc does not start JWM"
	fi
	grep -q '/usr/lib/pivuan/audio-session' "${home}/.xinitrc" 2> /dev/null || error "${home}/.xinitrc does not run /usr/lib/pivuan/audio-session"
	for f in /usr/lib/pivuan/audio-session /usr/lib/pivuan/pulse-session; do
		[[ -x "${f}" ]] || error "no ${f}"
	done
	grep -q '/usr/lib/pivuan/pulse-session' /etc/jwm/pivuan.jwmrc || error "JWM does not start /usr/lib/pivuan/pulse-session"
	grep -q '^[^#]*picom' /etc/jwm/pivuan.jwmrc || error "JWM does not start picom"
	grep -qx 'gtk-icon-theme-name=Numix' "${home}/.config/gtk-3.0/settings.ini" 2> /dev/null || error "GTK 3 does not use the Numix icons"
	grep -q '^load-module module-udev-detect tsched=0' /etc/pulse/default.pa 2> /dev/null || error "PulseAudio's udev-detect lacks tsched=0 (HDMI)"
	# The login-time script: the folders and pcmanfm bookmarks, for the user.
	su -l -s /bin/sh -c /usr/lib/pivuan/audio-session pivuan || error "/usr/lib/pivuan/audio-session failed"
	for d in Downloads Documents Music Videos NAM "Impulse Responses" .vst3 .lv2; do
		[[ "$(stat -c %U "${home}/${d}" 2> /dev/null)" == pivuan ]] || error "${home}/${d} missing or not the user's"
	done
	[[ "$(grep -c '^file://' "${home}/.config/gtk-3.0/bookmarks" 2> /dev/null)" == 8 ]] || error "pcmanfm does not have the 8 bookmarks"
	# Every menu icon is a file in one of JWM's IconPaths (JWM looks nowhere else).
	mapfile -t iconpaths < <(sed -n 's|.*<IconPath>\(.*\)</IconPath>.*|\1|p' /etc/jwm/pivuan.jwmrc)
	missing_icons=()
	while IFS= read -r icon; do
		if [[ "${icon}" == /* ]]; then
			[[ -f "${icon}" ]] && continue
		else
			hit=""
			for dir in "${iconpaths[@]}"; do
				for ext in png svg xpm; do
					[[ -f "${dir}/${icon}.${ext}" ]] && { hit=1; break 2; }
				done
			done
			[[ -n "${hit}" ]] && continue
		fi
		missing_icons+=("${icon}")
	done < <(grep -o 'icon="[^"]*"' /etc/jwm/pivuan.jwmrc | cut -d'"' -f2 | sort -u)
	# Numix's icons are SVG: JWM draws them only when built with librsvg.
	ldd /usr/bin/jwm 2> /dev/null | grep -q 'librsvg' || error "jwm is built without SVG support (librsvg): Numix's icons would not show"
	if ((${#missing_icons[@]})); then
		error "menu icons not found in JWM's IconPaths: ${missing_icons[*]}"
	fi
	summary "- Menu icons: $(grep -o 'icon="[^"]*"' /etc/jwm/pivuan.jwmrc | sort -u | wc -l) names, missing: ${missing_icons[*]:-none}"
	(cd "${home}" && HOME="${home}" jwm -p > /tmp/jwm-parse-user.log 2>&1) || true
	if [[ -s /tmp/jwm-parse-user.log ]]; then cat /tmp/jwm-parse-user.log; error "jwm reports problems in ~/.jwmrc"; fi
	# Realtime for JACK, and the user's groups.
	grep -qE '^@audio +- +rtprio +[0-9]+' /etc/security/limits.d/audio.conf 2> /dev/null || error "no realtime limits for @audio"
	id -nG pivuan | tr ' ' '\n' | grep -qx audio || error "the user is not in the audio group"
	# nm-applet: the user may scan for and join Wi-Fi networks (polkit, group netdev).
	id -nG pivuan | tr ' ' '\n' | grep -qx netdev || error "the user is not in the netdev group"
	[[ -f /etc/polkit-1/rules.d/50-pivuan-networkmanager.rules ]] || error "no NetworkManager polkit rule for netdev"
	# Browser (Brave's own repository; a failure there only skips the browser).
	if dpkg-query -W -f '${db:Status-Status}' brave-origin 2> /dev/null | grep -qx installed; then
		summary "- brave-origin $(dpkg-query -W -f '${Version}' brave-origin)"
	else
		echo "::warning::brave-origin was not installed"
		summary "- brave-origin: **not installed**"
	fi
	pivuan-config --api module_desktops status de=audio || error "module_desktops status says audio is not installed"
	summary "- /etc/inittab after the install: \`$(grep -E '^[1-6]:' /etc/inittab | tr '\n' ' ')\`"

	# Remove it again.
	rc=0
	DIALOG="read" pivuan-config --api module_desktops remove de=audio < /dev/null > /tmp/remove.log 2>&1 || rc=$?
	tail -n 20 /tmp/remove.log
	((rc == 0)) || error "module_desktops remove de=audio failed (exit status ${rc})"
	cmp -s /tmp/inittab.orig /etc/inittab || error "/etc/inittab is not back to the original after the removal"
	if [[ -e /etc/armbian/desktop/audio.inittab ]]; then error "the inittab backup was left behind"; fi
	if dpkg-query -W -f '${db:Status-Status}' simple-login-gui 2> /dev/null | grep -qx installed; then
		error "simple-login-gui is still installed"
	fi
	summary "- Removal: /etc/inittab restored, packages removed"
	# The checks above ran against the installed desktop; stop before the package summary.
	exit "${fail}"
fi

# 7. What was installed: every package whose version isn't from Devuan, and the totals.
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
