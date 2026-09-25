# Workflows (Pivuan fork)

This fork builds **Pivuan**: Devuan (sysvinit, no systemd) images for the Raspberry Pi,
using the Armbian build framework. See `pre-plan.md` in the repository root.

Only one workflow is kept:

- `pivuan-build.yml`: **Pivuan image build**. Run it by hand from the Actions tab
  ("Run workflow"). It builds on a GitHub-hosted arm64 runner and uploads the
  `.img.xz` and the build logs as run artifacts. Kernel packages and the rootfs
  are cached between runs.

Armbian's own workflows (issue/PR automation, label and board syncing, mirroring,
security scans, scheduled maintenance) were removed. They target armbian/build's
infrastructure and would only fail or create noise here. If you sync from upstream
and Git reports conflicts on those files, resolve them by keeping the deletion:

    git rm .github/workflows/<file>.yml

Optional repository variable (Settings > Secrets and variables > Actions > Variables):

- `DEVUAN_KEY_FINGERPRINTS`: fingerprint(s) of the Devuan archive signing key(s),
  as shown by `gpg --show-keys /usr/share/keyrings/devuan-archive-keyring.gpg` on a
  Devuan machine you trust. When set, the build only trusts those keys.
