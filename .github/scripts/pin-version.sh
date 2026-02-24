#!/usr/bin/env bash
# Pin wire-server and/or individual charts to specific versions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Global arrays for chart pins
declare -a CHART_PINS=()

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Pin wire-server and/or individual charts to specific versions.

OPTIONS:
    -v, --version VERSION    Wire-server version to pin to (optional if using --pin-chart)
    -f, --file FILE          Path to build.json (default: build.json)
    -b, --base-branch BRANCH Base branch to branch from (default: current branch)
    -p, --pin-chart SPEC     Pin individual chart (format: chart:release:repo:github_repo)
                             Can be specified multiple times
    -h, --help               Show this help message

DESCRIPTION:
    Creates a temporary branch with pinned build.json, tags it, and pushes the tag.
    The root build.json on the base branch remains unchanged.

    Mode 1: Pin wire-server and all related charts to the same version
    Mode 2: Pin individual charts by their release tags (webapp, account-pages, etc.)
    Mode 3: Combination of both

    Creates a Git tag: pinned-<base-branch>-<descriptive-name>

    The tag name is output to stdout for use in workflows.

CHART SPEC FORMAT:
    chart:release:repo:github_repo
    - chart: Chart name (e.g., webapp, account-pages)
    - release: Release tag to pin to (e.g., 2025-12-10-production.0)
    - repo: Helm chart repo name (e.g., charts-webapp, charts)
    - github_repo: GitHub repository for commit lookup (e.g., wireapp/wire-webapp)

EXAMPLES:
    # Pin wire-server and related charts
    $0 --version 5.23.0

    # Pin webapp only
    $0 --pin-chart webapp:2025-12-10-production.0:charts-webapp:wireapp/wire-webapp

    # Pin both wire-server and webapp
    $0 --version 5.25.0 \\
       --pin-chart webapp:2025-12-10-production.0:charts-webapp:wireapp/wire-webapp

    # Pin multiple individual charts
    $0 --pin-chart webapp:2025-12-10-production.0:charts-webapp:wireapp/wire-webapp \\
       --pin-chart account-pages:2.9.0:charts-webapp:wireapp/account-pages

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
            -p|--pin-chart)
                CHART_PINS+=("$2")
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
    if [ -z "$PINNED_VERSION" ] && [ ${#CHART_PINS[@]} -eq 0 ]; then
        log_error "Either --version or --pin-chart is required"
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

# Fetch commit metadata for the pinned wire-server version
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

# Update a single chart with wire-server style metadata
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

# Update a single chart by searching for appVersion
update_chart_by_appversion() {
    local chart_name="$1"
    local release_tag="$2"
    local repo_name="$3"
    local github_repo="$4"

    log_info "Pinning $chart_name to release: $release_tag"
    echo "" >&2

    # Construct index URL based on repo name
    local index_url="https://s3-eu-west-1.amazonaws.com/public.wire.com/${repo_name}/index.yaml"

    # Fetch chart info
    local chart_info
    if ! chart_info=$(get_chart_by_appversion "$chart_name" "$index_url" "$github_repo" "$release_tag"); then
        die "Failed to find $chart_name chart with release tag: $release_tag"
    fi

    # Parse chart info: chart_version|commit_sha|commit_url|app_version
    local chart_version="${chart_info%%|*}"
    local remaining="${chart_info#*|}"
    local commit_sha="${remaining%%|*}"
    remaining="${remaining#*|}"
    local commit_url="${remaining%%|*}"
    local app_version="${remaining#*|}"

    log_info "Updating $chart_name:"
    log_info "  Chart version: $chart_version"
    log_info "  appVersion: $app_version"
    if [ -n "$commit_sha" ]; then
        log_info "  Commit: ${commit_sha:0:7}"
    fi
    echo "" >&2

    # Update build.json with chart version and metadata
    if [ -n "$commit_sha" ] && [ -n "$commit_url" ] && [ -n "$app_version" ]; then
        json_set "$BUILD_FILE" "
            .helmCharts[\"$chart_name\"].version = \"$chart_version\" |
            .helmCharts[\"$chart_name\"].meta.commit = \"$commit_sha\" |
            .helmCharts[\"$chart_name\"].meta.commitURL = \"$commit_url\" |
            .helmCharts[\"$chart_name\"].meta.appVersion = \"$app_version\"
        "
    elif [ -n "$app_version" ]; then
        json_set "$BUILD_FILE" "
            .helmCharts[\"$chart_name\"].version = \"$chart_version\" |
            .helmCharts[\"$chart_name\"].meta.appVersion = \"$app_version\"
        "
    else
        json_set "$BUILD_FILE" ".helmCharts[\"$chart_name\"].version = \"$chart_version\""
    fi
}

# Generate tag name based on what was pinned
generate_tag_name() {
    local base_branch="$1"
    local pinned_version="$2"
    local pin_specs=("${@:3}")

    if [ -n "$pinned_version" ] && [ ${#pin_specs[@]} -eq 0 ]; then
        # Only wire-server pinned
        echo "pinned-${base_branch}-${pinned_version}"
    elif [ -z "$pinned_version" ] && [ ${#pin_specs[@]} -eq 1 ]; then
        # Only one chart pinned
        local chart_name="${pin_specs[0]%%:*}"
        local release_tag
        release_tag=$(echo "${pin_specs[0]}" | cut -d: -f2)
        echo "pinned-${base_branch}-${chart_name}-${release_tag}"
    else
        # Multiple charts or combination - use timestamp
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        echo "pinned-${base_branch}-multi-${timestamp}"
    fi
}

# Create orphan branch with only build.json, tag it, and push tag
commit_and_push() {
    local base_branch="$1"
    local source_build_file="$2"
    local tag_name="$3"
    local summary="$4"

    local temp_branch="temp-pin-${tag_name}"

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
Pin charts for ${base_branch}

${summary}

Base branch: ${base_branch}
Tag: ${tag_name}

This is an orphan branch containing only build.json for the pinned version.
EOF

    git commit -F /tmp/pin-commit-msg.txt >&2
    rm -f /tmp/pin-commit-msg.txt

    local commit_sha
    commit_sha=$(git rev-parse HEAD)

    log_info "Creating and pushing tag: $tag_name"

    # Delete tag if it exists (for re-pinning same version)
    if git tag -l "$tag_name" | grep -q "$tag_name"; then
        log_warning "Local tag $tag_name already exists, deleting..."
        git tag -d "$tag_name" >&2 || true
    fi
    if git ls-remote --tags origin | grep -q "refs/tags/$tag_name"; then
        log_warning "Remote tag $tag_name already exists, deleting..."
        git push origin --delete "$tag_name" >&2 || true
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

    # Output tag name
    echo "$tag_name"
}

# Main function
main() {
    check_prerequisites
    parse_args "$@"

    local summary=""

    log_info "Pinning charts for branch: $BASE_BRANCH"
    echo "" >&2

    # Create a temporary working file
    local temp_build_file="/tmp/build-pinned-$$.json"
    cp "$BUILD_FILE" "$temp_build_file"
    local original_build_file="$BUILD_FILE"
    BUILD_FILE="$temp_build_file"

    # Pin wire-server and related charts if version specified
    if [ -n "$PINNED_VERSION" ]; then
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

        summary="Wire-server and related charts: $current_version → $PINNED_VERSION"
    fi

    # Pin individual charts if specified
    if [ ${#CHART_PINS[@]} -gt 0 ]; then
        log_info "Pinning individual charts..."
        echo "" >&2

        for chart_spec in "${CHART_PINS[@]}"; do
            # Parse spec: chart:release:repo:github_repo
            IFS=':' read -r chart_name release_tag repo_name github_repo <<< "$chart_spec"

            if [ -z "$chart_name" ] || [ -z "$release_tag" ] || [ -z "$repo_name" ] || [ -z "$github_repo" ]; then
                die "Invalid chart spec: $chart_spec (expected format: chart:release:repo:github_repo)"
            fi

            update_chart_by_appversion "$chart_name" "$release_tag" "$repo_name" "$github_repo"

            if [ -n "$summary" ]; then
                summary="$summary\n"
            fi
            summary="${summary}${chart_name}: ${release_tag}"
        done
    fi

    # Show summary
    log_info "Summary of pinned charts:"
    jq -r '.helmCharts | to_entries[] | "\(.key): \(.value.version)"' "$BUILD_FILE" | while read -r line; do
        echo "  $line" >&2
    done
    echo "" >&2

    # Generate tag name
    local tag_name
    tag_name=$(generate_tag_name "$BASE_BRANCH" "$PINNED_VERSION" "${CHART_PINS[@]}")

    # Commit and push (returns tag name)
    commit_and_push "$BASE_BRANCH" "$temp_build_file" "$tag_name" "$summary"

    # Cleanup
    rm -f "$temp_build_file"
}

# Run main function
main "$@"
