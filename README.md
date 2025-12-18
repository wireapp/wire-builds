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
1. Workflow fetches the correct commit SHA from wire-server releases
2. Updates all charts that match the current wire-server version to the pinned version
3. Updates both version numbers and commit metadata
4. Creates a new commit and pushes to the branch
5. Triggers PR creation to wire-server-deploy

**Available versions:** 5.24.0 down to 5.5.0

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

### Adding New Wire-Server Versions

When a new wire-server version is released, edit [.github/workflows/create-deploy-pr.yml](.github/workflows/create-deploy-pr.yml) and add the version to the `options` list:

```yaml
wire_server_version:
  description: 'Pin wire-server version'
  required: false
  type: choice
  options:
    - 'none'
    - '5.25.0'  # New version
    - '5.24.0'
    - '5.23.0'
    # ... rest of versions
```

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

The workflow reuses the same branch name (`auto/bump-wire-build`) for all PRs. After you merge a PR:

**What happens on next trigger:**
1. Workflow fetches the existing `auto/bump-wire-build` branch
2. Attempts to rebase it on master (which includes the merged changes)
3. If rebase succeeds: updates the branch and creates a new PR
4. If rebase fails: deletes and recreates the branch from master

**Best practice:**
Delete the `auto/bump-wire-build` branch in wire-server-deploy after merging to ensure clean PR history:

```bash
# Delete the branch after merging
cd wire-server-deploy
git push origin --delete auto/bump-wire-build
```

Or use the GitHub UI to enable "Automatically delete head branches" in repository settings.

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

