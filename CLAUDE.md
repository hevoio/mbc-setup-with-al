# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This repository automates the creation of new GitHub repositories at Hevo. When a JSON configuration file is merged to the `dev` branch, CircleCI automatically provisions a new repository with standardized settings.

## How It Works

1. Create a new `repos/new-repo-details-N.json` file with repository configuration
2. Open a PR to the `dev` branch - CircleCI validates the JSON
3. Merge to `dev` - CircleCI creates the repository with proper settings (branch protection, webhooks, CODEOWNERS, CircleCI config)

## Adding a New Repository

1. Find the highest numbered `repos/new-repo-details-N.json` file and increment N
2. Create your JSON file following the schema below
3. Open a PR to `dev` branch

## Repository Configuration JSON Schema

Files must be placed in `repos/` directory with name pattern `new-repo-details-{N}.json`:

```json
{
  "repo-name": "my-service",
  "code-owners": "@username1 @username2",
  "repo-description": "Service description",
  "team": "dev",
  "jira-id": "H2-12345",
  "confluence-url": "https://hevodata.atlassian.net/wiki/...",
  "repo-config": {
    "type": "java|general|connector",
    "group-id": "io.hevo",           // Java only
    "artefact-id": "my-service",     // Java only
    "java-package-type": "service|library",  // Java only
    "connector-id": "salesforce"     // Connector only
  }
}
```

- `type: "java"` - requires `group-id`, `artefact-id`, and `java-package-type` (service or library)
- `type: "general"` - for non-Java projects (only base fields required)
- `type: "connector"` - requires `connector-id`. Uses `hevoio/connector-generator` as template. **repo-name must be `{connector-id}-connector`**
- Java `java-package-type: "service"` uses `java-config-service.yml`, `java-package-type: "library"` uses `java-config-library.yml`

## Creating a Connector Repository

Connector repos are used for Hevo's connector framework. They use the `connector-generator` template which includes pre-configured CircleCI pipelines and connector scaffolding.

### Steps

1. Find the highest numbered `repos/new-repo-details-N.json` file and increment N
2. Create your JSON file with the connector configuration (see example below)
3. Open a PR to `dev` branch
4. After merge, the repo will be created at `hevoio/{connector-id}-connector`

### Example Configuration

For a Salesforce connector (`repos/new-repo-details-71.json`):

```json
{
  "repo-name": "salesforce-connector",
  "code-owners": "@developer1 @developer2",
  "repo-description": "Salesforce connector for Hevo",
  "team": "dev",
  "jira-id": "H2-12345",
  "confluence-url": "https://hevodata.atlassian.net/wiki/spaces/DEV/pages/...",
  "repo-config": {
    "type": "connector",
    "connector-id": "salesforce"
  }
}
```

### Naming Convention

- `connector-id`: The identifier for your connector (e.g., `salesforce`, `hubspot`, `stripe`)
- `repo-name`: Must follow the pattern `{connector-id}-connector` (e.g., `salesforce-connector`)

### What Gets Created

- Repository at `github.com/hevoio/{connector-id}-connector`
- Uses `hevoio/connector-generator` as template
- CODEOWNERS file updated with specified owners
- Branch protection rules on `dev` and `release/*` branches
- Homer webhook configured

## Key Files

- `.circleci/config.yml` - Main pipeline: validates JSON on PRs, creates repos on merge to dev
- `.circleci/validate-json.sh` - Validates required fields in repo details JSON
- `configs/` - Templates and configuration files applied to new repos:
  - `base-circleci-configs/` - CircleCI templates (java-config-service.yml, java-config-library.yml, non-java-config.yml)
  - `rules.json` - Branch protection rules
  - `hook.json` - GitHub webhook configuration
  - `repo-query.ql` - GraphQL queries for GitHub API branch protection

## Validation Rules

The `.circleci/validate-json.sh` script enforces these rules on every PR:

1. **Only new files allowed** - Modifications to existing repo files are rejected
2. **Single repo per PR** - Only one `new-repo-details-N.json` file can be added per PR
3. **Required fields** - All base fields must be present (repo-name, code-owners, repo-description, team, jira-id, confluence-url, repo-config.type)
4. **Java-specific fields** - If `type: "java"`, requires group-id, artefact-id, and java-package-type
5. **Connector-specific fields** - If `type: "connector"`, requires `connector-id` and repo-name must be `{connector-id}-connector`
6. **Compares against dev branch** - Validates all changes in PR, not just the last commit