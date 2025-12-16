#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

# Icebow Branch Rebase Automation Script
#
# This script automates rebasing the icebow branch onto upstream DataFusion tags.
# It fetches tags from upstream, rebases all icebow commits onto a specified tag,
# and creates a new icebow-VERSION tag.
#
# Usage:
#   ./dev/rebase-icebow.sh <version>
#
# Examples:
#   ./dev/rebase-icebow.sh 52.0.0
#   ./dev/rebase-icebow.sh 52.0.0-rc1
#
# Features:
#   - Creates backup branch before rebasing
#   - Handles merge conflicts gracefully
#   - Provides clear instructions for conflict resolution
#   - Creates icebow-VERSION tag after successful rebase
#   - Manual push (no auto-push for safety)

set -euo pipefail

# ==================== Configuration ====================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../" && pwd)"
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"
BRANCH_NAME="icebow"
BACKUP_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_BRANCH="icebow-backup-${BACKUP_TIMESTAMP}"

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==================== Helper Functions ====================

usage() {
    cat << EOF
Usage: $0 <version>

Automate rebasing the icebow branch onto upstream DataFusion tags.

Arguments:
  version       The upstream tag version to rebase onto (e.g., 52.0.0, 52.0.0-rc1)

Examples:
  $0 52.0.0         Rebase icebow branch onto DataFusion 52.0.0
  $0 52.0.0-rc1     Rebase icebow branch onto DataFusion 52.0.0-rc1

Options:
  -h, --help        Show this help message

The script will:
  1. Fetch all tags from upstream
  2. Validate the specified tag exists
  3. Create a backup branch (icebow-backup-TIMESTAMP)
  4. Rebase all icebow commits onto the target tag
  5. Create a new tag: icebow-<version>
  6. Display next steps for testing and pushing

Safety features:
  - Always creates a backup branch before rebasing
  - Stops and prompts on merge conflicts
  - Never auto-pushes (manual review required)
EOF
}

log_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

log_success() {
    echo -e "${GREEN}✓${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

log_error() {
    echo -e "${RED}✗${NC} $1" >&2
}

validate_prerequisites() {
    log_info "Validating prerequisites..."

    # Check if git command exists
    if ! command -v git &> /dev/null; then
        log_error "git command not found. Please install git."
        exit 1
    fi

    # Change to repo root
    cd "${REPO_ROOT}"

    # Verify we're inside a git repository
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log_error "Not inside a git repository."
        exit 1
    fi

    # Check if working directory is clean
    if ! git diff-index --quiet HEAD -- 2>/dev/null; then
        log_error "Working directory has uncommitted changes."
        echo "Please commit or stash your changes before rebasing."
        git status --short
        exit 1
    fi

    # Check if we're in detached HEAD state
    if ! git symbolic-ref -q HEAD >/dev/null; then
        log_error "Currently in detached HEAD state."
        echo "Please checkout a branch first."
        exit 1
    fi

    # Check if upstream remote exists
    if ! git remote | grep -q "^${UPSTREAM_REMOTE}$"; then
        log_error "Remote '${UPSTREAM_REMOTE}' not found."
        echo "Please add upstream remote:"
        echo "  git remote add ${UPSTREAM_REMOTE} https://github.com/apache/datafusion.git"
        exit 1
    fi

    # Check current branch and offer to switch if needed
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" != "$BRANCH_NAME" ]; then
        log_warning "Not on ${BRANCH_NAME} branch (currently on ${CURRENT_BRANCH})."
        read -p "Switch to ${BRANCH_NAME} branch? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git checkout "$BRANCH_NAME"
            log_success "Switched to ${BRANCH_NAME} branch"
        else
            log_error "Aborted. Please checkout ${BRANCH_NAME} branch manually."
            exit 1
        fi
    fi

    log_success "Prerequisites validated"
}

fetch_and_validate_tag() {
    local target_tag=$1

    log_info "Fetching tags from ${UPSTREAM_REMOTE}..."
    if ! git fetch "${UPSTREAM_REMOTE}" --tags --force; then
        log_error "Failed to fetch tags from ${UPSTREAM_REMOTE}"
        echo "Please check your network connection and remote configuration."
        exit 1
    fi
    log_success "Tags fetched from ${UPSTREAM_REMOTE}"

    # Validate tag exists
    if ! git rev-parse "${target_tag}" >/dev/null 2>&1; then
        log_error "Tag '${target_tag}' not found in upstream repository."
        echo ""
        echo "Available recent tags:"
        git tag --sort=-version:refname | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | head -10
        exit 1
    fi

    # Display tag info
    log_success "Tag '${target_tag}' found"
    echo ""
    git show --quiet "${target_tag}" | head -10
    echo ""
}

create_backup_branch() {
    log_info "Creating backup branch..."

    if ! git branch "${BACKUP_BRANCH}"; then
        log_error "Failed to create backup branch."
        exit 1
    fi

    log_success "Backup branch created: ${BACKUP_BRANCH}"
    echo "  (You can restore with: git reset --hard ${BACKUP_BRANCH})"
    echo ""
}

show_commits_to_rebase() {
    local target_tag=$1

    log_info "Analyzing commits to rebase..."

    # Find merge base with upstream/main
    local merge_base
    merge_base=$(git merge-base "${BRANCH_NAME}" "${UPSTREAM_REMOTE}/main" 2>/dev/null || echo "")

    if [ -z "$merge_base" ]; then
        log_warning "Could not find merge base with ${UPSTREAM_REMOTE}/main"
        log_info "Will rebase all commits on ${BRANCH_NAME} branch"
        merge_base=$(git rev-list --max-parents=0 HEAD)
    fi

    # Count commits to rebase
    local commit_count
    commit_count=$(git rev-list --count "${merge_base}..${BRANCH_NAME}")

    echo ""
    echo "=========================================="
    echo "Rebase Summary"
    echo "=========================================="
    echo "Target tag:      ${target_tag}"
    echo "Current branch:  ${BRANCH_NAME}"
    echo "Commits to rebase: ${commit_count}"
    echo "=========================================="
    echo ""

    if [ "$commit_count" -gt 0 ]; then
        echo "Commits that will be rebased:"
        git log --oneline --no-decorate "${merge_base}..${BRANCH_NAME}"
        echo ""
    fi

    # Ask for confirmation
    read -p "Proceed with rebase? [y/N]: " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_warning "Rebase cancelled by user."
        exit 0
    fi

    # Return merge_base for use in rebase
    echo "$merge_base"
}

execute_rebase() {
    local target_tag=$1
    local merge_base=$2

    log_info "Executing rebase onto ${target_tag}..."

    # Execute rebase using --onto
    # This rebases commits from merge_base..icebow onto target_tag
    if git rebase --onto "${target_tag}" "${merge_base}" "${BRANCH_NAME}"; then
        log_success "Rebase completed successfully!"
        return 0
    else
        # Rebase failed (likely due to conflicts)
        return 1
    fi
}

handle_rebase_conflict() {
    local target_tag=$1

    echo ""
    log_warning "MERGE CONFLICTS DETECTED"
    echo ""
    echo "The rebase has encountered conflicts in the following files:"
    git diff --name-only --diff-filter=U 2>/dev/null || echo "  (run 'git status' to see conflicted files)"
    echo ""
    echo "=========================================="
    echo "TO RESOLVE CONFLICTS:"
    echo "=========================================="
    echo "1. Fix conflicts in the files listed above"
    echo "2. Mark as resolved:  git add <file>"
    echo "3. Continue rebase:   git rebase --continue"
    echo "4. After successful rebase, create tag:"
    echo "   git tag -a icebow-${target_tag} -m \"Icebow custom build based on DataFusion ${target_tag}\""
    echo ""
    echo "=========================================="
    echo "TO ABORT AND RESTORE:"
    echo "=========================================="
    echo "  git rebase --abort"
    echo "  git reset --hard ${BACKUP_BRANCH}"
    echo ""
    echo "For help: https://git-scm.com/docs/git-rebase"
    echo ""

    exit 1
}

create_icebow_tag() {
    local target_tag=$1
    local icebow_tag="icebow-${target_tag}"

    log_info "Creating tag ${icebow_tag}..."

    # Check if tag already exists
    if git rev-parse "${icebow_tag}" >/dev/null 2>&1; then
        log_warning "Tag '${icebow_tag}' already exists."
        read -p "Overwrite existing tag? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git tag -d "${icebow_tag}"
            log_success "Deleted existing tag"
        else
            log_warning "Skipping tag creation."
            return 0
        fi
    fi

    # Create annotated tag
    if git tag -a "${icebow_tag}" -m "Icebow custom build based on DataFusion ${target_tag}"; then
        log_success "Tag created: ${icebow_tag}"
    else
        log_error "Failed to create tag."
        exit 1
    fi
}

display_summary() {
    local target_tag=$1
    local icebow_tag="icebow-${target_tag}"

    echo ""
    echo "=========================================="
    echo "Rebase Complete!"
    echo "=========================================="
    log_success "Base tag: ${target_tag}"
    log_success "New tag: ${icebow_tag}"
    log_success "Backup: ${BACKUP_BRANCH}"
    echo "=========================================="
    echo ""
    echo "NEXT STEPS:"
    echo ""
    echo "1. Review the changes:"
    echo "   git log --oneline ${target_tag}..${BRANCH_NAME}"
    echo "   git diff ${target_tag}..${BRANCH_NAME}"
    echo ""
    echo "2. Test your build:"
    echo "   cargo test"
    echo ""
    echo "3. When ready to push (MANUAL STEP):"
    echo "   git push ${ORIGIN_REMOTE} ${BRANCH_NAME} --force-with-lease"
    echo "   git push ${ORIGIN_REMOTE} ${icebow_tag}"
    echo ""
    echo "4. If something went wrong, restore from backup:"
    echo "   git reset --hard ${BACKUP_BRANCH}"
    echo ""
}

# ==================== Main Function ====================

main() {
    # Parse arguments
    if [ "$#" -eq 0 ]; then
        log_error "Missing required argument: version"
        echo ""
        usage
        exit 1
    fi

    if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        usage
        exit 0
    fi

    local target_tag=$1

    # Display banner
    echo ""
    echo "=========================================="
    echo "Icebow Branch Rebase Automation"
    echo "=========================================="
    echo "Target version: ${target_tag}"
    echo "=========================================="
    echo ""

    # Execute workflow
    validate_prerequisites
    fetch_and_validate_tag "${target_tag}"
    create_backup_branch

    # Show commits and get merge base
    merge_base=$(show_commits_to_rebase "${target_tag}")

    # Execute rebase
    if execute_rebase "${target_tag}" "${merge_base}"; then
        # Rebase successful
        create_icebow_tag "${target_tag}"
        display_summary "${target_tag}"
    else
        # Rebase failed (conflicts)
        handle_rebase_conflict "${target_tag}"
    fi
}

# ==================== Entry Point ====================

main "$@"
