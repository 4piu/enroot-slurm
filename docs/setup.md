# Setup

This procedure assumes a shared home filesystem and a working Slurm cluster.
Run installation and recovery commands from the ordinary host shell. Commands
inside the development environment are shown separately.

## 1. Verify the cluster

Download the `enroot-check` bundle that matches the Enroot release and run both
its verification and execution modes as described in the
[official requirements](https://github.com/NVIDIA/enroot/blob/main/doc/requirements.md).
At minimum, confirm:

```bash
command -v enroot squashfuse
enroot version
sinfo --version
```

Repeat the relevant checks inside a small compute allocation. Login-node
success does not prove that user namespaces, FUSE, Slurm paths, or GPU hooks
are identical on compute nodes.

Enroot may be installed in a shared user prefix, but the dependencies depend on
the host distribution. If a module or user package manager does not already
provide it, the upstream Makefile supports a custom prefix:

```bash
git clone --recurse-submodules https://github.com/NVIDIA/enroot.git
cd enroot
make -j"$(nproc)"
make prefix="$HOME/.local" install
```

This installs the binary, runtime library, configuration, and standard hooks
beneath `~/.local`, matching the example config. It does not install missing
build/runtime dependencies or change kernel policy, and a user cannot perform
the optional capability setup. Consult the official
[installation guide](https://github.com/NVIDIA/enroot/blob/main/doc/installation.md)
and the cluster policy before choosing this route.

Do not load a replacement `glibc` globally into the host shell. Configure the
resulting binary, library, and system-hook paths in `devbox.conf`.

## 2. Configure the layout

Create a working configuration:

```bash
cp config/devbox.conf.example config/devbox.conf
```

The central choices are:

- `DEVBOX_PRIVATE_HOME`: persistent user files exposed as the container home;
- `DEVBOX_CONTAINER_HOME`: the stable in-container path, `/root` by default;
- `DEVBOX_ENROOT_DATA_PATH`: persistent named-rootfs storage;
- `DEVBOX_ENROOT_CACHE_PATH`: disposable image-download cache;
- `DEVBOX_HOST_TMPDIR`: node-local runtime and temporary storage;
- `DEVBOX_SNAPSHOT`: immutable image used by Slurm jobs;
- `DEVBOX_SLURM_BIN_DIR`: real scheduler commands, not the wrappers;
- `DEVBOX_SCRATCH_PATH`: optional shared data/project filesystem;
- `DEVBOX_EXTRA_MOUNTS`: site files required by Slurm or Munge;
- `DEVBOX_SRUN_MPI`: optional override for the site's default MPI plugin.

Enroot resolves named containers beneath `ENROOT_DATA_PATH`, so setting the
wrong path makes an existing rootfs appear to be missing. The launcher exports
all Enroot paths explicitly before changing `HOME`; compare them with the
[official configuration variables](https://github.com/NVIDIA/enroot/blob/main/doc/configuration.md).

### Storage placement

Treat the storage classes differently:

| Data | Property | Suggested placement |
| --- | --- | --- |
| Named rootfs | Persistent, mutable development OS | Durable storage |
| Private home | Projects, configuration, virtual environments | Durable shared storage |
| Snapshot | Reproducible compute image | Durable shared storage |
| Import cache | Re-creatable, potentially large | Cache or purgeable storage |
| Runtime/temp | Short-lived mounts and extraction | Node-local temporary storage |
| Datasets/checkpoints | Large and shared with jobs | Project or scratch storage |

Do not place the only copy of a rootfs, private home, or snapshot on storage
that is periodically purged. Symlinks do not replace mounts: explicitly mount
the filesystem containing a symlink target into the container.

## 3. Create and customize the image

Load the configured Enroot paths in the host shell:

```bash
export DEVBOX_HOST_HOME=$HOME
export DEVBOX_HOST_USER=${USER:-${HOME##*/}}
source config/devbox.conf

export ENROOT_LIBRARY_PATH=$DEVBOX_ENROOT_LIBRARY_PATH
export ENROOT_SYSCONF_PATH=$DEVBOX_ENROOT_SYSCONF_PATH
export ENROOT_CONFIG_PATH=$DEVBOX_ENROOT_CONFIG_PATH
export ENROOT_CACHE_PATH=$DEVBOX_ENROOT_CACHE_PATH
export ENROOT_DATA_PATH=$DEVBOX_ENROOT_DATA_PATH
export ENROOT_RUNTIME_PATH=$DEVBOX_HOST_TMPDIR/enroot-runtime/enroot
export ENROOT_TEMP_PATH=$DEVBOX_HOST_TMPDIR
```

Import a base image and create the named rootfs. This generic CPU example can
be replaced by a GPU image compatible with the cluster driver:

```bash
"$DEVBOX_ENROOT_BIN" import --output "$HOME/base.sqsh" docker://ubuntu:24.04
"$DEVBOX_ENROOT_BIN" create --name "$DEVBOX_NAME" "$HOME/base.sqsh"
```

The official [Enroot usage guide](https://github.com/NVIDIA/enroot/blob/main/doc/usage.md)
covers registry URI syntax and the import/create/export workflow.

Install the host launcher, then enter the mutable rootfs:

```bash
scripts/install config/devbox.conf
devbox --writable
```

Inside Enroot, namespace-root can modify the container filesystem:

```bash
apt-get update
apt-get install --no-install-recommends git build-essential
```

`--root` only remaps the calling user inside the namespace. It is not host
root. The behavior of `--root`, `--rw`, image starts, and mounts is documented
under [`enroot start`](https://github.com/NVIDIA/enroot/blob/main/doc/cmd/start.md).

Exit to the host and export the compute image:

```bash
"$DEVBOX_ENROOT_BIN" export --output "$DEVBOX_SNAPSHOT" "$DEVBOX_NAME"
```

When updating the environment, customize the named rootfs again and produce a
new snapshot. Do not modify the image while jobs are using it; export to a new
file and switch `DEVBOX_SNAPSHOT` deliberately.

## 4. Site-specific Slurm mounts

Running `srun` inside the image uses the cluster's own Slurm client and plugins.
Mount the smallest common host prefix that contains them. Depending on the
site, `DEVBOX_EXTRA_MOUNTS` may also need:

- the Slurm installation prefix;
- a node-local `slurm.conf` cache;
- the Munge socket directory;
- a host Munge or hardware-locality library required by a Slurm plugin.

Example only:

```bash
DEVBOX_SLURM_BIN_DIR=/opt/slurm/current/bin
DEVBOX_EXTRA_MOUNTS=$'/opt/slurm:/opt/slurm\n/run/munge:/run/munge\n/var/spool/slurmd/conf-cache:/var/spool/slurmd/conf-cache'
DEVBOX_CONTAINER_LD_LIBRARY_PATH=/opt/slurm/current/lib
```

Inspect dependencies rather than copying this example:

```bash
ldd "$DEVBOX_SLURM_BIN_DIR/srun"
srun --mpi=list
```

If the cluster defaults to a PMIx plugin that depends on host libraries absent
from the image and the workload does not use Slurm's MPI bootstrap, set:

```bash
DEVBOX_SRUN_MPI=none
```

Callers can still request another plugin explicitly with `srun --mpi=...`.

## 5. Install the scripts

Run from the host shell:

```bash
scripts/install config/devbox.conf
```

This installs:

```text
~/.local/bin/devbox
~/.local/bin/devbox-ssh
~/.config/enroot-slurm/devbox.conf
~/.config/enroot-slurm/devbox-batch-env
$DEVBOX_PRIVATE_HOME/.local/bin/sbatch
$DEVBOX_PRIVATE_HOME/.local/bin/srun
```

Put `$HOME/.local/bin` first in the container's `PATH`. Do not alias the real
Slurm commands; the private-home executables are the intended interception
point.

## 6. SSH routing and recovery

Use separate key pairs for rescue and development access. Keep the private keys
on the client. Add public keys to the host's `~/.ssh/authorized_keys`.

The simplest rescue entry is an ordinary key with no forced command:

```text
ssh-ed25519 AAAA... rescue-client
```

Force the development key into Enroot:

```text
command="/home/ACCOUNT/.local/bin/devbox-ssh devbox" ssh-ed25519 AAAA... development-client
```

If both keys should use the dispatcher, the rescue entry can instead use:

```text
command="/home/ACCOUNT/.local/bin/devbox-ssh host" ssh-ed25519 AAAA... rescue-client
```

Do not add `no-port-forwarding` if an editor or development tool needs SSH
forwarding. Add only restrictions compatible with the intended client.

Use distinct client aliases and identities:

```sshconfig
Host cluster-host
    HostName login.example.edu
    User ACCOUNT
    IdentitiesOnly yes
    IdentityFile ~/.ssh/id_cluster_rescue

Host cluster-devbox
    HostName login.example.edu
    User ACCOUNT
    IdentitiesOnly yes
    IdentityFile ~/.ssh/id_cluster_devbox
```

Avoid a broad `Host * IdentityFile ...` rule for these aliases: OpenSSH can
accumulate identity files and the server may accept the unintended key first.

The development route is intentionally fail-closed. If startup breaks, connect
with the rescue key, correct the configuration, or create the configured
disable file.

## 7. Validate login and compute paths

In a development SSH session:

```bash
test "$(id -u)" -eq 0
test "$HOME" = /root
test "$DEVBOX_ROOTFS_KIND" = named-rw-session
findmnt -T "$HOME"
```

Submit the CPU example:

```bash
sbatch examples/job.sh
```

Its batch and nested `srun` lines should both report UID `0`, the same home,
and `DEVBOX_ROOTFS_KIND=snapshot`.

For a GPU allocation, use the site's partition/resource syntax and test inside
the job:

```bash
printf '%s\n' "$CUDA_VISIBLE_DEVICES"
nvidia-smi
```

Choose an image CUDA userspace supported by the compute-node driver. The login
node's locally installed CUDA toolkit is not the compatibility contract.
