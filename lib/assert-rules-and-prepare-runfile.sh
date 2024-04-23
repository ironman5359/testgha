#!/bin/bash

# Make sure the migration doesn't run after 24 hours, unless it hasn't been run before.
#TIMEFRAME=86400
TIMEFRAME=120

if [ $ENVIRONMENT == 'icecream' ]; then
  echo "Info: Skipping the 24-hour check for the icecream environment."
  exit 0
else

  commit_timestamp=$(git show -s --format=%ct "$GITHUB_SHA")
  echo "Info: $commit_timestamp is the timestamp of the triggering commit."
  current_timestamp=$(date +%s)
  echo "Info: $current_timestamp is the current timestamp."
  age_in_seconds=$((current_timestamp - commit_timestamp))
  echo "Info: The triggering commit is $age_in_seconds seconds old."
  if (( age_in_seconds > $TIMEFRAME )); then
    if grep -q "$GITHUB_SHA" "$GITHUB_WORKSPACE/.github_actions_cache"; then
      echo "Error: The triggering commit $GITHUB_SHA is older than $TIMEFRAME seconds and has already run before. Skipping the workflow."
      exit 1
    else
      echo "Info: The triggering commit $GITHUB_SHA is older than $TIMEFRAME seconds but has not run before. Proceeding with the workflow."
      echo "$GITHUB_SHA" >>"$GITHUB_WORKSPACE/.github_actions_cache"
    fi
  else
    echo "Info: The triggering commit $GITHUB_SHA is within the last $TIMEFRAME seconds. Proceeding with the workflow."
    echo "$GITHUB_SHA" >>"$GITHUB_WORKSPACE/.github_actions_cache"
  fi
fi
