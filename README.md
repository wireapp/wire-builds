# Wire Builds (Offline Branch)

This repository manages Wire Server build configurations for offline deployments and automates deployment to the wire-server-deploy repository.

## Overview

- `build.json`: Helm chart versions and metadata for all Wire components
- `.github/workflows/create-deploy-pr.yml`: Automation workflow for PR creation

## Workflow

The workflow automatically creates or updates pull requests in the [wire-server-deploy](https://github.com/wireapp/wire-server-deploy) repository.

### Triggers

1. **Push to `main` branch** when `build.json` is modified - automatically syncs to `offline` branch
2. **Push to `offline` branch** when `build.json` is modified
3. **Pull requests** that modify `build.json`
4. **Manual dispatch (CLI)** with optional wire-server version pinning

### Features

#### Automatic Build Sync and PR Creation

When `build.json` is updated on the `main` branch:
1. The `sync-build-json.yml` workflow automatically syncs it to the `offline` branch
2. This triggers the `create-deploy-pr.yml` workflow, which:
   - Updates the wire-build URL in `wire-server-deploy/offline/tasks/proc_pull_charts.sh`
   - Creates/updates a PR in wire-server-deploy with version details and commit links
   - Uses branch name: `auto/wire-server-version-bump`

When `build.json` is updated directly on the `offline` branch (manual changes):
1. The `create-deploy-pr.yml` workflow triggers directly
2. Updates wire-server-deploy and creates a PR (same as above)

#### Wire-Server Version Pinning (CLI)

Pin wire-server and all related charts to a specific version using GitHub CLI:

```bash
gh workflow run create-deploy-pr.yml \
  --ref offline \
  -f wire_server_version=5.23.0

# Watch the workflow execution
gh run watch
```

**How it works:**
1. Workflow creates an orphan branch (isolated, no history)
2. Fetches the correct commit SHA from wire-server releases
3. Updates all charts that match the current wire-server version to the pinned version
4. Places only the pinned `build.json` in the orphan branch
5. Commits and creates a Git tag: `pinned-<branch>-<version>`
6. Pushes the tag to remote and deletes the orphan branch
7. Creates a PR to wire-server-deploy using the tag name

**Important:**
- The base branch (e.g., `offline`) remains unchanged at the latest version
- Pinned versions use orphan branches containing **only build.json** (no other files)
- Tags point to these minimal commits for clean, lightweight version pinning
- Accessible via clean URLs

**Example after pinning to 5.23.0:**
```
offline branch: build.json at 5.24.0 (unchanged)
Git tag: pinned-offline-5.23.0 → orphan commit with only build.json at 5.23.0
URL: https://raw.githubusercontent.com/wireapp/wire-builds/pinned-offline-5.23.0/build.json

# List all pinned versions
$ git tag -l 'pinned-offline-*'
pinned-offline-5.23.0
pinned-offline-5.22.0

# Verify the tag contains only build.json
$ git ls-tree pinned-offline-5.23.0
100644 blob abc123... build.json
```

**Note:** You can pin to any valid wire-server version (e.g., 5.24.0, 5.23.0, etc.). The workflow will fetch the corresponding commit SHA from wire-server releases.

**Charts that get pinned together:**
- wire-server, wire-server-enterprise
- redis-ephemeral, rabbitmq, rabbitmq-external, databases-ephemeral
- fake-aws, fake-aws-s3, fake-aws-sqs, aws-ingress
- fluent-bit, kibana
- backoffice, calling-test, demo-smtp
- elasticsearch-curator, elasticsearch-external, elasticsearch-ephemeral
- minio-external, cassandra-external
- ingress-nginx-controller, nginx-ingress-services
- reaper, restund, k8ssandra-test-cluster, ldap-scim-bridge

## build.json Structure

```json
{
  "helmCharts": {
    "chart-name": {
      "repo": "https://s3-eu-west-1.amazonaws.com/public.wire.com/charts",
      "version": "5.24.0",
      "meta": {
        "commit": "e05bbb4e9e1e8c972fcd9a0ce8a92510d1d46019",
        "commitURL": "https://github.com/wireapp/wire-server/commit/e05bbb4e9e1e8c972fcd9a0ce8a92510d1d46019"
      }
    }
  }
}
```

**Metadata Fields:**
- `repo`: Helm chart repository URL
- `version`: Chart version
- `meta.commit`: Git commit SHA for this chart version
- `meta.commitURL`: Direct link to the commit on GitHub

## Workflow Chain

When `build.json` is updated on the `main` branch, a two-step workflow chain executes:

```
main: build.json updated
  ↓
sync-build-json.yml workflow triggers
  ↓
Syncs build.json to offline branch
  ↓
create-deploy-pr.yml workflow triggers
  ↓
Creates PR in wire-server-deploy
```

This ensures that production-ready versions on `main` are automatically propagated to the offline deployment configuration.

## Common Operations

### Updating Chart Versions

**Option 1: Update main branch (recommended for production versions)**
1. Modify `build.json` with new chart versions on `main` branch
2. Commit and push to `main`
3. Sync workflow automatically updates `offline` branch
4. PR creation workflow automatically creates a PR in wire-server-deploy

**Option 2: Update offline branch directly (for testing or offline-specific changes)**
1. Modify `build.json` with new chart versions on `offline` branch
2. Commit and push to `offline`
3. Workflow automatically creates a PR in wire-server-deploy

### Checking Workflow Status

```bash
# List recent workflow runs
gh run list --workflow=create-deploy-pr.yml --limit 5

# View details of a specific run
gh run view <run-id>

# View logs
gh run view <run-id> --log
```

### After Merging PRs in wire-server-deploy

The workflow uses different branch naming strategies:

| Trigger | Branch Name | Behavior |
|---------|-------------|----------|
| Automatic (sync from `main`) | `auto/wire-server-version-bump` | Reused for all automatic version bumps |
| Pinned version (workflow_dispatch) | `auto/pin-<branch>-<version>` | Unique per pinned version |

**For automatic updates (`auto/wire-server-version-bump`):**

After you merge a PR, the next trigger will:
1. Fetch the existing `auto/wire-server-version-bump` branch
2. Attempt to rebase it on master (which includes the merged changes)
3. If rebase succeeds: update the branch and create a new PR
4. If rebase fails: delete and recreate the branch from master

**Best practice:** Delete the `auto/wire-server-version-bump` branch after merging to ensure clean PR history:

```bash
# Delete the branch after merging
cd wire-server-deploy
git push origin --delete auto/wire-server-version-bump
```

Or enable "Automatically delete head branches" in GitHub repository settings.

**For pinned versions (`auto/pin-*`):**

Each pinned version gets its own unique branch (e.g., `auto/pin-offline-5.23.0`), so there's no conflict between different pinned versions.

## Troubleshooting

### Commit SHA Mismatch

If the commit SHA doesn't match the version after pinning:
- The workflow fetches the correct commit from wire-server releases
- If a tag is not found, it will only update the version (keeping existing commit metadata)
- Check that the wire-server release tag exists: `chart/<version>`

### PR Not Created

Check that:
1. The `ZEBOT_TOKEN` secret has proper permissions
2. The wire_build URL actually changed
3. The workflow completed successfully: `gh run view <run-id>`

