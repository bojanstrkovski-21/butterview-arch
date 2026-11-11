#!/bin/bash
#
##################################################################################################################
# Written to be used on 64 bits computers
# Author  :   Erik Dubois
# Website   :   http://www.erikdubois.be
# Adapted for GitHub by bojanstrkovski-21
##################################################################################################################
##################################################################################################################
#
#   DO NOT JUST RUN THIS. EXAMINE AND JUDGE. RUN AT YOUR OWN RISK.
#
##################################################################################################################
# Problem solving commands
# Read before using it.
# https://www.atlassian.com/git/tutorials/undoing-changes/git-reset
# git reset --hard origin/main
# ONLY if you are very sure and no coworkers are on your github.
# Command that have helped in the past
# Force git to overwrite local files on pull - no merge
# git fetch --all
# git push --set-upstream origin main
# git reset --hard origin/main

set -e

project=butterview-arch

echo "-----------------------------------------------------------------------------"
echo "this is project https://github.com/bojanstrkovski-21/$project"
echo "-----------------------------------------------------------------------------"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not inside a git repository. Aborting."; exit 1; }

origin_url="$(git remote get-url origin 2>/dev/null)" || { echo "No 'origin' remote configured. Aborting."; exit 1; }
case "$origin_url" in
    https://github.com/bojanstrkovski-21/butterview-arch.git) ;;
    *)
        echo "'origin' does not point at https://github.com/bojanstrkovski-21/butterview-arch.git ($origin_url). Aborting."
        exit 1
        ;;
esac

git add --all .

if ! git diff --cached --quiet; then
    echo "-----------------------------------------------------------------------------"
    echo "About to commit:"
    git status --short
    echo "-----------------------------------------------------------------------------"

    commit_message=""
    while [ -z "$commit_message" ]; do
        echo "Enter commit message:"
        read -r commit_message
    done

    git commit -m "$commit_message"
else
    echo "Nothing staged, skipping commit."
fi

current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo "No commit yet. Aborting."; exit 1; }
if [ "$current_branch" = "HEAD" ]; then
    echo "Detached HEAD state, not on a branch. Aborting."
    exit 1
fi

if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    # Upstream already tracked: safe to pull now that local work is committed.
    git pull --rebase
    git push
else
    # First push for this branch: nothing to pull from yet.
    git push -u origin "$current_branch"
fi

echo "################################################################"
echo "###################    T H E   E N D      ######################"
echo "################################################################"
