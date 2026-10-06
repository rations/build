# @description Installs the Pivuan boot splash (`pivuan-plymouth-theme`, a plymouth theme: the Pivuan logo swept in by a band of light, with electricity running along its circuit traces) into Devuan (Pivuan) images, minimal ones too, and turns the splash on in the Raspberry Pi's kernel command line. The package is built at image-build time from `plymouth-theme/` of `PIVUAN_PLYMOUTH_REPO` (branch `PIVUAN_PLYMOUTH_BRANCH`), then installed with apt so plymouth comes from the Devuan archive. Armbian's own theme (`PLYMOUTH`, armbian-plymouth-theme) is turned off. Enabled automatically for Devuan releases.
function extension_prepare_config__pivuan_plymouth() {
	declare -g PIVUAN_PLYMOUTH_REPO="${PIVUAN_PLYMOUTH_REPO:-https://github.com/rations/pivuan.git}"
	declare -g PIVUAN_PLYMOUTH_BRANCH="${PIVUAN_PLYMOUTH_BRANCH:-master}"
	# Not Armbian's theme: this extension installs plymouth with the Pivuan one.
	declare -g PLYMOUTH="no"
	display_alert "Extension: ${EXTENSION}: boot splash source" "${PIVUAN_PLYMOUTH_REPO} ${PIVUAN_PLYMOUTH_BRANCH}" "info"
}

# Runs after install_distribution_agnostic, which removes plymouth when PLYMOUTH=no.
function post_repo_customize_image__install_pivuan_plymouth() {
	fetch_from_repo "${PIVUAN_PLYMOUTH_REPO}" "pivuan-plymouth" "branch:${PIVUAN_PLYMOUTH_BRANCH}"
	declare srcdir="${SRC}/cache/sources/pivuan-plymouth/plymouth-theme"
	declare outdir="${WORKDIR}/pivuan-plymouth"
	run_host_command_logged rm -rf "${outdir}"
	run_host_command_logged make -C "${srcdir}" BUILD="${outdir}" deb
	declare deb
	deb="$(ls "${outdir}"/pivuan-plymouth-theme_*_all.deb)" || exit_with_error "Building pivuan-plymouth-theme failed" "${srcdir}"
	display_alert "Extension: ${EXTENSION}: installing" "$(basename "${deb}")" "info"
	# Brings plymouth; its postinst chooses the theme and rebuilds the initramfs.
	install_deb_chroot "${deb}"
	run_host_command_logged rm -f "${SDCARD}/root/$(basename "${deb}")"

	# plymouth depends on "systemd | elogind": it must have taken elogind.
	if awk '/^Package: / { p = $2 } /^Status: install ok installed/ && p == "systemd" { found = 1 } END { exit !found }' \
		"${SDCARD}/var/lib/dpkg/status"; then
		exit_with_error "systemd was installed with plymouth" "${EXTENSION}"
	fi

	# Without its init script the screen stays frozen after the splash (plymouth-theme 1.0.1 and later).
	compgen -G "${SDCARD}/etc/rc2.d/S??pivuan-splash" > /dev/null \
		|| exit_with_error "the boot splash's init script (pivuan-splash) is not started at boot" "${EXTENSION}"
}

# cmdline.txt is written by pre_umount_final_image__write_raspi_cmdline (bcm2711.conf), after
# the packages: add the splash options the package's postinst adds on installed systems.
# 900_ sorts after it (hooks without a number sort as 500_).
function pre_umount_final_image__900_pivuan_splash_cmdline() {
	declare cmdline="${MOUNT}/boot/firmware/cmdline.txt"
	[[ -f "${cmdline}" ]] || return 0
	declare option
	for option in splash plymouth.ignore-serial-consoles; do
		grep -qE "(^| )${option}( |\$)" "${cmdline}" || sed -i "1s/\$/ ${option}/" "${cmdline}"
	done
	display_alert "Extension: ${EXTENSION}: kernel command line" "$(< "${cmdline}")" "info"
}
