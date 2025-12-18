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
    -b, --branch BRANCH      Git branch to push to (default: current branch)
    -h, --help               Show this help message

EXAMPLE:
    $0 --version 5.23.0
    $0 --version 5.23.0 --file path/to/build.json --branch offline

EOF
    exit 1
}

# Parse command line arguments
parse_args() {
    PINNED_VERSION=""
    BUILD_FILE="build.json"
    GIT_BRANCH=""

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
            -b|--branch)
                GIT_BRANCH="$2"
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
    if [ -z "$GIT_BRANCH" ]; then
        GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
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

# Commit and push changes
commit_and_push() {
    local current_version="$1"
    local pinned_version="$2"
    local charts="$3"
    local branch="$4"

    log_info "Committing changes..."

    git_config_bot
    git add "$BUILD_FILE"

    # Build commit message
    cat > /tmp/pin-commit-msg.txt <<EOF
Pin wire-server and related charts to $pinned_version

Charts updated from $current_version to $pinned_version:
$charts
EOF

    git commit -F /tmp/pin-commit-msg.txt
    rm -f /tmp/pin-commit-msg.txt

    log_info "Pushing to branch: $branch"
    git push origin "HEAD:refs/heads/$branch"

    log_success "Version pinning complete!"
}

# Main function
main() {
    check_prerequisites
    parse_args "$@"

    log_info "Pinning wire-server and related charts to version $PINNED_VERSION"
    echo ""

    # Get current wire-server version
    local current_version
    current_version=$(get_current_version)
    log_info "Current wire-server version: $current_version"
    log_info "Target wire-server version: $PINNED_VERSION"
    echo ""

    # Fetch commit metadata
    local metadata
    metadata=$(fetch_commit_metadata "$PINNED_VERSION")
    local commit_sha="${metadata%%|*}"
    local commit_url="${metadata##*|}"
    echo ""

    # Find charts to update
    log_info "Finding charts with version $current_version..."
    local charts
    charts=$(find_charts_to_update "$current_version")
    log_info "Charts to update: $charts"
    echo ""

    # Update each chart
    log_info "Updating charts..."
    for chart in $charts; do
        update_chart "$chart" "$PINNED_VERSION" "$commit_sha" "$commit_url"
    done
    echo ""

    # Show summary
    log_info "Summary of pinned charts:"
    for chart in $charts; do
        local version
        version=$(json_get "$BUILD_FILE" ".helmCharts[\"$chart\"].version")
        echo "  $chart: $version"
    done
    echo ""

    # Commit and push
    commit_and_push "$current_version" "$PINNED_VERSION" "$charts" "$GIT_BRANCH"
}

# Run main function
main "$@"
