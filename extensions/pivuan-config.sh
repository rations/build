# @description Installs `pivuan-config` into Devuan (Pivuan) images: armbian-config (configng) from the Pivuan fork, with a sysvinit service backend and no systemd dependency. The package is built at image-build time from `PIVUAN_CONFIG_REPO` (branch `PIVUAN_CONFIG_BRANCH`) with the fork's `tools/pivuan/build-deb.sh`, then installed with apt so its dependencies come from the Devuan archive. Enabled automatically for Devuan releases, in place of the `armbian-config` extension.

function extension_prepare_config__pivuan_config() {
	declare -g PIVUAN_CONFIG_REPO="${PIVUAN_CONFIG_REPO:-https://github.com/rations/configng.git}"
	declare -g PIVUAN_CONFIG_BRANCH="${PIVUAN_CONFIG_BRANCH:-claude/loving-fermi-gp2uoo}"
	display_alert "Extension: ${EXTENSION}: pivuan-config source" "${PIVUAN_CONFIG_REPO} ${PIVUAN_CONFIG_BRANCH}" "info"
}

function post_repo_customize_image__install_pivuan_config() {
	fetch_from_repo "${PIVUAN_CONFIG_REPO}" "pivuan-configng" "branch:${PIVUAN_CONFIG_BRANCH}"
	declare srcdir="${SRC}/cache/sources/pivuan-configng"

	declare outdir="${WORKDIR}/pivuan-config"
	run_host_command_logged rm -rf "${outdir}"
	run_host_command_logged mkdir -p "${outdir}"
	declare deb
	deb="$(bash "${srcdir}/tools/pivuan/build-deb.sh" "${outdir}")" || exit_with_error "Building pivuan-config failed" "${srcdir}"
	display_alert "Extension: ${EXTENSION}: installing" "$(basename "${deb}")" "info"
	install_deb_chroot "${deb}"
	run_host_command_logged rm -f "${SDCARD}/root/$(basename "${deb}")"

	# Keep a copy for the Pivuan apt repository (published by the "Pivuan image build" workflow).
	declare publish_dir="${SRC}/output/pivuan-publish"
	run_host_command_logged mkdir -p "${publish_dir}"
	run_host_command_logged rm -f "${publish_dir}"/pivuan-config_*.deb
	run_host_command_logged cp -v "${deb}" "${publish_dir}/"
}
