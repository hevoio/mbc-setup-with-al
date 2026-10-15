#!/bin/bash
# set -x
UNSET_FIELDS=()

# Determine how to get changed files based on current branch
current_branch=$(git rev-parse --abbrev-ref HEAD)

if [[ "$current_branch" == "dev" ]]; then
    # On dev branch after merge - check last commit (squash merge)
    all_changed_files=$(git diff-tree --no-commit-id --name-only -r HEAD)
else
    # On feature branch - compare against dev branch
    git fetch origin dev --quiet 2>/dev/null || true
    all_changed_files=$(git diff --name-only origin/dev...HEAD 2>/dev/null || git diff-tree --no-commit-id --name-only -r HEAD)
fi

# Filter to only files in repos/ folder matching the expected pattern
new_repo_details_file=$(echo "$all_changed_files" | grep -E '^repos/.*\.json$' | head -1)

# If no repo details file changed, skip validation
if [[ -z "$new_repo_details_file" ]]; then
    echo "No new repo details file found in repos/ folder. Skipping validation."
    echo "export skip_repo_creation=true" >> $BASH_ENV
    exit 0
fi

# Check if the file is newly added or modified
# On feature branches, warn if modifying an existing file but allow it
if [[ "$current_branch" != "dev" ]]; then
    if git show origin/dev:"${new_repo_details_file}" &>/dev/null; then
        echo "Warning: ${new_repo_details_file} already exists in dev branch. This PR modifies an existing repo config."
        echo "export is_repo_modification=true" >> $BASH_ENV
    fi
fi

# Validate only one repo file is being added
repo_files_count=$(echo "$all_changed_files" | grep -cE '^repos/.*\.json$')
if [[ "$repo_files_count" -gt 1 ]]; then
    echo "Error: Multiple repo details files found. Only one new repo can be created per PR."
    exit 1
fi

echo "Validating: ${new_repo_details_file}"

# Read JSON file once
json_content=$(cat "${new_repo_details_file}")

# Helper function to check if value is missing (null or empty)
is_missing() {
    [[ -z "$1" || "$1" == "null" ]]
}

# Parse all required fields
repo_name=$(echo "$json_content" | jq -r '.["repo-name"]')
repo_description=$(echo "$json_content" | jq -r '.["repo-description"]')
team=$(echo "$json_content" | jq -r '.team')
jira_id=$(echo "$json_content" | jq -r '.["jira-id"]')
confluence_url=$(echo "$json_content" | jq -r '.["confluence-url"]')
code_owners=$(echo "$json_content" | jq -r '.["code-owners"]')
repo_type=$(echo "$json_content" | jq -r '.["repo-config"].type')
repo_full_name="hevoio/${repo_name}"

# Validate required fields
required_fields="repo_name repo_description team jira_id confluence_url code_owners repo_type"
for field in $required_fields; do
    if is_missing "${!field}"; then
        UNSET_FIELDS+=("$field")
    fi
done

# Java-specific fields
if [[ "$repo_type" == "java" ]]; then
    group_id=$(echo "$json_content" | jq -r '.["repo-config"]["group-id"]')
    artefact_id=$(echo "$json_content" | jq -r '.["repo-config"]["artefact-id"]')
    java_package_type=$(echo "$json_content" | jq -r '.["repo-config"]["java-package-type"]')

    is_missing "$group_id" && UNSET_FIELDS+=("group-id")
    is_missing "$artefact_id" && UNSET_FIELDS+=("artefact-id")
    is_missing "$java_package_type" && UNSET_FIELDS+=("java-package-type")

    # Export Java-specific vars
    echo "export group_id=${group_id}" >> $BASH_ENV
    echo "export artefact_id=${artefact_id}" >> $BASH_ENV
    echo "export java_package_type=${java_package_type}" >> $BASH_ENV
fi

# Connector-specific validation
if [[ "$repo_type" == "connector" ]]; then
    connector_id=$(echo "$json_content" | jq -r '.["repo-config"]["connector-id"]')

    is_missing "$connector_id" && UNSET_FIELDS+=("connector-id")

    # Validate repo-name matches {connector_id}-connector
    expected_repo_name="${connector_id}-connector"
    if [[ "$repo_name" != "$expected_repo_name" ]]; then
        echo "Error: For connector type, repo-name must be '{connector_id}-connector'. Expected: ${expected_repo_name}, Got: ${repo_name}"
        exit 1
    fi

    # Export connector-specific vars
    echo "export connector_id=${connector_id}" >> $BASH_ENV
fi

# Check for missing fields and exit if any
if [[ ${#UNSET_FIELDS[@]} -gt 0 ]]; then
    echo "Error: Missing required fields: ${UNSET_FIELDS[*]}"
    exit 1
fi

# Validate description length (GitHub API limit is 350 characters)
desc_length=${#repo_description}
if [[ "$desc_length" -gt 350 ]]; then
    echo "Error: repo-description is ${desc_length} characters. GitHub limits descriptions to 350 characters."
    exit 1
fi

echo "Validation successful for ${new_repo_details_file}"

# Export environment variables for downstream jobs
cat >> $BASH_ENV << EOF
export new_repo_details_file=${new_repo_details_file}
export repo_name=${repo_name}
export repo_full_name=${repo_full_name}
export repo_description="${repo_description}"
export team=${team}
export jira_id=${jira_id}
export confluence_url=${confluence_url}
export code_owners="${code_owners}"
export repo_type=${repo_type}
EOF