#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2026 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

# Service helpers for the target rootfs (SDCARD). INIT_SYSTEM (set in main-config.sh) selects
# systemd (systemctl) or sysvinit (update-rc.d + /etc/init.d scripts, used for Devuan).
# Service names may be given with or without a ".service" suffix; for sysvinit it is stripped.

# service_exists_sdcard <service>: true if the target has a unit (systemd) or an init script (sysvinit) for it.
function service_exists_sdcard() {
	declare service="${1}"
	if [[ "${INIT_SYSTEM}" == "sysvinit" ]]; then
		[[ -x "${SDCARD}/etc/init.d/${service%.service}" ]]
	else
		[[ "${service}" == *.* ]] || service="${service}.service"
		[[ -f "${SDCARD}/lib/systemd/system/${service}" || -f "${SDCARD}/etc/systemd/system/${service}" ]]
	fi
}

# enable_service_sdcard <service> [<service> ...]: enable services on the target, inside the chroot.
function enable_service_sdcard() {
	declare service
	for service in "${@}"; do
		if [[ "${INIT_SYSTEM}" == "sysvinit" ]]; then
			service="${service%.service}"
			if [[ -x "${SDCARD}/etc/init.d/${service}" ]]; then
				chroot_sdcard update-rc.d "${service}" defaults
			else
				display_alert "No init script on target, not enabling" "${service}" "wrn"
			fi
		else
			chroot_sdcard systemctl --no-reload enable "${service}"
		fi
	done
}

function disable_systemd_service_sdcard() {
	display_alert "Disabling service(s) on target" "${*}" "debug"
	declare service stderr_output
	for service in "${@}"; do
		if [[ "${INIT_SYSTEM}" == "sysvinit" ]]; then
			# Timers and other unit types have no sysvinit equivalent; only act on existing init scripts.
			[[ "${service}" == *.timer ]] && continue
			service="${service%.service}"
			[[ -x "${SDCARD}/etc/init.d/${service}" ]] || continue
			stderr_output="$(LC_ALL=C LANG=C LANGUAGE="" chroot "${SDCARD}" update-rc.d "${service}" disable 2>&1)" || true
			[[ -n "${stderr_output}" ]] && display_alert "update-rc.d ${service} disable" "${stderr_output}" "debug"
			continue
		fi
		# Use --root= to operate directly on the chroot filesystem
		# instead of talking to the host's systemd via D-Bus (which
		# doesn't know about the chroot's unit files).
		stderr_output="$(systemctl --root="${SDCARD}" --no-reload disable "${service}" 2>&1)" || true
		[[ -n "${stderr_output}" ]] && display_alert "systemctl disable ${service}" "${stderr_output}" "debug"
	done
}
