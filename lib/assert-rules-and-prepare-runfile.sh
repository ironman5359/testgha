#!/bin/bash

# Make sure the migration doesn't run after 24 hours, unless it hasn't been run before.
#TIMEFRAME=86400
TIMEFRAME=120

if [ $ENVIRONMENT == 'icecream' ]; then
  echo "Info: Skipping the 24-hour check for the icecream environment."
  exit 0
else
  # Fetch the branch history to ensure we can find the right commit
  git fetch --no-tags --prune --depth=50 origin +refs/heads/*:refs/remotes/origin/*

  # Find the last commit on the branch before it was merged into main
  # This assumes your pull request merge strategy involves a merge commit
  branch_commit=$(git rev-parse HEAD^2)

  commit_timestamp=$(git show -s --format=%ct "$branch_commit")
  echo "Info: $commit_timestamp is the timestamp of the branch commit."
  current_timestamp=$(date +%s)
  echo "Info: $current_timestamp is the current timestamp."
  age_in_seconds=$((current_timestamp - commit_timestamp))
  echo "Info: The branch commit is $age_in_seconds seconds old."
  if (( age_in_seconds > $TIMEFRAME )); then
    if grep -q "$branch_commit" "$GITHUB_WORKSPACE/.github_actions_cache"; then
      echo "Error: The branch commit $branch_commit is older than $TIMEFRAME seconds and has already run before. Skipping the workflow."
      exit 1
    else
      echo "Info: The branch commit $branch_commit is older than $TIMEFRAME seconds but has not run before. Proceeding with the workflow."
      echo "$branch_commit" >>"$GITHUB_WORKSPACE/.github_actions_cache"
    fi
  else
    echo "Info: The branch commit $branch_commit is within the last $TIMEFRAME seconds. Proceeding with the workflow."
    echo "$branch_commit" >>"$GITHUB_WORKSPACE/.github_actions_cache"
  fi
fi
