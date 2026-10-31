#!/bin/bash
# Runs terraform with the CloudShell setup done for you. Use it instead of "terraform":
#
#   ./tf.sh apply
#   ./tf.sh output -raw api_key
#   ./tf.sh destroy
#
# It finds your state bucket by itself (research-relay-tfstate-<ACCOUNT_ID>, made by bootstrap.sh),
# so you never type -backend-config or TF_DATA_DIR again.
set -e
cd "$(dirname "$0")"

# terraform's AWS plugin is ~800 MB, CloudShell's home folder is only 1 GB, so keep it in /tmp
export TF_DATA_DIR=/tmp/tf

# /tmp is wiped when CloudShell closes, so init again only when needed (state itself is safe in S3)
if [ ! -d "$TF_DATA_DIR/providers" ]; then
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
  terraform init -input=false -backend-config="bucket=research-relay-tfstate-$ACCOUNT_ID"
fi

terraform "$@"
