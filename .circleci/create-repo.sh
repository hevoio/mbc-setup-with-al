#!/bin/bash
# Create new repo using template and configure settings

# Select template based on repo type
if [[ "connector" == $repo_type ]]; then
    gh repo create ${repo_full_name} -p hevoio/connector-generator --private -d "${repo_description}"
else
    gh repo create ${repo_full_name} -p hevoio/hevo-repo-generator --private -d "${repo_description}"
fi

# Setup rules for new repo
# Add teams
gh api --method PUT /orgs/hevoio/teams/infra/repos/${repo_full_name} -f permission='push'
gh api --method PUT /orgs/hevoio/teams/dev/repos/${repo_full_name} -f permission='push'
gh api --method PUT /orgs/hevoio/teams/l_soc/repos/${repo_full_name} -f permission='push'

if [[ "$repo_type" == "connector" ]]; then
    gh api --method PUT "/orgs/hevoio/teams/support-team/repos/${repo_full_name}" -f permission='push'
fi

# Setup dev branch rules
gh repo edit ${repo_full_name} --default-branch dev --delete-branch-on-merge --enable-merge-commit=false --enable-rebase-merge --enable-squash-merge
gh api --method PATCH /repos/${repo_full_name} -f squash_merge_commit_title='PR_TITLE' -f squash_merge_commit_message='COMMIT_MESSAGES'

# Setup homer hook
gh api repos/${repo_full_name}/hooks --input configs/hook.json

# Setup branch restrictions
repository_id=$(gh api graphql \
    -f query="$(cat configs/repo-query.ql)" \
    -f operationName=getRepositoryId \
    -F owner=hevoio -F repo=${repo_name} | jq -r '.data .repository .id')
gh api graphql \
    -f query="$(cat configs/repo-query.ql)" \
    -f operationName=addBranchProtection \
    -F repositoryId=${repository_id} -F branchPattern=dev
gh api graphql \
    -f query="$(cat configs/repo-query.ql)" \
    -f operationName=addBranchProtection \
    -F repositoryId=${repository_id} -F branchPattern=release/*

# Make 91pratyush as admin
gh api --method PUT /repos/${repo_full_name}/collaborators/91pratyush -f permission='admin'
