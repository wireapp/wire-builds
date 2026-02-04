#!/usr/bin/env bash
# Pin wire-server and related charts to a specific version

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Pin wire-server and all related charts to a specific version.

OPTIONS:
    -v, --version VERSION    Wire-server version to pin to (required)
    -f, --file FILE          Path to build.json (default: build.json)
    -b, --base-branch BRANCH Base branch to branch from (default: current branch)
    -h, --help               Show this help message

DESCRIPTION:
    Creates a temporary branch with pinned build.json, tags it, and pushes the tag.
    The root build.json on the base branch remains unchanged.

    Pins wire-server and related charts to the specified version.
    Creates a Git tag: pinned-<base-branch>-<version>

    The tag name is output to stdout for use in workflows.

EXAMPLE:
    $0 --version 5.23.0
    # Creates tag: pinned-offline-5.23.0
    # URL: https://raw.githubusercontent.com/.../pinned-offline-5.23.0/build.json

    $0 --version 5.23.0 --base-branch offline
    # Creates tag: pinned-offline-5.23.0

EOF
    exit 1
}

# Parse command line arguments
parse_args() {
    PINNED_VERSION=""
    BUILD_FILE="build.json"
    BASE_BRANCH=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--version)
                PINNED_VERSION="$2"
                shift 2
                ;;
            -f|--file)
                BUILD_FILE="$2"
                shift 2
                ;;
            -b|--base-branch)
                BASE_BRANCH="$2"
                shift 2
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

    # Validate required arguments
    if [ -z "$PINNED_VERSION" ]; then
        log_error "Version is required"
        usage
    fi

    if [ ! -f "$BUILD_FILE" ]; then
        die "Build file not found: $BUILD_FILE"
    fi

    # Get current branch if not specified
    if [ -z "$BASE_BRANCH" ]; then
        BASE_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    fi
}

# Get current wire-server version
get_current_version() {
    json_get "$BUILD_FILE" '.helmCharts["wire-server"].version'
}

# Find all charts with the same version as wire-server
find_charts_to_update() {
    local current_version="$1"
    json_get "$BUILD_FILE" "
        [.helmCharts | to_entries[] |
         select(.value.version == \"$current_version\") |
         .key
        ] | join(\" \")
    "
}

# Fetch commit metadata for the pinned version
fetch_commit_metadata() {
    local version="$1"
    local commit_sha
    local commit_url

    log_info "Fetching commit SHA for wire-server version $version..."

    if commit_sha=$(get_commit_from_release "$version"); then
        commit_url="https://github.com/wireapp/wire-server/commit/$commit_sha"
        log_success "Found commit for version $version: $commit_sha"
        echo "$commit_sha|$commit_url"
    else
        log_warning "Could not find release tag chart/$version in wire-server"
        log_warning "Will update version only, keeping existing commit metadata"
        echo "|"
    fi
}

# Update a single chart
update_chart() {
    local chart="$1"
    local version="$2"
    local commit="$3"
    local commit_url="$4"

    log_info "Updating $chart to $version"

    if [ -n "$commit" ]; then
        # Update version and commit metadata
        json_set "$BUILD_FILE" "
            .helmCharts[\"$chart\"].version = \"$version\" |
            .helmCharts[\"$chart\"].meta.commit = \"$commit\" |
            .helmCharts[\"$chart\"].meta.commitURL = \"$commit_url\"
        "
    else
        # Update version only
        json_set "$BUILD_FILE" ".helmCharts[\"$chart\"].version = \"$version\""
    fi
}

# Create orphan branch with only build.json, tag it, and push tag
commit_and_push() {
    local current_version="$1"
    local pinned_version="$2"
    local charts="$3"
    local base_branch="$4"
    local source_build_file="$5"

    local temp_branch="temp-pin-${pinned_version}"
    local tag_name="pinned-${base_branch}-${pinned_version}"

    log_info "Creating orphan branch with only build.json: $temp_branch"

    # Create orphan branch (no parent commit, clean history)
    git checkout --orphan "$temp_branch" >&2

    # Remove all files from staging area
    git rm -rf . >/dev/null 2>&1 || true

    # Add only the pinned build.json
    cp "$source_build_file" build.json

    log_info "Committing pinned build.json..."
    git_config_bot
    git add build.json

    # Build commit message
    cat > /tmp/pin-commit-msg.txt <<EOF
Pin wire-server and related charts to $pinned_version

Charts updated from $current_version to $pinned_version:
$charts

Base branch: $base_branch
Tag: $tag_name

This is an orphan branch containing only build.json for the pinned version.
EOF

    git commit -F /tmp/pin-commit-msg.txt >&2
    rm -f /tmp/pin-commit-msg.txt

    local commit_sha
    commit_sha=$(git rev-parse HEAD)

    log_info "Creating and pushing tag: $tag_name"

    # Delete tag if it exists (for re-pinning same version)
    if git ls-remote --tags origin | grep -q "refs/tags/$tag_name"; then
        log_warning "Tag $tag_name already exists, deleting..."
        git push origin --delete "$tag_name" || true
    fi

    # Create and push tag
    git tag "$tag_name" "$commit_sha"
    git push origin "$tag_name" >&2

    # Switch back to base branch and delete temp branch
    log_info "Cleaning up orphan branch"
    git checkout "$base_branch" >&2
    git branch -D "$temp_branch" >&2

    log_success "Version pinning complete!"
    log_success "Tag: $tag_name"
    log_success "Commit SHA: $commit_sha"

    # Output tag name (not commit SHA|path anymore)
    echo "$tag_name"
}

# Main function
main() {
    check_prerequisites
    parse_args "$@"

    log_info "Pinning wire-server and related charts to version $PINNED_VERSION"
    echo "" >&2

    # Create a temporary working file
    local temp_build_file="/tmp/build-pinned-$PINNED_VERSION.json"
    cp "$BUILD_FILE" "$temp_build_file"
    local original_build_file="$BUILD_FILE"
    BUILD_FILE="$temp_build_file"

    # Get current wire-server version
    local current_version
    current_version=$(get_current_version)
    log_info "Current wire-server version: $current_version"
    log_info "Target wire-server version: $PINNED_VERSION"
    echo "" >&2

    # Fetch commit metadata
    local metadata
    metadata=$(fetch_commit_metadata "$PINNED_VERSION")
    local commit_sha="${metadata%%|*}"
    local commit_url="${metadata##*|}"
    echo "" >&2

    # Find charts to update
    log_info "Finding charts with version $current_version..."
    local charts
    charts=$(find_charts_to_update "$current_version")
    log_info "Charts to update: $charts"
    echo "" >&2

    # Update each chart
    log_info "Updating charts..."
    for chart in $charts; do
        update_chart "$chart" "$PINNED_VERSION" "$commit_sha" "$commit_url"
    done
    echo "" >&2

    # Show summary
    log_info "Summary of pinned charts:"
    for chart in $charts; do
        local version
        version=$(json_get "$BUILD_FILE" ".helmCharts[\"$chart\"].version")
        echo "  $chart: $version" >&2
    done
    echo "" >&2

    # Commit and push (returns commit SHA and file path)
    commit_and_push "$current_version" "$PINNED_VERSION" "$charts" "$BASE_BRANCH" "$temp_build_file"

    # Cleanup
    rm -f "$temp_build_file"
}

# Run main function
main "$@"
