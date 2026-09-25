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

Devuan archive keys: `pivuan-build.yml` pins the fingerprints of the keys that sign
excalibur (`DEVUAN_KEY_FINGERPRINTS` in the job's `env`), and the build only trusts those.
To override them without editing the workflow, set the optional repository variable
`DEVUAN_KEY_FINGERPRINTS` (Settings > Secrets and variables > Actions > Variables) to the
fingerprint(s) shown by `gpg --show-keys /usr/share/keyrings/devuan-archive-keyring.gpg` on a
Devuan machine you trust.
