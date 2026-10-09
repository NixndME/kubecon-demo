#!/usr/bin/env bash
# Run terraform for one folder, with state and variables kept outside the repo.
# Usage: scripts/tf.sh <dns|network|test-vm|...> <init|plan|apply|destroy|output> [args]
set -euo pipefail

root="${1:?folder name}"; shift
cmd="${1:?terraform command}"; shift
here="$(cd "$(dirname "$0")/.." && pwd)"
local_dir="${KUBECON_LOCAL:-$HOME/.local/share/kubecon-demo}"

export TF_DATA_DIR="$local_dir/tf-data/$root"
cd "$here/terraform/$root"

vars=()
[ -f "$local_dir/common.tfvars" ] && vars+=(-var-file="$local_dir/common.tfvars")
[ -f "$local_dir/$root.tfvars" ] && vars+=(-var-file="$local_dir/$root.tfvars")

case "$cmd" in
  init)
    terraform init -input=false -backend-config="path=$local_dir/state/$root.tfstate" "$@" ;;
  plan)
    terraform plan -input=false "${vars[@]}" -out="$local_dir/state/$root.plan" "$@" ;;
  apply)
    terraform apply -input=false "$local_dir/state/$root.plan" "$@" ;;
  destroy)
    terraform destroy -input=false "${vars[@]}" "$@" ;;
  *)
    terraform "$cmd" "$@" ;;
esac
