#!/usr/bin/env bash
# Update wire-server-deploy repository and create/update PR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Constants
readonly SCRIPT_FILE="offline/tasks/proc_pull_charts.sh"
# Branch name will be set dynamically based on whether it's a pinned version

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Update wire-server-deploy repository with new wire-builds reference.

OPTIONS:
    -r, --ref REF            Git reference (commit SHA or tag name) (required)
    -d, --deploy-dir DIR     Path to wire-server-deploy directory (required)
    -t, --token TOKEN        GitHub token for creating PRs (required)
    -b, --source-branch BRANCH  Source branch name (main/offline) (optional, default: offline)
    -T, --target-branch BRANCH  Target branch in wire-server-deploy (optional, default: master)
    -h, --help               Show this help message

ENVIRONMENT:
    GITHUB_SERVER_URL        GitHub server URL (default: https://github.com)
    GITHUB_REPOSITORY        Repository name (for PR body link)
    GITHUB_RUN_ID            Workflow run ID (for PR body link)

EXAMPLE:
    $0 --ref abc123 --deploy-dir ./wire-server-deploy --token \$ZEBOT_TOKEN
    $0 --ref pinned-offline-5.23.0 --deploy-dir ./wire-server-deploy --token \$ZEBOT_TOKEN
    $0 --ref abc123 --deploy-dir ./wire-server-deploy --token \$ZEBOT_TOKEN --source-branch main --target-branch develop

EOF
    exit 1
}

# Parse command line arguments
parse_args() {
    BUILD_REF=""
    DEPLOY_DIR=""
    GITHUB_TOKEN=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--ref)
                BUILD_REF="$2"
                shift 2
                ;;
            -d|--deploy-dir)
                DEPLOY_DIR="$2"
                shift 2
                ;;
            -t|--token)
                GITHUB_TOKEN="$2"
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
    if [ -z "$BUILD_REF" ]; then
        log_error "Git reference is required"
        usage
    fi

    if [ -z "$DEPLOY_DIR" ]; then
        log_error "Deploy directory is required"
        usage
    fi

    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GitHub token is required"
        usage
    fi

    if [ ! -d "$DEPLOY_DIR" ]; then
        die "Deploy directory not found: $DEPLOY_DIR"
    fi
}

# Determine branch name based on the ref
get_branch_name() {
    local ref="$1"

    # Check if ref is a pinned tag (format: pinned-<branch>-<version>)
    if [[ "$ref" =~ ^pinned-([^-]+)-([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        local base_branch="${BASH_REMATCH[1]}"
        local version="${BASH_REMATCH[2]}"
        echo "auto/pin-${base_branch}-${version}"
    else
        # For regular commits, use version-bump branch name
        echo "auto/wire-server-version-bump"
    fi
}

# Get current wire_build URL from master branch
get_current_url() {
    local current_url
    # Use sed for macOS compatibility
    current_url=$(sed -n 's/.*wire_build="https\([^"]*\)".*/\1/p' "$SCRIPT_FILE" | head -1 | tr -d '\n\r' || echo "")
    if [ -n "$current_url" ]; then
        echo "https${current_url}"
    fi
}

# Check if update is needed
check_if_update_needed() {
    local new_url="$1"
    local current_url
    # Use sed for macOS compatibility
    current_url=$(sed -n 's/.*wire_build="\([^"]*\)".*/\1/p' "$SCRIPT_FILE" | head -1 || echo "")

    if [ "$current_url" = "$new_url" ]; then
        log_info "No changes detected - wire_build URL is already: $new_url"
        return 1
    fi

    return 0
}

# Manage branch (create or rebase)
manage_branch() {
    log_info "Managing branch: $BRANCH_NAME"

    git fetch origin "$BRANCH_NAME" || true

    if git rev-parse --verify "origin/$BRANCH_NAME" >/dev/null 2>&1; then
        log_info "Branch exists, checking out and rebasing on master"
        git checkout -b "$BRANCH_NAME" "origin/$BRANCH_NAME"

        if ! git rebase origin/master; then
            log_warning "Rebase failed, recreating branch from master"
            git rebase --abort
            git checkout master
            git branch -D "$BRANCH_NAME"
            git checkout -b "$BRANCH_NAME"
        fi
    else
        log_info "Creating new branch from master"
        git checkout -b "$BRANCH_NAME"
    fi
}

# Update wire_build URL in the script file
update_wire_build_url() {
    local new_url="$1"

    log_info "Updating wire_build URL to: $new_url"

    sed -i.bak "s|wire_build=\"https://raw.githubusercontent.com/wireapp/wire-builds/[^\"]*\"|wire_build=\"$new_url\"|" "$SCRIPT_FILE"
    rm -f "$SCRIPT_FILE.bak"

    log_info "Changes:"
    git diff "$SCRIPT_FILE"
}

# Generate detailed commit message
generate_commit_message() {
    local old_url="$1"
    local new_url="$2"
    local old_sha
    local new_sha

    old_sha=$(extract_sha_from_url "$old_url")
    new_sha=$(extract_sha_from_url "$new_url")

    log_info "Generating commit message..."

    # Download build.json files
    local old_build="/tmp/old_build.json"
    local new_build="/tmp/new_build.json"

    if [ -n "$old_url" ] && download_with_retry "$old_url" "$old_build"; then
        log_success "Downloaded old build.json"
    else
        log_warning "Could not download old build.json, using empty baseline"
        echo '{"helmCharts":{}}' > "$old_build"
    fi

    if download_with_retry "$new_url" "$new_build"; then
        log_success "Downloaded new build.json"
    else
        die "Failed to download new build.json"
    fi

    # Extract wire-server version
    local ws_version
    ws_version=$(json_get "$new_build" '.helmCharts["wire-server"].version // "N/A"')

    # Generate changelog
    local changes
    changes=$(jq -r --slurpfile old "$old_build" '
        [.helmCharts | to_entries[] |
         select($old[0].helmCharts[.key] != null and
                (($old[0].helmCharts[.key].version // "") != .value.version or
                 ($old[0].helmCharts[.key].meta.commit // "") != .value.meta.commit)) |
         "- " + .key + ": " + $old[0].helmCharts[.key].version + " → " + .value.version
        ] | join("\n")
    ' "$new_build")

    # Build commit message
    cat > /tmp/commit-msg.txt <<EOF
Update wire-builds to ${old_sha:0:7}...${new_sha:0:7}

Wire Server: $ws_version

$(if [ -n "$changes" ]; then
    echo "Changed charts:"
    echo "$changes"
else
    echo "No chart version changes"
fi)

Build: $new_url
EOF

    log_success "Commit message generated"
}

# Commit and push changes
commit_and_push() {
    log_info "Committing changes..."

    git_config_bot "zebot" "zebot@users.noreply.github.com"
    git add "$SCRIPT_FILE"
    git commit -F /tmp/commit-msg.txt
    rm -f /tmp/commit-msg.txt

    log_info "Pushing branch (force push to update existing PR)..."
    git push -f origin "$BRANCH_NAME"

    log_success "Branch pushed successfully"
}

# Generate PR body
generate_pr_body() {
    local new_url="$1"
    local ws_version
    local ws_commit
    local ws_commit_url

    log_info "Generating PR body..."

    # Download new build.json
    local new_build="/tmp/new_build_pr.json"
    if ! download_with_retry "$new_url" "$new_build"; then
        die "Failed to download new build.json for PR body"
    fi

    ws_version=$(json_get "$new_build" '.helmCharts["wire-server"].version // "N/A"')
    ws_commit=$(json_get "$new_build" '.helmCharts["wire-server"].meta.commit // "N/A"')
    ws_commit_url=$(json_get "$new_build" '.helmCharts["wire-server"].meta.commitURL // ""')

    local github_server_url="${GITHUB_SERVER_URL:-https://github.com}"
    local workflow_url="${github_server_url}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

    cat > /tmp/pr-body.txt <<EOF
## Wire Server Version
- Version: \`$ws_version\`
$(if [ -n "$ws_commit_url" ] && [ "$ws_commit_url" != "null" ]; then
    echo "- Commit: [\`${ws_commit:0:7}\`]($ws_commit_url)"
fi)

---

**Note:** This PR updates the wire-builds reference in \`offline/tasks/proc_pull_charts.sh\`.

**See commit messages for detailed chart changes** - PR description cannot be auto-updated due to token permissions.

<sub>🤖 Auto-generated by [wire-builds]($workflow_url)</sub>
EOF

    log_success "PR body generated"
}

# Create or update PR
create_or_update_pr() {
    export GH_TOKEN="$GITHUB_TOKEN"

    log_info "Checking if PR already exists..."

    local existing_pr
    existing_pr=$(gh pr list --head "$BRANCH_NAME" --base master --json number --jq '.[0].number' || echo "")

    if [ -n "$existing_pr" ]; then
        log_warning "PR #$existing_pr already exists"
        log_info "Note: Cannot update existing PR (requires read:org token scope)"
        log_info "The branch has been updated with latest changes."
        log_info "PR will show updated content once permissions are configured."
    else
        log_info "Creating new PR..."
        gh pr create \
            --title "Update wire-builds" \
            --body-file /tmp/pr-body.txt \
            --base master \
            --head "$BRANCH_NAME"
        log_success "PR created successfully"
    fi

    rm -f /tmp/pr-body.txt
}

# Main function
main() {
    check_prerequisites
    require_command gh
    parse_args "$@"

    cd "$DEPLOY_DIR" || die "Failed to change to deploy directory"

    local new_url="https://raw.githubusercontent.com/wireapp/wire-builds/$BUILD_REF/build.json"

    log_info "Updating wire-server-deploy with ref: $BUILD_REF"
    echo ""

    # Check if update is needed
    if ! check_if_update_needed "$new_url"; then
        log_info "No update needed"
        exit 0
    fi

    # Get old URL from master before making changes
    git checkout master
    local old_url
    old_url=$(get_current_url)
    log_info "Old URL: $old_url"
    log_info "New URL: $new_url"
    echo ""

    # Determine branch name based on ref type
    BRANCH_NAME=$(get_branch_name "$BUILD_REF")
    log_info "Branch name: $BRANCH_NAME"

    # Manage branch
    manage_branch
    echo ""

    # Update wire_build URL
    update_wire_build_url "$new_url"
    echo ""

    # Generate commit message
    generate_commit_message "$old_url" "$new_url"
    echo ""

    # Commit and push
    commit_and_push
    echo ""

    # Generate PR body
    generate_pr_body "$new_url"
    echo ""

    # Create or update PR
    create_or_update_pr
    echo ""

    log_success "wire-server-deploy update complete!"
}

# Run main function
main "$@"
