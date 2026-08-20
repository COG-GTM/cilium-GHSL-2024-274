#!/usr/bin/env bash
#
# Copyright Authors of Cilium
# SPDX-License-Identifier: Apache-2.0
#
# Regenerate the protobuf APIs of a checkout with the cilium-builder image.
#
# In the base image release workflow both the builder image and the API
# directory come from an untrusted pull request, while the job itself holds
# registry credentials and a GitHub App token. The container engine resolves a
# bind mount source on the host, so mounting a pull request controlled path
# (api/v1 replaced with a symlink) would hand an arbitrary host directory, such
# as the workspace .git or the runner home, to attacker supplied binaries.
#
# Therefore the API sources are validated, copied to a scratch directory
# outside of the workspace, and only that copy is ever bind mounted. Only
# regular files and directories are copied back.

set -o errexit
set -o nounset
set -o pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api_dir="${1:?usage: $0 <path to the api/v1 directory to regenerate>}"

fatal() {
  echo "$@" >&2
  exit 1
}

[ -d "${api_dir}" ] || fatal "not a directory: ${api_dir}"

workspace="${GITHUB_WORKSPACE:-$(dirname "$(dirname "${api_dir}")")}"
# realpath resolves every path component, so comparing against the expected
# location rejects api/v1, or any of its parents, being a symlink.
real_api_dir="$(realpath -e "${api_dir}")"
real_workspace="$(realpath -e "${workspace}")"
[ "${real_api_dir}" = "${real_workspace}/api/v1" ] || \
  fatal "refusing to regenerate ${api_dir}: resolves to ${real_api_dir}, expected ${real_workspace}/api/v1"

# Symlinks inside the tree would be followed when the regenerated files are
# copied back into the workspace.
symlinks="$(find "${real_api_dir}" -type l)"
[ -z "${symlinks}" ] || \
  fatal "refusing to regenerate ${api_dir}: it contains symlinks:" $'\n'"${symlinks}"

scratch="$(mktemp -d "${RUNNER_TEMP:-/tmp}/cilium-protobuf.XXXXXXXXXX")"
trap 'rm -rf "${scratch}"' EXIT
tar -C "${real_api_dir}" -cf - . | tar -C "${scratch}" -xf -

make -C "${script_dir}/../../api/v1" VOLUME="${scratch}"

# The container runs untrusted code, so anything but regular files and
# directories, symlinks in particular, is left behind in the scratch directory.
(cd "${scratch}" && find . \( -type d -o -type f \) -print0 | \
  tar --null --no-recursion --files-from - -cf -) | tar -C "${real_api_dir}" -xf -
