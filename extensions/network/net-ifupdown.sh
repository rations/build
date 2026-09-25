# @description Manages network interfaces with classic `ifupdown`, for sysvinit (Devuan) images where systemd-networkd, systemd-resolved and Netplan don't exist: adds `ifupdown`, `isc-dhcp-client` and `wpasupplicant`, and writes `/etc/network/interfaces` with DHCP on the wired interface plus a disabled Wi-Fi (wpa_supplicant) template. Requires `NETWORKING_STACK=ifupdown`. Pair with `net-chrony` for time sync.

#
# Extension to manage network interfaces with ifupdown (+ wpa_supplicant for Wi-Fi)
#
function extension_prepare_config__install_ifupdown() {
	# Sanity check
	if [[ "${NETWORKING_STACK}" != "ifupdown" ]]; then
		exit_with_error "Extension: ${EXTENSION}: requires NETWORKING_STACK='ifupdown', currently set to '${NETWORKING_STACK}'"
	fi

	display_alert "Extension: ${EXTENSION}: Adding extra packages to image" "ifupdown isc-dhcp-client wpasupplicant" "info"
	add_packages_to_image ifupdown isc-dhcp-client wpasupplicant
}

function pre_install_kernel_debs__configure_ifupdown() {
	display_alert "Extension: ${EXTENSION}: Configuring" "ifupdown: DHCP on wired, Wi-Fi template" "info"

	mkdir -p "${SDCARD}/etc/network/interfaces.d"

	# source-directory only includes files named like run-parts expects ([A-Za-z0-9_-]),
	# so the "wlan0.example" template below is ignored until it is copied to "wlan0".
	cat <<- 'EOF' > "${SDCARD}/etc/network/interfaces"
		# interfaces(5) file used by ifup(8) and ifdown(8)
		# Per-interface configuration lives in /etc/network/interfaces.d/

		auto lo
		iface lo inet loopback

		source-directory /etc/network/interfaces.d
	EOF

	# eudev keeps kernel names (eth0); systemd-style naming would call the same port end0.
	# allow-hotplug only acts on interfaces that actually appear, so listing both is harmless.
	cat <<- 'EOF' > "${SDCARD}/etc/network/interfaces.d/wired"
		# Wired Ethernet, DHCP (IPv4 and SLAAC IPv6)
		allow-hotplug eth0
		iface eth0 inet dhcp
		iface eth0 inet6 auto

		allow-hotplug end0
		iface end0 inet dhcp
		iface end0 inet6 auto
	EOF

	cat <<- 'EOF' > "${SDCARD}/etc/network/interfaces.d/wlan0.example"
		# Wi-Fi via wpa_supplicant (the wpasupplicant package hooks into ifupdown).
		# To use it:
		#   cp /etc/network/interfaces.d/wlan0.example /etc/network/interfaces.d/wlan0
		#   chmod 600 /etc/network/interfaces.d/wlan0      (it holds the passphrase)
		#   edit the SSID and passphrase below and remove the leading '#'
		#   ifup wlan0
		# For several networks use "wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf" instead of wpa-ssid/wpa-psk.
		# If the radio is blocked, check "rfkill list" and set the country: "iw reg set XX".
		#
		#allow-hotplug wlan0
		#iface wlan0 inet dhcp
		#	wpa-ssid YourNetworkName
		#	wpa-psk YourPassphrase
	EOF
}
