#!/usr/bin/env bash
# Manually sync build.json from a source ref into a target branch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Manually sync build.json from a source ref into a target branch.

OPTIONS:
    -s, --source-ref REF      Source git ref to copy from (default: origin/main)
    -t, --target-branch NAME  Target branch to update (default: offline)
    -f, --file PATH           Path to build file (default: build.json)
    -n, --no-push             Commit locally but do not push
    -h, --help                Show this help message

EXAMPLES:
    $0
    $0 --source-ref origin/main --target-branch offline
    $0 --no-push
EOF
    exit 1
}

parse_args() {
    SOURCE_REF="origin/main"
    TARGET_BRANCH="offline"
    BUILD_FILE="build.json"
    SHOULD_PUSH="true"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--source-ref)
                SOURCE_REF="$2"
                shift 2
                ;;
            -t|--target-branch)
                TARGET_BRANCH="$2"
                shift 2
                ;;
            -f|--file)
                BUILD_FILE="$2"
                shift 2
                ;;
            -n|--no-push)
                SHOULD_PUSH="false"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done
}

check_prerequisites() {
    require_command git

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        die "This script must be run from inside a git repository"
    fi

    if ! git diff --quiet || ! git diff --cached --quiet; then
        die "Working tree is not clean. Commit or stash changes before syncing."
    fi
}

sync_build_file() {
    local original_branch
    local commit_msg
    local commit_author
    local commit_email

    log_info "Fetching latest refs..."
    git fetch origin

    if ! git rev-parse --verify "$SOURCE_REF" >/dev/null 2>&1; then
        die "Source ref not found: $SOURCE_REF"
    fi

    if ! git rev-parse --verify "origin/$TARGET_BRANCH" >/dev/null 2>&1; then
        die "Target branch not found on origin: $TARGET_BRANCH"
    fi

    original_branch=$(git rev-parse --abbrev-ref HEAD)

    log_info "Checking out target branch: $TARGET_BRANCH"
    git checkout "$TARGET_BRANCH"
    git reset --hard "origin/$TARGET_BRANCH"

    log_info "Copying $BUILD_FILE from $SOURCE_REF"
    git checkout "$SOURCE_REF" -- "$BUILD_FILE"

    if git diff --cached --quiet -- "$BUILD_FILE"; then
        log_info "No changes detected. $BUILD_FILE already matches $SOURCE_REF"
        if [ "$original_branch" != "$TARGET_BRANCH" ]; then
            git checkout "$original_branch"
        fi
        return 0
    fi

    commit_msg=$(git log "$SOURCE_REF" -1 --format=%B -- "$BUILD_FILE")
    commit_author=$(git log "$SOURCE_REF" -1 --format=%an -- "$BUILD_FILE")
    commit_email=$(git log "$SOURCE_REF" -1 --format=%ae -- "$BUILD_FILE")

    log_info "Committing synced $BUILD_FILE"
    git add "$BUILD_FILE"
    git -c user.name="$commit_author" -c user.email="$commit_email" commit -m "$commit_msg"

    if [ "$SHOULD_PUSH" = "true" ]; then
        log_info "Pushing $TARGET_BRANCH to origin"
        git push origin "$TARGET_BRANCH"
        log_success "Synced $BUILD_FILE from $SOURCE_REF to $TARGET_BRANCH"
    else
        log_success "Committed synced $BUILD_FILE locally on $TARGET_BRANCH"
    fi

    if [ "$original_branch" != "$TARGET_BRANCH" ]; then
        git checkout "$original_branch"
    fi
}

main() {
    parse_args "$@"
    check_prerequisites
    sync_build_file
}

main "$@"