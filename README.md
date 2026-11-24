# snreg-deploy

Everything for installing and running SNReg (spec §8). The package path is the main one;
Compose and Helm are optional.

| Path | What | Test |
|---|---|---|
| `systemd/` | `snreg-server.service` (shipped in the server's `.deb`/`.rpm`) | `systemd/test.sh <server .deb>` |
| `compose/` | server + `postgres:16`, a one-shot `init` | `compose/test.sh [image]` |
| `helm/snreg/` | hosted tier, external PostgreSQL | `helm/test.sh <image>` (kind) |
| `terraform/` | `snreg-hetzner`, `snreg-aws` | `terraform validate` in CI |
| `ansible/` | roles `snreg_server`, `snreg_agent` | `ansible/test.sh <server .deb> <agent .deb>` |
| `iso/` | `snreg-iso`, the zero-touch installer ISO builder | `iso/test.sh <distro>` (DM-1, QEMU) |

`.github/workflows/ci.yml` runs the static checks on every PR. `e2e.yml` runs everything above
nightly once `SNREG_READ_TOKEN` and the `SNREG_E2E=true` variable are set (ADR 0010).
