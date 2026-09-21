#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run Terraform in a container, so nothing has to be installed on your machine.
# Same pattern as scripts/dbt.sh.
#
#   ./scripts/tf.sh init
#   ./scripts/tf.sh validate
#   ./scripts/tf.sh plan
#   ./scripts/tf.sh apply          <-- the only one that costs money
#   ./scripts/tf.sh destroy
#
# ~/.aws is mounted read-only so the container uses your existing AWS profile.
# No credentials are copied or written anywhere.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

TF_VERSION="${TF_VERSION:-1.9}"

args=(
  --rm -i
  -v "$PWD/infra:/infra"
  -w /infra
  -e AWS_PROFILE="${AWS_PROFILE:-default}"
  -e AWS_REGION="${AWS_REGION:-us-east-1}"
)

# Mount the AWS config if it exists. `init` and `validate` do not need it;
# plan and apply do.
if [[ -d "$HOME/.aws" ]]; then
  args+=(-v "$HOME/.aws:/root/.aws:ro")
fi

# A TTY only when we have one, so this still works non-interactively in CI.
[[ -t 0 ]] && args+=(-t)

exec docker run "${args[@]}" "hashicorp/terraform:${TF_VERSION}" "$@"
