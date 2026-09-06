# Enroot development environments on Slurm without root

This repository is a user-space pattern for running a persistent Linux
development environment on a Slurm HPC cluster when the host operating system
is old, software installation is restricted, and the user cannot install a
Slurm plugin.

It uses [Enroot](https://github.com/NVIDIA/enroot), an unprivileged container
runtime designed for HPC. Enroot describes itself as an enhanced unprivileged
`chroot`: it provides filesystem separation and root remapping without trying
to be a strong security boundary.

The goal is one coherent environment across interactive development and
scheduled computation:

```text
development SSH key ──> writable named Enroot rootfs ──> /root
                                  │
                                  ├── sbatch job.sh
                                  └── srun ... -- command
                                           │
                                           v
compute node ─────────> immutable SquashFS image ──────> /root

rescue SSH key ───────> ordinary host shell
```

The same private directory is mounted as `/root` in both modes. Projects,
virtual environments, editor state, and user configuration therefore retain
the same absolute paths. A project or scratch filesystem can be mounted at the
same path on every node. The account's actual host home is not mounted wholesale
into the container; only the host launcher is bound as a narrow entry point for
nested scheduling.

## Why this pattern?

- Development needs a writable OS where package managers work.
- Compute jobs need a stable image that many jobs can start concurrently.
- A Slurm allocation alone does not reproduce the interactive environment.
- Globally replacing the host C library is unsafe; a container supplies its
  own userspace while retaining the cluster kernel, scheduler, filesystems,
  devices, and GPU driver.
- A separate rescue route prevents a broken image or launcher from blocking
  account access.

If the administrators already provide
[Pyxis](https://github.com/NVIDIA/pyxis), prefer it: Pyxis is the supported
Slurm SPANK integration for Enroot. The wrappers here solve the narrower case
where Enroot can be installed by a user but Pyxis cannot be installed
cluster-wide.

## What is included

| Path | Purpose |
| --- | --- |
| `scripts/devbox` | Starts writable sessions or the immutable batch image |
| `scripts/devbox-ssh` | Routes SSH keys to the host or development environment |
| `scripts/sbatch` | Forces Bash batch scripts and `--wrap` payloads into Enroot |
| `scripts/srun` | Forces each Slurm job step into Enroot |
| `scripts/devbox-batch-env` | Compute-node bootstrap used by the `sbatch` wrapper |
| `scripts/install` | Installs the scripts into the host and private home |
| `config/devbox.conf.example` | Site-specific paths and policy |
| `examples/job.sh` | Minimal batch and nested-step test |

## Prerequisites

The cluster kernel must allow the namespaces Enroot needs. Optional GPU support
also requires the host NVIDIA driver and `libnvidia-container` integration.
Run the release-matched `enroot-check` bundle before building the workflow; see
the official [Enroot requirements](https://github.com/NVIDIA/enroot/blob/main/doc/requirements.md).

The login and compute nodes need:

- Enroot and its helper programs available from the same shared user prefix;
- `squashfuse` for starting SquashFS images;
- the same shared private-home and project/scratch paths;
- a working Slurm client on compute nodes;
- for GPUs, the Enroot NVIDIA hook and host container-toolkit support.

Some prerequisites are controlled by administrators. A user-space installation
cannot compensate for disabled user namespaces or missing GPU host support.

## Quick start

1. Install Enroot and its runtime dependencies into a shared user prefix.
2. Copy and edit the configuration:

   ```bash
   cp config/devbox.conf.example config/devbox.conf
   $EDITOR config/devbox.conf
   ```

3. Import an image and create the named rootfs. The exact image is a project
   policy; it is deliberately not fixed by this repository.
4. From the host shell, install the scripts:

   ```bash
   scripts/install config/devbox.conf
   ```

5. Enter with `devbox --writable`, customize the rootfs, exit, and export it to
   the path configured by `DEVBOX_SNAPSHOT`.
6. Add the dedicated SSH key route described in
   [docs/setup.md](docs/setup.md#ssh-routing-and-recovery).
7. Connect through the development key and verify:

   ```bash
   id -u                         # 0, remapped only inside Enroot
   printf '%s\n' "$HOME"         # /root by default
   printf '%s\n' "$DEVBOX_ROOTFS_KIND"
   findmnt -T "$HOME"
   ```

8. Submit the example:

   ```bash
   sbatch examples/job.sh
   ```

Full installation and site-adaptation instructions are in
[docs/setup.md](docs/setup.md).

## Daily use

Enter a normal writable shell:

```bash
devbox --writable
```

The dedicated SSH route uses session mode, which shares a private `/tmp`
between independent SSH connections so development tools can coordinate over
Unix sockets:

```bash
devbox --session
```

Submit a Bash batch script or a short payload:

```bash
sbatch train.sh
sbatch --wrap='python train.py --config experiment.toml'
```

Run a job step. The `--` delimiter is mandatory; everything before it belongs
to Slurm and everything after it is the command started inside Enroot:

```bash
srun --ntasks=1 -- python evaluate.py
```

Both wrappers select the immutable image. They do not run compute payloads in
the writable development rootfs.

## Important boundaries

- Root inside Enroot is user-namespace root, not host root. It enables package
  management inside the writable rootfs but grants no administrative access to
  the cluster.
- Enroot is not a hostile-code sandbox. Mounted storage and credentials remain
  accessible to processes in the container.
- This is workflow enforcement, not cluster policy. Calling the real `sbatch`
  or `srun` binary directly bypasses user-installed wrappers.
- Ordinary `sbatch` files must use Bash because the handoff relies on
  [`BASH_ENV`](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files).
  `--wrap` is handled explicitly.
- The wrappers reject Slurm environment-export options because they can remove
  the bootstrap variables. See Slurm's
  [`sbatch --export`](https://slurm.schedmd.com/sbatch.html#OPT_export)
  semantics.
- Slurm opens stdout and stderr on the host. Relative output paths are rooted
  at the translated submission directory, but an explicit host-home output
  path can still write there without mounting that home in the container.
- A shared writable rootfs is suitable for development, not concurrent jobs.
  Parallel jobs use the immutable image and share only explicitly mounted data.

See [docs/design.md](docs/design.md) for the complete execution model and
[docs/troubleshooting.md](docs/troubleshooting.md) for site-specific failures.

## Upstream documentation

- [Enroot requirements](https://github.com/NVIDIA/enroot/blob/main/doc/requirements.md)
- [Enroot installation](https://github.com/NVIDIA/enroot/blob/main/doc/installation.md)
- [Enroot configuration](https://github.com/NVIDIA/enroot/blob/main/doc/configuration.md)
- [Enroot usage](https://github.com/NVIDIA/enroot/blob/main/doc/usage.md)
- [`enroot start`](https://github.com/NVIDIA/enroot/blob/main/doc/cmd/start.md)
- [Enroot standard hooks](https://github.com/NVIDIA/enroot/blob/main/doc/standard-hooks.md)
- [Slurm `sbatch`](https://slurm.schedmd.com/sbatch.html)
- [Slurm `srun`](https://slurm.schedmd.com/srun.html)
- [Pyxis](https://github.com/NVIDIA/pyxis)
