#!/usr/bin/env bash
#SBATCH --job-name=devbox-example
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G

set -euo pipefail

printf 'node=%s uid=%s home=%s rootfs=%s\n' \
    "$(hostname)" "$(id -u)" "$HOME" "$DEVBOX_ROOTFS_KIND"
python -c 'import platform; print(platform.platform())'

# The delimiter separates Slurm options from the command wrapped by devbox.
srun --ntasks=1 -- hostname
