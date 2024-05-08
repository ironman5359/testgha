#!/bin/bash
set -x
# set -e and set -o pipefail are set by github actions and therefore not needed here

# GITHUB_ENV, GITHUB_OUTPUT and TIMEFRAME are environment variables set by GitHub Actions

configure_aws_cli() {
  # this function determines if the aws cli is installed and if not installs it
  # secondly it configures the aws cli with the provided credentials
  if ! type -f aws; then
    sudo apt-get update && sudo apt-get install -y awscli >/dev/null 2>&1
  fi
  # Configure AWS CLI
  aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
  aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
  aws configure set default.region "$AWS_DEFAULT_REGION"
}

download_file() {
  local filepath=$1
  aws s3 cp s3:/"$filepath" .
}

update_file() {
  local sha_to_add=$1
  local filepath=$2
  echo "Updating the restricted.txt file... adding ${sha_to_add}."
  echo "$sha_to_add" >>restricted.txt
  aws s3 cp restricted.txt s3:/"$filepath"
}


main() {
  # initialization local variables
  local SHA_TO_ADD
  local commit_timestamp
  local current_timestamp
  local age_in_seconds
  local parent_count

  # Download the restricted.txt file from S3
  configure_aws_cli
  download_file "/${ENVIRONMENT}-migrations/24Hour/restricted.txt"

  # Fetch the branch history to ensure we can find the right commit
  git fetch --no-tags --prune --depth=50 origin +refs/heads/*:refs/remotes/origin/* || {
    echo "Get fetch failed"
    exit 128
  }

  # Find the last commit on the branch before it was merged into main
  # Also determine if we're dealing with a direct merge into main
  parent_count=$(git rev-list --parents -n 1 HEAD | wc -w)
  if [ "$parent_count" -le 2 ]; then
    SHA_TO_ADD="DIRECT_TO_MAIN"
  else
    SHA_TO_ADD=$(git rev-parse HEAD^2 2>/dev/null)
    echo "SHA_TO_ADD=$SHA_TO_ADD" >>$GITHUB_ENV
    commit_timestamp=$(git show -s --format=%ct "$SHA_TO_ADD")
    current_timestamp=$(date +%s)
    age_in_seconds=$((current_timestamp - commit_timestamp))
  fi

  # If the branch was merged directly into main, skip the workflow
  if [[ "$SHA_TO_ADD" == "DIRECT_TO_MAIN" ]]; then
    echo "✅ The branch was merged directly into main branch. Skipping the workflow."
    echo "skip=true" >>"$GITHUB_OUTPUT"
  else
    if grep "${SHA_TO_ADD}" restricted.txt >/dev/null 2>&1; then
      if ((age_in_seconds > $TIMEFRAME)); then
        echo "❌ Error: The branch commit $SHA_TO_ADD has already been run before and it's over the $TIMEFRAME limit."
        echo "skip=true" >>"$GITHUB_OUTPUT"
      else
        echo "ℹ️ Info: The branch commit $SHA_TO_ADD is within the last $TIMEFRAME seconds. Proceeding with the workflow."
        echo "skip=false" >>"$GITHUB_OUTPUT"
      fi
    else
      echo "ℹ️ Info: The branch commit $SHA_TO_ADD has never been run before. Updating sha file and proceeding with the workflow."
      update_file "$SHA_TO_ADD" "/${ENVIRONMENT}-migrations/24Hour/restricted.txt"
      echo "skip=false" >>"$GITHUB_OUTPUT"
    fi
  fi
}

# Call the main function
main