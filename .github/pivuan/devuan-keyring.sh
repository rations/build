#!/bin/bash
#
# Fetch the Devuan archive keyring and check it against pinned fingerprints.
#
# Usage: devuan-keyring.sh <release> <out.gpg>
# Environment:
#   DEVUAN_KEY_FINGERPRINTS  fingerprints (space or comma separated) of the keys that must sign
#                            both archives; the output keyring holds only these. Empty: the whole
#                            keyring from the package, unpinned (trust on first use), with a warning.
#   DEVUAN_POOL_BASE         Devuan-only repository (holds devuan-keyring), default pkgmaster.devuan.org
#   DEVUAN_MERGED_BASE       merged archive, default deb.devuan.org/merged
#   GITHUB_STEP_SUMMARY      optional: a summary of the keys is appended to it
#
# How: devuan-keyring is taken from the Devuan-only repository and checked against the SHA256
# in its Packages index; the InRelease files of both archives must verify with it, and (pinned)
# be signed by one of DEVUAN_KEY_FINGERPRINTS. Devuan serves these over plain http, like apt:
# integrity comes from the index checksums, the InRelease signatures and the pinned fingerprints.
#
set -euo pipefail

release="${1:?usage: devuan-keyring.sh <release> <out.gpg>}"
out="$(realpath -m "${2:?usage: devuan-keyring.sh <release> <out.gpg>}")"
pool_base="${DEVUAN_POOL_BASE:-http://pkgmaster.devuan.org/devuan}"
merged_base="${DEVUAN_MERGED_BASE:-http://deb.devuan.org/merged}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cd "${work}"
export GNUPGHOME="${work}/gnupg"
mkdir -m 700 "${GNUPGHOME}"

# 1. Locate devuan-keyring in the Devuan-only repository and check its SHA256 from the index.
curl -fsSL --retry 3 "${pool_base}/dists/${release}/main/binary-arm64/Packages.xz" -o Packages.xz
entry="$(xz -dc Packages.xz | awk 'BEGIN { RS = ""; FS = "\n" } $1 == "Package: devuan-keyring" { print; exit }')"
filename="$(sed -n 's/^Filename: //p' <<< "${entry}")"
sha256="$(sed -n 's/^SHA256: //p' <<< "${entry}")"
if [[ -z "${filename}" || -z "${sha256}" ]]; then
	echo "::error::devuan-keyring not found in ${pool_base} ${release} Packages index"
	exit 1
fi
curl -fsSL --retry 3 "${pool_base}/${filename}" -o devuan-keyring.deb
echo "${sha256}  devuan-keyring.deb" | sha256sum -c -
dpkg-deb -x devuan-keyring.deb extracted
full="${work}/extracted/usr/share/keyrings/devuan-archive-keyring.gpg"
if [[ ! -f "${full}" ]]; then
	echo "::error::devuan-keyring package has no usr/share/keyrings/devuan-archive-keyring.gpg"
	exit 1
fi

# 2. Check which keys sign the two archives.
normalize() { tr '[:lower:],' '[:upper:] ' | tr -s ' \t' '\n' | grep -v '^$' || true; }
pinned="$(normalize <<< "${DEVUAN_KEY_FINGERPRINTS:-}")"
declare -a all_signers=()
for base in "${pool_base}" "${merged_base}"; do
	curl -fsSL --retry 3 "${base}/dists/${release}/InRelease" -o InRelease
	if ! status="$(gpgv --status-fd 1 --keyring "${full}" InRelease 2> gpgv.err)"; then
		cat gpgv.err
		echo "::error::${base}/dists/${release}/InRelease does not verify with devuan-archive-keyring"
		exit 1
	fi
	# VALIDSIG ... <primary key fingerprint> is the last field.
	signers="$(awk '$2 == "VALIDSIG" { print $NF }' <<< "${status}")"
	echo "${base} signed by: ${signers}"
	# shellcheck disable=SC2206 # one fingerprint per word
	all_signers+=(${signers})
	if [[ -n "${pinned}" ]] && ! grep -qxFf <(echo "${pinned}") <<< "${signers}"; then
		echo "::error::${base} is not signed by any key in DEVUAN_KEY_FINGERPRINTS"
		exit 1
	fi
done

# 3. Output a keyring holding only the pinned keys, or (unpinned) the whole package keyring.
mkdir -p "$(dirname "${out}")"
if [[ -n "${pinned}" ]]; then
	# shellcheck disable=SC2086
	gpg --batch --no-default-keyring --keyring "${full}" --export ${pinned} > "${out}"
	[[ -s "${out}" ]] || { echo "::error::none of DEVUAN_KEY_FINGERPRINTS are in devuan-archive-keyring"; exit 1; }
	trust="pinned by DEVUAN_KEY_FINGERPRINTS"
else
	cp "${full}" "${out}"
	trust="**not pinned** (trust on first use)"
	echo "::warning::DEVUAN_KEY_FINGERPRINTS is not set; using the downloaded Devuan keyring unpinned. See the run summary."
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	{
		echo "## Devuan archive keyring"
		echo ""
		echo "- Package: \`${filename}\` (SHA256 matched the ${release} index)"
		echo "- Archive signers: \`$(printf '%s\n' "${all_signers[@]}" | sort -u | tr '\n' ' ')\`"
		echo "- Trust: ${trust}"
		echo ""
		echo "Keys in use (compare with \`gpg --show-keys /usr/share/keyrings/devuan-archive-keyring.gpg\` on your Devuan machine, then put the fingerprint(s) in the repository variable \`DEVUAN_KEY_FINGERPRINTS\`):"
		echo ""
		echo '```'
		gpg --batch --show-keys --with-fingerprint "${out}"
		echo '```'
	} >> "${GITHUB_STEP_SUMMARY}"
fi
