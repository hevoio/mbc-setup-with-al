# hevo-repo-generator

Automates the creation of new GitHub repositories at Hevo with standardized settings.

## How It Works

1. Create a new `repos/new-repo-details-N.json` file with repository configuration
2. Open a PR to the `dev` branch - CircleCI validates the JSON
3. Merge to `dev` - CircleCI creates the repository with proper settings (branch protection, webhooks, CODEOWNERS, CircleCI config)

## Quick Start

1. Find the highest numbered `repos/new-repo-details-N.json` file and increment N
2. Create your JSON file following the schema below
3. Open a PR to `dev` branch

## Repository Types

| Type | Use Case | Required Fields |
|------|----------|-----------------|
| `java` | Java services and libraries | `group-id`, `artefact-id`, `java-package-type` |
| `general` | Non-Java projects | Base fields only |
| `connector` | Hevo connector framework | `connector-id` |

## JSON Schema

### Java Repository

```json
{
  "repo-name": "my-java-service",
  "code-owners": "@github-user1 @github-user2",
  "repo-description": "Service description",
  "team": "dev",
  "jira-id": "H2-12345",
  "confluence-url": "https://hevodata.atlassian.net/wiki/...",
  "repo-config": {
    "type": "java",
    "group-id": "io.hevo",
    "artefact-id": "my-java-service",
    "java-package-type": "service"
  }
}
```

- `java-package-type`: `service` or `library`

### General (Non-Java) Repository

```json
{
  "repo-name": "my-project",
  "code-owners": "@github-user1 @github-user2",
  "repo-description": "Project description",
  "team": "dev",
  "jira-id": "H2-12345",
  "confluence-url": "https://hevodata.atlassian.net/wiki/...",
  "repo-config": {
    "type": "general"
  }
}
```

### Connector Repository

```json
{
  "repo-name": "salesforce-connector",
  "code-owners": "@github-user1 @github-user2",
  "repo-description": "Salesforce connector for Hevo",
  "team": "dev",
  "jira-id": "H2-12345",
  "confluence-url": "https://hevodata.atlassian.net/wiki/...",
  "repo-config": {
    "type": "connector",
    "connector-id": "salesforce"
  }
}
```

- `repo-name` **must** be `{connector-id}-connector`
- Uses `hevoio/connector-generator` as template

## Validation Rules

- Only new files allowed (no modifications to existing repo files)
- Single repo per PR
- All base fields are mandatory
- Java repos require: `group-id`, `artefact-id`, `java-package-type`
- Connector repos require: `connector-id` and matching repo-name

## Documentation

[Full documentation on Confluence](https://hevodata.atlassian.net/wiki/spaces/DEVX/pages/3299475488/New+repo+creation+at+Hevo)
