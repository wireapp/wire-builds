#!/usr/bin/env bash
# Common utilities for wire-builds automation scripts

set -euo pipefail

# Colors for output
readonly COLOR_RESET='\033[0m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[0;33m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_BLUE='\033[0;34m'

# Logging functions
log_info() {
    echo -e "${COLOR_BLUE}ℹ${COLOR_RESET} $*" >&2
}

log_success() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $*" >&2
}

log_warning() {
    echo -e "${COLOR_YELLOW}⚠${COLOR_RESET} $*" >&2
}

log_error() {
    echo -e "${COLOR_RED}✗${COLOR_RESET} $*" >&2
}

# Exit with error message
die() {
    log_error "$*"
    exit 1
}

# Check if command exists
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        die "Required command not found: $cmd"
    fi
}

# Retry with exponential backoff
retry_with_backoff() {
    local max_attempts="$1"
    local delay="$2"
    local command="${@:3}"
    local attempt=1

    while [ $attempt -le "$max_attempts" ]; do
        if eval "$command"; then
            return 0
        fi

        if [ $attempt -lt "$max_attempts" ]; then
            log_warning "Attempt $attempt/$max_attempts failed, retrying in ${delay}s..."
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done

    log_error "All $max_attempts attempts failed"
    return 1
}

# JSON utilities using jq
json_get() {
    local file="$1"
    local query="$2"
    jq -r "$query" "$file"
}

json_set() {
    local file="$1"
    local query="$2"
    jq "$query" "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# GitHub API utilities
github_api_get() {
    local endpoint="$1"
    local url="https://api.github.com${endpoint}"
    curl -sf "$url" || return 1
}

# Get commit SHA from wire-server release tag
get_commit_from_release() {
    local version="$1"
    local tag_ref
    local tag_sha
    local tag_type
    local commit_sha

    tag_ref=$(github_api_get "/repos/wireapp/wire-server/git/refs/tags/chart/$version") || return 1

    tag_sha=$(echo "$tag_ref" | jq -r '.object.sha')
    tag_type=$(echo "$tag_ref" | jq -r '.object.type')

    if [ "$tag_type" = "tag" ]; then
        # Annotated tag - dereference to get commit
        local tag_obj
        tag_obj=$(github_api_get "/repos/wireapp/wire-server/git/tags/$tag_sha") || return 1
        commit_sha=$(echo "$tag_obj" | jq -r '.object.sha')
    else
        # Lightweight tag or direct commit
        commit_sha="$tag_sha"
    fi

    echo "$commit_sha"
}

# Download file with retry
download_with_retry() {
    local url="$1"
    local output="$2"
    local max_retries="${3:-5}"
    local delay="${4:-3}"

    retry_with_backoff "$max_retries" "$delay" "curl -sf '$url' > '$output' 2>/dev/null"
}

# Git configuration
git_config_bot() {
    local name="${1:-github-actions[bot]}"
    local email="${2:-github-actions[bot]@users.noreply.github.com}"
    git config user.name "$name"
    git config user.email "$email"
}

# Extract SHA from wire-builds URL
extract_sha_from_url() {
    local url="$1"
    # Use sed for macOS compatibility (BSD grep doesn't support -P)
    echo "$url" | sed -n 's/.*wire-builds\/\([^/]*\).*/\1/p' | head -1 | tr -d '\n\r' || echo ""
}

# Compare two build.json files and generate changelog
generate_changelog() {
    local old_build="$1"
    local new_build="$2"

    # Extract wire-server version
    local ws_version
    ws_version=$(json_get "$new_build" '.helmCharts["wire-server"].version // "N/A"')
    echo "## Wire Server: $ws_version"
    echo ""

    # Find changed charts
    local changes
    changes=$(jq -r --slurpfile old "$old_build" '
        [.helmCharts | to_entries[] |
         select($old[0].helmCharts[.key] != null and
                (($old[0].helmCharts[.key].version // "") != .value.version or
                 ($old[0].helmCharts[.key].meta.commit // "") != .value.meta.commit)) |
         "- " + .key + ": " + $old[0].helmCharts[.key].version + " → " + .value.version
        ] | join("\n")
    ' "$new_build")

    if [ -n "$changes" ]; then
        echo "## Changed Charts"
        echo "$changes"
    else
        echo "No chart version changes"
    fi
}

# Ensure required commands are available
check_prerequisites() {
    require_command jq
    require_command curl
    require_command git
}
