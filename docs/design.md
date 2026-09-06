# Execution model

## Two root filesystems, one home path

Interactive work starts a named Enroot rootfs with `--rw --root`. Package
installation changes that rootfs persistently. Scheduled work starts a
SquashFS image with `--root` but without `--rw`, so every job sees the same OS
state and cannot mutate the source image.

Both modes mount one private host directory at the same container path. The
default is:

```text
host:      $HOME/enroot_home
container: /root
```

This makes absolute paths stable across SSH sessions, batch scripts, and job
steps. Namespace-root still maps to the submitting account on the host, so
files on shared storage retain ordinary account ownership.

The account's actual home is deliberately absent as a directory tree. The
launcher itself is the one intentional file bind. This prevents containerized
tools and jobs from silently mixing host dotfiles, host binaries, or host-home
outputs with the development environment. It is filesystem separation, not a
security boundary.

## Why the Enroot paths are explicit

Enroot normally derives cache, data, configuration, and runtime paths from
XDG variables and `HOME`. The launcher changes `HOME` before startup so the
standard home/shadow hooks build `/root` from the private directory. If
`ENROOT_DATA_PATH` were left implicit, the named rootfs could be looked up
under a different home and appear missing.

The launcher therefore fixes `ENROOT_LIBRARY_PATH`, `ENROOT_SYSCONF_PATH`,
`ENROOT_CONFIG_PATH`, `ENROOT_CACHE_PATH`, `ENROOT_DATA_PATH`,
`ENROOT_RUNTIME_PATH`, and `ENROOT_TEMP_PATH` first. Their meanings are defined
by the [Enroot configuration reference](https://github.com/NVIDIA/enroot/blob/main/doc/configuration.md).

## SSH sessions

An `authorized_keys` forced command receives the client's requested command in
`SSH_ORIGINAL_COMMAND`. `devbox-ssh` either:

- executes it in a normal host login shell for the rescue route; or
- starts `devbox --session` and executes it inside Enroot.

Session mode mounts one user-private temporary directory at `/tmp`. Independent
SSH connections can then share editor IPC sockets and other session-local
state. Ordinary writable mode keeps Enroot's normal per-start temporary
filesystem.

No shell startup file automatically replaces Bash with Enroot. Key routing is
the activation point, which keeps the rescue shell independent of container
configuration.

## `sbatch` handoff

Slurm copies the submitted script into a node-local spool path and invokes its
interpreter. For Bash scripts, the wrapper exports `BASH_ENV` pointing at
`devbox-batch-env`. Bash sources that file before the script body, as specified
by the [Bash startup-file rules](https://www.gnu.org/software/bash/manual/html_node/Bash-Startup-Files).

The bootstrap identifies the Slurm spool script, clears its own trigger, and
re-executes the script through:

```text
host devbox --batch /bin/bash -s < Slurm-spooled-script
```

The original `#SBATCH` directives have already been interpreted by Slurm.
Script arguments are preserved. `sbatch --wrap` uses an explicit rewritten
payload because Slurm normally evaluates it with `/bin/sh`, which does not
source `BASH_ENV`.

Consequences:

- ordinary submission files must be Bash scripts;
- submission from stdin is rejected;
- custom Slurm environment-export modes are rejected because they can remove
  the bootstrap variables;
- invoking the real Slurm binary bypasses the wrapper.

Slurm documents script parsing, working-directory behavior, and environment
export under [`sbatch`](https://slurm.schedmd.com/sbatch.html).

## `srun` handoff

The wrapper requires an explicit delimiter:

```text
srun [Slurm options] -- command [arguments]
```

It asks the real `srun` to start this executable on each task:

```text
$HOST_HOME/.local/bin/devbox --batch command [arguments]
```

Each task therefore creates its own Enroot runtime mount of the same immutable
image. Enroot introduces no shared writable rootfs lock between these tasks.
Application-level races on datasets, caches, checkpoints, or the private home
remain ordinary parallel-filesystem concerns.

The host Slurm client may load plugins not present in the image. Mount its
installation and configuration, or select `--mpi=none` for steps that do not
need an MPI bootstrap. Multi-node MPI is site-specific; administrator-provided
Pyxis is a better integration when available.

## GPU handoff

Slurm assigns devices and sets `CUDA_VISIBLE_DEVICES`. The launcher maps that
allocation to `NVIDIA_VISIBLE_DEVICES`, enabling Enroot's standard NVIDIA hook
only for GPU jobs. CPU jobs use `NVIDIA_VISIBLE_DEVICES=void` and do not probe
the login or compute node for GPUs.

The container supplies the CUDA userspace and frameworks; the compute node
supplies the kernel driver and device files. The official
[standard-hooks reference](https://github.com/NVIDIA/enroot/blob/main/doc/standard-hooks.md)
describes Enroot's NVIDIA integration.

## Output and filesystem boundaries

The job process can access only paths explicitly mounted into Enroot. Slurm,
however, opens batch stdout and stderr before the payload enters the container.
An explicit `#SBATCH --output` path is consequently a host-side write. Use
relative paths or paths beneath the configured private/project storage.

Symlinks are resolved against the container's mount namespace. A symlink to a
dataset is usable only if its target filesystem is mounted at the expected
path.
