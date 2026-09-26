# Workflows (Pivuan fork)

This fork builds **Pivuan**: Devuan (sysvinit, no systemd) images for the Raspberry Pi,
using the Armbian build framework. See `pre-plan.md` in the repository root.

Workflows:

- `pivuan-build.yml`: **Pivuan image build**. Run it by hand from the Actions tab
  ("Run workflow"). It builds on a GitHub-hosted arm64 runner and uploads the
  `.img.xz` and the build logs as run artifacts. Kernel packages and the rootfs
  are cached between runs. Packages are versioned `<VERSION>.<run number>`
  (e.g. `26.11.0.14`). With **publish** ticked it also updates the Pivuan apt
  repository (https://rations.github.io/pivuan, branch `gh-pages` of rations/pivuan)
  and makes a GitHub Release with the image in rations/pivuan.
- `pivuan-kernel-pin.yml`: **Pivuan kernel pin**, Mondays 03:17 UTC and by hand. The
  kernel is pinned to one commit of the Foundation's `rpi-6.18.y` branch
  (`config/sources/families/bcm2711.conf`, the `pivuan-kernel-pin` marker). When the
  branch has a new point release (6.18.53 -> 6.18.54, where the security fixes
  arrive) it moves the pin, pushes it to `pivuan` and starts a published build.
  "force" moves the pin to the branch head without a new point release.
- `pivuan-desktop-check.yml`: **Pivuan desktop package check**, by hand. Checks that a
  pivuan-config desktop (and Brave) installs on Devuan without systemd, for arm64.

Publishing needs two repository secrets (Settings > Secrets and variables > Actions):

- `PIVUAN_APT_SIGNING_KEY`: armored OpenPGP private key without a passphrase that
  signs the apt repository. Every build puts its public half into the image, with
  `/etc/apt/sources.list.d/pivuan.sources`. Without it images get no Pivuan apt source.
  Keep a copy offline: installed systems only trust this key.
- `PIVUAN_REPO_TOKEN`: fine-grained personal access token, repository rations/pivuan
  only, permission Contents: read and write.

rations/pivuan serves the repository with GitHub Pages (Settings > Pages: Deploy from a
branch, `gh-pages`, `/ (root)`; set once).

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
