#!/bin/bash
#
# Update the Pivuan apt repository tree (published on GitHub Pages of rations/pivuan).
#
# Usage: publish-apt.sh <site-dir> <revision> <deb-dir>...
#   site-dir  checkout of the Pages branch; updated in place (pool/, dists/, keys, index.html)
#   revision  REVISION of this build: from the <deb-dir>s, packages whose version is <revision>
#             or starts with "<revision>-" are published (Armbian's reversioned packages), plus
#             every pivuan-config_*.deb (versioned by the configng commit)
#   deb-dir   directories searched recursively for .deb files
# Environment:
#   PIVUAN_APT_SIGNING_KEY_ID  key (fingerprint) in the current GNUPGHOME that signs the repository
#   PIVUAN_APT_SUITE           default: excalibur
#   PIVUAN_APT_ARCH            default: arm64
#   PIVUAN_APT_KEEP            versions kept per package, default: 3
# Needs: dpkg-deb, dpkg, apt-ftparchive (apt-utils), gpg, gzip, xz.
#
set -euo pipefail

site="$1"
revision="$2"
shift 2
suite="${PIVUAN_APT_SUITE:-excalibur}"
arch="${PIVUAN_APT_ARCH:-arm64}"
keep="${PIVUAN_APT_KEEP:-3}"
key="${PIVUAN_APT_SIGNING_KEY_ID:?PIVUAN_APT_SIGNING_KEY_ID is not set}"
# GitHub rejects files over 100 MB; stay under it.
max_bytes=$((95 * 1024 * 1024))

mkdir -p "${site}/pool/main"

# 1. This build's packages into pool/main/<first letter>/<package>/.
added=0
while IFS= read -r -d '' deb; do
	pkg="$(dpkg-deb -f "${deb}" Package)"
	ver="$(dpkg-deb -f "${deb}" Version)"
	deb_arch="$(dpkg-deb -f "${deb}" Architecture)"
	if [[ "$(basename "${deb}")" != pivuan-config_*.deb && "${ver}" != "${revision}" && "${ver}" != "${revision}-"* ]]; then
		continue
	fi
	if [[ "${deb_arch}" != "${arch}" && "${deb_arch}" != all ]]; then
		echo "skip ${pkg} ${ver}: architecture ${deb_arch}"
		continue
	fi
	if (($(stat -c %s "${deb}") > max_bytes)); then
		echo "::warning::${pkg} ${ver} is larger than 95 MB (GitHub's file limit); not published" >&2
		continue
	fi
	dir="${site}/pool/main/${pkg:0:1}/${pkg}"
	mkdir -p "${dir}"
	cp "${deb}" "${dir}/${pkg}_${ver//:/%3a}_${deb_arch}.deb"
	echo "added ${pkg} ${ver} ${deb_arch}"
	added=$((added + 1))
done < <(find "$@" -name '*.deb' -type f -print0 2> /dev/null)
if ((added == 0)); then
	echo "::error::no packages of revision ${revision} found in: $*" >&2
	exit 1
fi

# 2. Keep the newest ${keep} versions of each package.
for dir in "${site}"/pool/main/*/*/; do
	mapfile -t debs < <(find "${dir}" -maxdepth 1 -name '*.deb' -type f)
	((${#debs[@]} > keep)) || continue
	# oldest first, by dpkg's version ordering (insertion sort; a handful of files)
	declare -a ordered=() versions=()
	for d in "${debs[@]}"; do
		v="$(dpkg-deb -f "${d}" Version)"
		i=${#ordered[@]}
		while ((i > 0)) && dpkg --compare-versions "${versions[i - 1]}" gt "${v}"; do
			ordered[i]="${ordered[i - 1]}"
			versions[i]="${versions[i - 1]}"
			i=$((i - 1))
		done
		ordered[i]="${d}"
		versions[i]="${v}"
	done
	for ((i = 0; i < ${#ordered[@]} - keep; i++)); do
		echo "remove old $(basename "${ordered[i]}")"
		rm -f "${ordered[i]}"
	done
	unset ordered versions
done

# 3. Indexes and the signed Release.
dists="${site}/dists/${suite}"
rm -rf "${dists}"
mkdir -p "${dists}/main/binary-${arch}"
(
	cd "${site}"
	apt-ftparchive --arch "${arch}" packages pool/main > "dists/${suite}/main/binary-${arch}/Packages"
)
gzip -9nk "${dists}/main/binary-${arch}/Packages"
xz -9k "${dists}/main/binary-${arch}/Packages"
(
	cd "${dists}"
	apt-ftparchive \
		-o APT::FTPArchive::Release::Origin=Pivuan \
		-o APT::FTPArchive::Release::Label=Pivuan \
		-o APT::FTPArchive::Release::Suite="${suite}" \
		-o APT::FTPArchive::Release::Codename="${suite}" \
		-o APT::FTPArchive::Release::Architectures="${arch}" \
		-o APT::FTPArchive::Release::Components=main \
		-o APT::FTPArchive::Release::Description="Pivuan: kernel, firmware, board support and pivuan-config for Devuan on the Raspberry Pi" \
		release . > ../Release.tmp
	mv ../Release.tmp Release
	gpg --batch --yes --local-user "${key}" --clearsign --output InRelease Release
	gpg --batch --yes --local-user "${key}" --armor --detach-sign --output Release.gpg Release
)

# 4. Public key, and a page for people who open the address in a browser.
gpg --batch --armor --export "${key}" > "${site}/pivuan-archive-keyring.asc"
gpg --batch --export "${key}" > "${site}/pivuan-archive-keyring.gpg"
fingerprint="$(gpg --batch --with-colons --fingerprint "${key}" | awk -F: '$1 == "fpr" { print $10; exit }')"
touch "${site}/.nojekyll"
{
	cat << EOF
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pivuan apt repository</title>
<style>body{font-family:sans-serif;max-width:48rem;margin:2rem auto;padding:0 1rem;line-height:1.5}pre{background:#f3f3f3;padding:.75rem;overflow-x:auto}</style>
</head><body>
<h1>Pivuan apt repository</h1>
<p>Kernel, firmware, board support and pivuan-config updates for <a href="https://github.com/rations/pivuan">Pivuan</a> (Devuan ${suite} for the Raspberry Pi, ${arch}).
Pivuan images already use it; <code>apt update &amp;&amp; apt upgrade</code> installs the updates.</p>
<p>Signing key fingerprint: <code>${fingerprint}</code></p>
<pre>/etc/apt/sources.list.d/pivuan.sources
Types: deb
URIs: https://rations.github.io/pivuan
Suites: ${suite}
Components: main
Signed-By: /usr/share/keyrings/pivuan-archive-keyring.gpg</pre>
<h2>Packages</h2>
<ul>
EOF
	awk '/^Package: /{p=$2} /^Version: /{print "<li><code>" p " " $2 "</code></li>"}' "${dists}/main/binary-${arch}/Packages" | sort -u
	cat << EOF
</ul>
</body></html>
EOF
} > "${site}/index.html"

echo "Repository updated: ${added} packages added, suite ${suite}, key ${fingerprint}"
