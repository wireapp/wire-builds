# Wire Builds (Offline Branch)

This repository manages Wire Server build configurations for offline deployments and automates deployment to the wire-server-deploy repository.

## Overview

- `build.json`: Helm chart versions and metadata for all Wire components
- `.github/workflows/create-deploy-pr.yml`: Automation workflow for PR creation

## Workflow

The workflow automatically creates or updates pull requests in the [wire-server-deploy](https://github.com/wireapp/wire-server-deploy) repository.

### Triggers

1. **Push to `offline` branch** when `build.json` is modified
2. **Pull requests** that modify `build.json`
3. **Manual dispatch (CLI)** with optional wire-server version pinning

### Features

#### Automatic PR Creation

When `build.json` is updated on the `offline` branch, the workflow:
1. Updates the wire-build URL in `wire-server-deploy/offline/tasks/proc_pull_charts.sh`
2. Creates/updates a PR in wire-server-deploy with version details and commit links

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

## Common Operations

### Updating Chart Versions

1. Modify `build.json` with new chart versions
2. Commit and push to the `offline` branch
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
| Automatic (push to `build.json`) | `auto/bump-wire-build` | Reused for all automatic updates |
| Pinned version (workflow_dispatch) | `auto/pin-<branch>-<version>` | Unique per pinned version |

**For automatic updates (`auto/bump-wire-build`):**

After you merge a PR, the next trigger will:
1. Fetch the existing `auto/bump-wire-build` branch
2. Attempt to rebase it on master (which includes the merged changes)
3. If rebase succeeds: update the branch and create a new PR
4. If rebase fails: delete and recreate the branch from master

**Best practice:** Delete the `auto/bump-wire-build` branch after merging to ensure clean PR history:

```bash
# Delete the branch after merging
cd wire-server-deploy
git push origin --delete auto/bump-wire-build
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

