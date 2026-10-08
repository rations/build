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
# a library. MODE=pivuan-config also checks the desktop pivuan-config set up: the login
# screen and its backgrounds, the session scripts, PulseAudio into JACK (with JACK's dummy
# driver), Desktop Settings and the panel it makes, the Pivuan menu (jgmenu) and Extract Here.
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
for pkg in systemd systemd-sysv pipewire pipewire-bin pipewire-pulse wireplumber lightdm xserver-xorg-core audio-gui pasystray; do
	if installed "${pkg}"; then error "${pkg} is installed"; fi
done
if grep -rhs '^[^#]*\(xlibre-debian\|backports\)' /etc/apt/sources.list /etc/apt/sources.list.d/; then
	error "an xlibre-debian or backports source is configured"
fi
# What must be: PulseAudio for HDMI, Bluetooth and ordinary programs (and into JACK), the
# compositor, the icon themes (Pivuan's, and Numix for the icons it lacks).
for pkg in pulseaudio pulseaudio-utils pulseaudio-module-bluetooth pulseaudio-module-jack pavucontrol picom pivuan-icon-theme numix-icon-theme; do
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
	# Login: xlogin-launcher on tty1 under its own id (so telinit q replaces the getty's
	# running text login), text logins on tty2-6, the original kept.
	grep -qx 'x1:2345:respawn:/usr/bin/xlogin-launcher' /etc/inittab || error "tty1 does not start xlogin-launcher (id x1)"
	[[ -d /etc/inittab.d ]] || error "no /etc/inittab.d (init reports its absence on every reload)"
	if grep -qE '^1:[0-9]*:respawn:.*getty' /etc/inittab; then error "tty1 still has an active getty"; fi
	for vt in 2 3 4 5 6; do
		grep -qE "^${vt}:[0-9]*:respawn:.*getty.*tty${vt}" /etc/inittab || error "tty${vt} lost its getty"
	done
	cmp -s /tmp/inittab.orig /etc/armbian/desktop/audio.inittab || error "the inittab backup is not the original"
	# Backgrounds: the seven Pivuan backgrounds, black by default, for the desktop and
	# the login screen (xlogin reads only root-owned files nobody else can write).
	grep -q "^XLOGIN_BACKGROUND='background-black.png'" /etc/xlogin.conf 2> /dev/null || error "no /etc/xlogin.conf with the black background"
	for colour in black blue dark-gray gray green orange yellow; do
		[[ -f "/usr/share/backgrounds/pivuan/background-${colour}.png" ]] || error "no /usr/share/backgrounds/pivuan/background-${colour}.png"
		[[ "$(stat -c '%U %a' "/usr/share/xlogin/backgrounds/background-${colour}.png" 2> /dev/null)" == "root 644" ]] \
			|| error "the login background background-${colour}.png is missing or not root-owned 0644"
	done
	if grep -rqs 'pivuan-background' /etc/jwm /etc/xlogin.conf /usr/lib/pivuan "${home}/.jwmrc"; then
		error "pivuan-background.png (the old name) is still referenced"
	fi
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
	for f in /usr/lib/pivuan/audio-session /usr/lib/pivuan/pulse-session /usr/lib/pivuan/autostart /usr/lib/pivuan/jwm-desktop \
		/usr/lib/pivuan/keyboard /usr/lib/pivuan/menu /usr/lib/pivuan/menu-items /usr/lib/pivuan/session \
		/usr/lib/pivuan/wine-menu /usr/lib/pivuan/desktop-icons /usr/lib/pivuan/extract-here; do
		if [[ ! -x "${f}" ]]; then
			error "no ${f}"
		elif ! sh -n "${f}"; then
			error "${f} is not valid sh"
		fi
	done
	grep -q '<StartupCommand>/usr/lib/pivuan/pulse-session' /etc/jwm/pivuan.jwmrc || error "JWM does not start /usr/lib/pivuan/pulse-session"
	grep -q '<StartupCommand>/usr/lib/pivuan/autostart' /etc/jwm/pivuan.jwmrc || error "JWM does not start /usr/lib/pivuan/autostart"
	grep -q '<StartupCommand>picom .*--config /etc/pivuan/picom.conf' /etc/jwm/pivuan.jwmrc || error "JWM does not start picom with /etc/pivuan/picom.conf"
	grep -qx 'shadow = false;' /etc/pivuan/picom.conf 2> /dev/null || error "no /etc/pivuan/picom.conf without shadows"
	grep -qx 'backend = "xrender";' /etc/pivuan/picom.conf 2> /dev/null || error "/etc/pivuan/picom.conf does not use the xrender backend"
	grep -q '<ResizeMode>outline</ResizeMode>' /etc/jwm/pivuan.jwmrc || error "JWM does not resize with an outline"
	# The panel and background: /usr/lib/pivuan/jwm-desktop, from the user's Desktop Settings.
	grep -q '<Include>exec:/usr/lib/pivuan/jwm-desktop</Include>' /etc/jwm/pivuan.jwmrc || error "JWM does not include /usr/lib/pivuan/jwm-desktop"
	xml_ok() { python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.stdin)'; }
	su -l -s /bin/sh -c /usr/lib/pivuan/jwm-desktop pivuan > /tmp/jwm-desktop.xml 2> /tmp/jwm-desktop.err || error "/usr/lib/pivuan/jwm-desktop failed: $(cat /tmp/jwm-desktop.err)"
	xml_ok < /tmp/jwm-desktop.xml || error "/usr/lib/pivuan/jwm-desktop does not print valid XML (no settings)"
	grep -q 'exec:pavucontrol' /tmp/jwm-desktop.xml || error "the tray has no button for Volume Control"
	grep -q 'autohide="off"' /tmp/jwm-desktop.xml || error "the panel hides without settings"
	grep -q '<Tray x="0" y="-1" height="30" ' /tmp/jwm-desktop.xml || error "the panel is not 30 pixels high without settings"
	grep -q '<Background>#959597</Background>' /tmp/jwm-desktop.xml || error "the panel is not Pivuan grey (#959597) without settings"
	[[ -f /usr/share/pixmaps/pivuan/pivuan-panel.png ]] || error "no /usr/share/pixmaps/pivuan/pivuan-panel.png (the menu button's logo on a grey panel)"
	grep -q '<TrayButton icon="/usr/share/pixmaps/pivuan/pivuan-panel.png" popup="Pivuan menu">' /tmp/jwm-desktop.xml \
		|| error "the menu button on the grey panel is not the outlined logo (pivuan-panel.png)"
	grep -q '<Background type="scale">/usr/share/backgrounds/pivuan/background-black.png</Background>' /tmp/jwm-desktop.xml \
		|| error "the default desktop background is not black"
	# With settings, as Desktop Settings writes them: another background, a hidden panel, a
	# program icon (Volume Control's .desktop file, org.pulseaudio.pavucontrol.desktop in
	# pavucontrol 6), and one that is not installed (skipped).
	volume_app="$(dpkg -L pavucontrol | sed -n 's|^/usr/share/applications/\([^/]*\.desktop\)$|\1|p' | head -n 1)"
	[[ -n "${volume_app}" ]] || error "pavucontrol has no .desktop file"
	su -s /bin/sh -c "mkdir -p ${home}/.config/pivuan && printf '%s\n' \
		'background=/usr/share/backgrounds/pivuan/background-blue.png' autohide=yes \
		launcher=${volume_app} launcher=not-installed.desktop panel_size=40 icon_size=24 \
		'panel_colour=#E8E4D8' > ${home}/.config/pivuan/desktop.conf" pivuan
	su -l -s /bin/sh -c /usr/lib/pivuan/jwm-desktop pivuan > /tmp/jwm-desktop-set.xml
	xml_ok < /tmp/jwm-desktop-set.xml || error "/usr/lib/pivuan/jwm-desktop does not print valid XML (with settings)"
	grep -q 'autohide="bottom"' /tmp/jwm-desktop-set.xml || error "Desktop Settings: the panel does not hide"
	grep -q 'background-blue.png</Background>' /tmp/jwm-desktop-set.xml || error "Desktop Settings: the background is not the one chosen"
	grep -q '<Tray x="0" y="-1" height="40" ' /tmp/jwm-desktop-set.xml || error "Desktop Settings: the panel size is not the one chosen"
	grep -q '<Background>#E8E4D8</Background>' /tmp/jwm-desktop-set.xml || error "Desktop Settings: the panel colour is not the one chosen"
	grep -q '<Foreground>#1E1E1E</Foreground>' /tmp/jwm-desktop-set.xml || error "Desktop Settings: the text on a light panel is not dark"
	grep -q '<TrayButton icon="[^"]*" popup="[^"]*">exec:pavucontrol</TrayButton>' /tmp/jwm-desktop-set.xml \
		|| error "Desktop Settings: no panel icon for Volume Control (${volume_app})"
	(cd "${home}" && HOME="${home}" jwm -p > /tmp/jwm-parse-set.log 2>&1) || true
	if [[ -s /tmp/jwm-parse-set.log ]]; then cat /tmp/jwm-parse-set.log; error "jwm reports problems with Desktop Settings applied"; fi
	summary "- Desktop Settings panel (${volume_app}): \`$(grep -o '<TrayButton [^>]*>exec:pavucontrol<' /tmp/jwm-desktop-set.xml)\`"
	if [[ ! -x /usr/bin/pivuan-desktop-settings ]]; then
		error "no /usr/bin/pivuan-desktop-settings"
	elif ! su -l -s /bin/sh -c 'pivuan-desktop-settings --check' pivuan > /tmp/settings-check.log 2>&1; then
		cat /tmp/settings-check.log
		error "pivuan-desktop-settings does not start (Python or GTK missing)"
	elif ! grep -qx "launchers: ${volume_app} not-installed.desktop" /tmp/settings-check.log \
		|| ! grep -qx 'panel size: 40' /tmp/settings-check.log || ! grep -qx 'icon size: 24' /tmp/settings-check.log; then
		cat /tmp/settings-check.log
		error "pivuan-desktop-settings does not read the settings"
	fi
	# The panel icons, made without a display: each exactly panel size - 8 (JWM's size for
	# a panel icon), for Volume Control, the speaker and the program that is not installed
	# (the generic icon); the panel uses them.
	su -l -s /bin/sh -c 'pivuan-desktop-settings --render-icons' pivuan > /tmp/render-icons.log 2>&1 \
		|| { cat /tmp/render-icons.log; error "pivuan-desktop-settings --render-icons failed"; }
	cat /tmp/render-icons.log
	for icon in audio-speakers "${volume_app%.desktop}" not-installed; do
		grep -qx "${home}/.config/pivuan/panel-icons/${icon}.png 32x32" /tmp/render-icons.log \
			|| error "Desktop Settings: no 32x32 panel icon for ${icon}"
	done
	su -l -s /bin/sh -c /usr/lib/pivuan/jwm-desktop pivuan > /tmp/jwm-desktop-icons.xml
	grep -q "icon=\"${home}/.config/pivuan/panel-icons/${volume_app%.desktop}.png\"" /tmp/jwm-desktop-icons.xml \
		|| error "the panel does not use the icons Desktop Settings made"
	# Invalid values give the defaults.
	su -s /bin/sh -c "printf '%s\n' panel_size=500 icon_size=x 'panel_colour=#GGGGGG' > ${home}/.config/pivuan/desktop.conf" pivuan
	su -l -s /bin/sh -c /usr/lib/pivuan/jwm-desktop pivuan > /tmp/jwm-desktop-bad.xml
	xml_ok < /tmp/jwm-desktop-bad.xml || error "/usr/lib/pivuan/jwm-desktop does not print valid XML (invalid settings)"
	if ! grep -q '<Tray x="0" y="-1" height="30" ' /tmp/jwm-desktop-bad.xml \
		|| ! grep -q '<Background>#959597</Background>' /tmp/jwm-desktop-bad.xml; then
		error "invalid panel settings do not give the defaults"
	fi
	rm -rf "${home}/.config/pivuan/desktop.conf" "${home}/.config/pivuan/panel-icons"
	# The Pivuan menu (jgmenu): the panel button, Alt+F1 and a right click on the desktop open it
	# (/usr/lib/pivuan/menu), and /usr/lib/pivuan/menu-items makes it from the programs' .desktop
	# files by category (/etc/xdg/menus/pivuan-applications.menu, through jgmenu's lx module).
	grep -q '<TrayButton [^>]*popup="Pivuan menu">exec:/usr/lib/pivuan/menu panel</TrayButton>' /tmp/jwm-desktop.xml \
		|| error "the panel's Pivuan button does not open the menu (/usr/lib/pivuan/menu)"
	grep -q '<Mouse context="root" button="3">exec:/usr/lib/pivuan/menu pointer</Mouse>' /etc/jwm/pivuan.jwmrc \
		|| error "a right click on the desktop does not open the menu"
	grep -q '<Key mask="A" key="F1">exec:/usr/lib/pivuan/menu panel</Key>' /etc/jwm/pivuan.jwmrc || error "Alt+F1 does not open the menu"
	for f in /etc/pivuan/jgmenurc /etc/xdg/menus/pivuan-applications.menu /usr/share/desktop-directories/pivuan-audio.directory; do
		[[ -f "${f}" ]] || error "no ${f}"
	done
	command -v jgmenu > /dev/null || error "jgmenu is not installed"
	su -l -s /bin/sh -c /usr/lib/pivuan/menu-items pivuan > /tmp/menu.csv 2> /tmp/menu.err || error "/usr/lib/pivuan/menu-items failed: $(cat /tmp/menu.err)"
	for item in 'Terminal,lxterminal,' 'Home,pcmanfm ' 'Audio,^checkout(' 'Settings,^checkout(' 'Jack Graph,jack-graph,' \
		'Volume Control,pavucontrol,' 'Desktop Settings,pivuan-desktop-settings,' 'On-screen Keyboard,/usr/lib/pivuan/keyboard toggle,' \
		'Wine Configuration,winecfg,' 'Shut Down,/usr/lib/pivuan/session poweroff,'; do
		grep -qF "${item}" /tmp/menu.csv || error "the menu has no ${item%%,*}"
	done
	if grep -qE '^(Pivuan Config|jgmenu|picom),' /tmp/menu.csv; then error "the menu lists Pivuan Config, jgmenu or picom"; fi
	summary "- Menu: $(grep -o '^[^,]*,^checkout(' /tmp/menu.csv | cut -d, -f1 | tr '\n' ' ')"
	# Extract Here: pcmanfm's action (libfm-modules runs actions) and the script, on a zip and a
	# tar.gz with several files each, and a zip with one folder.
	[[ -f /usr/share/file-manager/actions/pivuan-extract-here.desktop ]] || error "no Extract Here action for pcmanfm"
	compgen -G '/usr/lib/*/libfm/modules/gtk-menu-actions.so' > /dev/null || error "libfm-modules is missing: pcmanfm shows no Extract Here"
	su -l -s /bin/sh -c 'set -e; rm -rf /tmp/extract; mkdir -p /tmp/extract/in/top && cd /tmp/extract/in
		echo a > a.txt; echo b > b.txt; echo c > top/c.txt
		python3 -c "import zipfile; z = zipfile.ZipFile(\"../many.zip\", \"w\"); z.write(\"a.txt\"); z.write(\"b.txt\"); z.close(); z = zipfile.ZipFile(\"../one.zip\", \"w\"); z.write(\"top/c.txt\"); z.close()"
		tar -czf ../many.tar.gz a.txt b.txt
		cd .. && /usr/lib/pivuan/extract-here many.zip many.tar.gz one.zip' pivuan > /tmp/extract.log 2>&1 \
		|| { cat /tmp/extract.log; error "Extract Here failed"; }
	for f in many/a.txt "many (2)/b.txt" top/c.txt; do
		[[ -f "/tmp/extract/${f}" ]] || error "Extract Here did not make /tmp/extract/${f}"
	done
	# GTK uses the Pivuan icons (pivuan-icon-theme), which inherit Numix's for the ones they lack.
	grep -qx 'gtk-icon-theme-name=Pivuan' "${home}/.config/gtk-3.0/settings.ini" 2> /dev/null || error "GTK 3 does not use the Pivuan icons"
	grep -q '^Inherits=.*Numix' /usr/share/icons/Pivuan/index.theme 2> /dev/null || error "the Pivuan icon theme does not inherit Numix"
	grep -q '^load-module module-udev-detect tsched=0' /etc/pulse/default.pa 2> /dev/null || error "PulseAudio's udev-detect lacks tsched=0 (HDMI)"
	# The login-time script: the folders and pcmanfm bookmarks, for the user.
	su -l -s /bin/sh -c /usr/lib/pivuan/audio-session pivuan || error "/usr/lib/pivuan/audio-session failed"
	for d in Downloads Documents Music Videos NAM "Impulse Responses" .vst3 .lv2; do
		[[ "$(stat -c %U "${home}/${d}" 2> /dev/null)" == pivuan ]] || error "${home}/${d} missing or not the user's"
	done
	[[ "$(grep -c '^file://' "${home}/.config/gtk-3.0/bookmarks" 2> /dev/null)" == 8 ]] || error "pcmanfm does not have the 8 bookmarks"
	# The autostart runner: lxrandr's kind of entry (LXDE only) and plain ones run; hidden ones
	# and those of other desktops do not.
	autostart="${home}/.config/autostart"
	su -s /bin/sh -c "mkdir -p '${autostart}'" pivuan
	as_entry() { printf '[Desktop Entry]\nType=Application\nName=%s\nExec=touch /tmp/autostart-%s %%U\n%s\n' "$1" "$1" "$2" > "${autostart}/check-$1.desktop"; }
	as_entry lxde 'OnlyShowIn=LXDE'
	as_entry all ''
	as_entry hidden 'Hidden=true'
	as_entry xfce 'OnlyShowIn=XFCE;'
	as_entry notlxde 'NotShowIn=LXDE;'
	chown pivuan: "${autostart}"/check-*.desktop
	rm -f /tmp/autostart-*
	su -l -s /bin/sh -c /usr/lib/pivuan/autostart pivuan || error "/usr/lib/pivuan/autostart failed"
	sleep 2
	for e in lxde all; do
		[[ -e "/tmp/autostart-${e}" ]] || error "/usr/lib/pivuan/autostart did not start the ${e} entry"
	done
	for e in hidden xfce notlxde; do
		[[ ! -e "/tmp/autostart-${e}" ]] || error "/usr/lib/pivuan/autostart started the ${e} entry"
	done
	rm -f "${autostart}"/check-*.desktop /tmp/autostart-*
	# PulseAudio into JACK: with PulseAudio running, start JACK (its dummy driver: no sound
	# card here) and pulse-session must load the JACK sink ("JACK (audio interface)") and make
	# it the default output; when JACK stops, the previous default comes back. PulseAudio runs
	# with a null sink only (no sound card, no D-Bus session here).
	cat > /tmp/jack-check.sh << 'EOF'
export XDG_RUNTIME_DIR=/tmp/xdg-pivuan
mkdir -p -m 0700 "${XDG_RUNTIME_DIR}"
pulseaudio --daemonize=yes -n --exit-idle-time=-1 --log-target=file:/tmp/pulse.log \
	-L module-native-protocol-unix -L 'module-null-sink sink_name=check_null' || exit 1
sleep 1
/usr/lib/pivuan/pulse-session > /tmp/pulse-session.log 2>&1 &
session=$!
sleep 3
echo "before: $(pactl get-default-sink)"
jackd --no-realtime -d dummy -r 48000 > /tmp/jackd.log 2>&1 &
jack=$!
for i in 1 2 3 4 5 6 7 8 9 10; do
	sleep 1
	pactl list short sinks | grep -q jack_out && break
done
sleep 1
echo "with JACK: $(pactl get-default-sink)"
pactl list sinks | sed -n 's/^\tDescription: /description: /p'
kill "${jack}"
for i in 1 2 3 4 5 6 7 8 9 10; do
	sleep 1
	pactl list short sinks | grep -q jack_out || break
done
sleep 3
echo "after JACK: $(pactl get-default-sink)"
kill "${session}"
pulseaudio -k
EOF
	chmod 0755 /tmp/jack-check.sh
	su -l -s /bin/sh -c /tmp/jack-check.sh pivuan > /tmp/jack-check.log 2>&1 || true
	cat /tmp/jack-check.log
	grep -qx 'with JACK: jack_out' /tmp/jack-check.log || error "PulseAudio does not play into JACK while JACK runs (no default jack_out)"
	grep -qx 'description: JACK (audio interface)' /tmp/jack-check.log || error "the JACK sink is not named \"JACK (audio interface)\""
	grep -qx 'after JACK: check_null' /tmp/jack-check.log || error "the default output does not come back when JACK stops"
	if ! grep -qx 'with JACK: jack_out' /tmp/jack-check.log; then
		echo "::group::PulseAudio, jackd and pulse-session logs"
		tail -n 30 /tmp/pulse.log /tmp/jackd.log /tmp/pulse-session.log 2> /dev/null
		echo "::endgroup::"
	fi
	summary "- PulseAudio into JACK: $(grep -E '^(before|with JACK|after JACK):' /tmp/jack-check.log | tr '\n' ' ')"
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
	done < <(cat /etc/jwm/pivuan.jwmrc /tmp/jwm-desktop.xml | grep -o 'icon="[^"]*"' | cut -d'"' -f2 | sort -u)
	# Numix's icons are SVG: JWM draws them only when built with librsvg.
	ldd /usr/bin/jwm 2> /dev/null | grep -q 'librsvg' || error "jwm is built without SVG support (librsvg): Numix's icons would not show"
	if ((${#missing_icons[@]})); then
		error "menu icons not found in JWM's IconPaths: ${missing_icons[*]}"
	fi
	summary "- Menu and panel icons: $(cat /etc/jwm/pivuan.jwmrc /tmp/jwm-desktop.xml | grep -o 'icon="[^"]*"' | sort -u | wc -l) names, missing: ${missing_icons[*]:-none}"
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
	summary "- /etc/inittab after the install: \`$(grep -E '^x?[1-6]:' /etc/inittab | tr '\n' ' ')\`"

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
