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

# Get chart version from Helm chart index by searching for appVersion
# Usage: get_chart_by_appversion <chart_name> <index_url> <github_repo> <appversion_search>
# Returns: chart_version|commit_sha|commit_url|app_version
# Example: get_chart_by_appversion "webapp" "https://...charts-webapp/index.yaml" "wireapp/wire-webapp" "2025-12-10-production.0"
get_chart_by_appversion() {
    local chart_name="$1"
    local index_url="$2"
    local github_repo="$3"
    local search_pattern="$4"

    local temp_yaml="/tmp/${chart_name}-index-$$.yaml"

    log_info "Fetching $chart_name chart index from: $index_url"
    if ! download_with_retry "$index_url" "$temp_yaml"; then
        rm -f "$temp_yaml"
        return 1
    fi

    log_info "Searching for $chart_name chart with appVersion matching: $search_pattern"

    # Parse YAML to find chart with matching appVersion
    local chart_info
    if command -v yq &> /dev/null; then
        # Use yq if available (more reliable)
        chart_info=$(yq eval ".entries[\"${chart_name}\"][] | select(.appVersion | test(\"^${search_pattern}\")) | .version + \"|\" + (.appVersion // \"\")" "$temp_yaml" 2>/dev/null | head -1)
    else
        # Fallback: use awk for basic YAML parsing
        chart_info=$(awk -v chart="$chart_name" -v pattern="$search_pattern" '
            BEGIN { in_chart = 0 }
            $0 ~ "^  " chart ":" { in_chart = 1; next }
            in_chart && /^  [a-z]/ { in_chart = 0 }
            in_chart && /^  - appVersion:/ {
                app_version = $3
                # Read ahead to find version
                while (getline > 0) {
                    if ($1 == "version:") {
                        version = $2
                        # Check if appVersion starts with pattern
                        if (index(app_version, pattern) == 1) {
                            print version "|" app_version
                            exit
                        }
                        break
                    }
                    if ($0 ~ /^  - /) break
                }
            }
        ' "$temp_yaml")
    fi

    if [ -z "$chart_info" ]; then
        log_warning "No chart found with appVersion matching: $search_pattern"
        rm -f "$temp_yaml"
        return 1
    fi

    local chart_version="${chart_info%%|*}"
    local app_version="${chart_info##*|}"

    log_success "Found $chart_name chart version: $chart_version (appVersion: $app_version)"

    # Extract commit SHA from appVersion (typically at the end: ...-vX.Y.Z-commit_sha)
    # Use sed for reliable extraction (BASH_REMATCH has issues with set -u)
    local commit_sha=""
    commit_sha=$(echo "$app_version" | sed -E 's/.*-([a-f0-9]{7,})$/\1/' | grep -E '^[a-f0-9]{7,}$' || echo "")

    # Get full commit SHA and URL from GitHub if we have a short SHA
    local full_commit_sha=""
    local commit_url=""
    if [ -n "$commit_sha" ] && [ -n "$github_repo" ]; then
        log_info "Looking up full commit SHA for: $commit_sha in $github_repo"
        # Fetch directly and extract SHA
        local api_url="https://api.github.com/repos/${github_repo}/commits/$commit_sha"
        if full_commit_sha=$(curl -sf "$api_url" | jq -r '.sha // empty' 2>/dev/null) && [ -n "$full_commit_sha" ]; then
            commit_url="https://github.com/${github_repo}/commit/$full_commit_sha"
            log_success "Commit: ${full_commit_sha:0:7}"
        else
            log_warning "Could not fetch full commit SHA from GitHub"
        fi
    fi

    rm -f "$temp_yaml"
    echo "${chart_version}|${full_commit_sha}|${commit_url}|${app_version}"
}

# Ensure required commands are available
check_prerequisites() {
    require_command jq
    require_command curl
    require_command git
}
