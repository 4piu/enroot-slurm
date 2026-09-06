# Troubleshooting

Start with three questions:

1. Is the failing process on the login host, inside the writable rootfs, or in
   the immutable compute image?
2. Which physical path backs its home and working directory?
3. Is the failure from Enroot, Slurm, a host plugin, or the application?

Collect this minimal state without dumping credentials or the full environment:

```bash
id
printf 'home=%s active=%s kind=%s job=%s\n' \
    "$HOME" "${DEVBOX_ACTIVE:-0}" \
    "${DEVBOX_ROOTFS_KIND:-unset}" "${SLURM_JOB_ID:-none}"
findmnt -T "$HOME"
printf 'cuda=%s\n' "${CUDA_VISIBLE_DEVICES:-unset}"
```

## Named container is missing

Typical symptom:

```text
No such file or directory: .../enroot/devbox
```

Check `ENROOT_DATA_PATH` in the host launcher and compare it with the path used
when `enroot create` was run:

```bash
printf '%s\n' "$ENROOT_DATA_PATH"
find "$ENROOT_DATA_PATH" -maxdepth 1 -mindepth 1 -type d
```

Do not let the launcher derive this path after it changes `HOME` to the private
container home.

## Namespace or mount operation is denied

Run the matching `enroot-check` release bundle. Failures involving user or
mount namespaces, AppArmor restrictions, or kernel configuration generally
require administrator action. The complete list is in the
[Enroot requirements](https://github.com/NVIDIA/enroot/blob/main/doc/requirements.md).

## SquashFS image will not start

Confirm that the image is readable on the compute node and that `squashfuse`
is on the host-side launcher's `PATH`:

```bash
test -r /path/to/devbox.sqsh
command -v squashfuse
```

Starting an image directly uses a temporary overlay and requires SquashFS/FUSE
support documented by [`enroot start`](https://github.com/NVIDIA/enroot/blob/main/doc/cmd/start.md#starting-container-images).

Keep runtime and overlay working directories on node-local storage when the
shared filesystem does not support the required mount/overlay semantics.

## `srun` cannot find `slurm.conf`

The host Slurm client may use a node-local configuration cache. Determine the
path from `SLURM_CONF`, Slurm diagnostics, or the site installation, then add a
same-path entry to `DEVBOX_EXTRA_MOUNTS`.

Do not copy a login-node configuration blindly; compute-node caches and DNSless
configurations can differ.

## Slurm plugin reports a missing shared library

Inspect the named plugin and its dependencies on a compute node:

```bash
ldd /path/to/slurm/plugin.so
srun --mpi=list
```

Mount the compatible host library at a controlled path and add that path to
`DEVBOX_CONTAINER_LD_LIBRARY_PATH`. Do not replace the image's global `glibc`
with the host's copy.

If the failure is the default PMIx plugin and the step does not use Slurm for
MPI startup, configure `DEVBOX_SRUN_MPI=none`. For actual MPI workloads, align
the image's MPI/PMI libraries with the cluster and test across multiple nodes.

## `sbatch` rejects a script

The wrapper accepts:

- a readable submission file with a Bash shebang; or
- `sbatch --wrap='...'`.

It rejects stdin submission, non-Bash shebangs, and custom `--export`,
`--export-file`, or `--get-user-env` modes. These restrictions make the
user-level handoff fail closed. Put Python or another application inside a
small Bash driver script rather than using that interpreter as the Slurm
submission script.

## The job wrote outside the expected container path

Check `#SBATCH --output` and `#SBATCH --error`. Slurm opens these files on the
host, not from the containerized payload. Prefer relative paths after the
wrapper's translated `--chdir`, or explicitly target mounted private/project
storage.

Also inspect symlink targets:

```bash
readlink -f path/to/link
findmnt -T "$(readlink -f path/to/link)"
```

## GPU is absent inside the job

First verify that Slurm actually assigned a device:

```bash
printf '%s\n' "$CUDA_VISIBLE_DEVICES"
```

Then check that the host has `nvidia-container-cli`, that the Enroot NVIDIA hook
is present under `DEVBOX_ENROOT_SYSCONF_PATH`, and that the image starts with
`NVIDIA_VISIBLE_DEVICES` set to the Slurm allocation. Enroot's GPU prerequisites
and hook controls are covered by the
[requirements](https://github.com/NVIDIA/enroot/blob/main/doc/requirements.md#gpu-support-optional)
and [standard-hooks documentation](https://github.com/NVIDIA/enroot/blob/main/doc/standard-hooks.md).

Do not infer compute compatibility from the login node's CUDA toolkit. Check
the compute-node driver and select an image with a compatible CUDA userspace.

## Development SSH fails

Use the rescue key. Then check, in order:

```bash
bash -n ~/.local/bin/devbox ~/.local/bin/devbox-ssh
test -r ~/.config/enroot-slurm/devbox.conf
test -x ~/.local/bin/enroot
export DEVBOX_HOST_HOME=$HOME
export DEVBOX_HOST_USER=${USER:-${HOME##*/}}
source ~/.config/enroot-slurm/devbox.conf
test -d "$DEVBOX_ENROOT_DATA_PATH/$DEVBOX_NAME"
```

Run `devbox --session` directly from the rescue shell to see the real error.
Do not add a host fallback to the development forced command: a silent fallback
can start development tools against the wrong home and operating system.

If both client aliases select the same server route, inspect the effective SSH
configuration:

```bash
ssh -G cluster-devbox | grep '^identityfile'
```

Ensure the alias offers only its intended key.

## Concurrent jobs and rootfs locks

Never point batch mode at the shared writable named rootfs. Enroot serializes
parts of rootfs setup, and concurrent mutation also makes results
non-reproducible. Export a SquashFS image and let every job mount that immutable
file independently. Coordinate application writes to caches, checkpoints, and
datasets exactly as for any other parallel Slurm workload.
