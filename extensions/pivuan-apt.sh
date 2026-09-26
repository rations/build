# @description Adds the Pivuan apt repository (kernel, firmware, board support and pivuan-config updates for installed systems) to Devuan (Pivuan) images. The repository is published by the "Pivuan image build" workflow to GitHub Pages of rations/pivuan. `PIVUAN_APT_KEY_FILE` is the repository's public signing key (armored); without it the image gets no Pivuan source. Enabled automatically for Devuan releases.

function extension_prepare_config__pivuan_apt() {
	declare -g PIVUAN_APT_URL="${PIVUAN_APT_URL:-https://rations.github.io/pivuan}"
	declare -g PIVUAN_APT_KEY_FILE="${PIVUAN_APT_KEY_FILE:-}"
	if [[ -n "${PIVUAN_APT_KEY_FILE}" && ! -s "${PIVUAN_APT_KEY_FILE}" ]]; then
		exit_with_error "PIVUAN_APT_KEY_FILE does not exist or is empty" "${PIVUAN_APT_KEY_FILE}"
	fi
	display_alert "Extension: ${EXTENSION}: Pivuan apt repository" "${PIVUAN_APT_URL} key: ${PIVUAN_APT_KEY_FILE:-none, not added}" "info"
}

# Added at the very end of the image build, after the image's last `apt-get update`, so the build
# never depends on the repository being reachable (the first published build creates it).
function pre_umount_final_image__pivuan_apt_source() {
	if [[ -z "${PIVUAN_APT_KEY_FILE}" ]]; then
		display_alert "Extension: ${EXTENSION}: no PIVUAN_APT_KEY_FILE" "image gets no Pivuan apt source" "warn"
		return 0
	fi
	declare keyring="/usr/share/keyrings/pivuan-archive-keyring.gpg"
	declare gpg_tmp
	gpg_tmp="$(mktemp -d)"
	run_host_command_logged mkdir -p "${MOUNT}/usr/share/keyrings" "${MOUNT}/etc/apt/sources.list.d"
	gpg --homedir "${gpg_tmp}" --batch --yes --dearmor < "${PIVUAN_APT_KEY_FILE}" > "${MOUNT}${keyring}"
	rm -rf "${gpg_tmp}"
	chmod 0644 "${MOUNT}${keyring}"
	cat <<- EOF > "${MOUNT}/etc/apt/sources.list.d/pivuan.sources"
		Types: deb
		URIs: ${PIVUAN_APT_URL}
		Suites: ${RELEASE}
		Components: main
		Signed-By: ${keyring}
	EOF
	display_alert "Extension: ${EXTENSION}: added" "/etc/apt/sources.list.d/pivuan.sources -> ${PIVUAN_APT_URL}" "info"
}
