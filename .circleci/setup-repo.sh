#!/bin/bash
# Setup type specific repo configuration
set -e

slack_message="*New Repo creation status :*\n"
slack_message+="*Requestor:* ${CIRCLE_USERNAME}\n"
slack_message+="*New repo URL:* https://github.com/${repo_full_name}\n"

echo "Checking if repo ${repo_full_name} is ready..."

max_retries=10
retry_count=0
sleep_interval=30

until gh repo view ${repo_full_name} >/dev/null 2>&1; do
  retry_count=$((retry_count + 1))

  if [ $retry_count -ge $max_retries ]; then
    echo "Repo ${repo_full_name} is not available after $max_retries attempts. Exiting."
    exit 1
  fi

  echo "Repo not ready yet. Retrying in ${sleep_interval}s... (Attempt ${retry_count}/${max_retries})"
  sleep ${sleep_interval}
done

echo "Repo is ready. Cloning..."
gh repo clone ${repo_full_name}
cd ${repo_name}

if [[ "connector" == $repo_type ]]; then
    # Connector type - template already has proper setup
    # Just update CODEOWNERS
    echo "*    ${code_owners}" > CODEOWNERS
    git add .
    git commit -m "feat: sets up repo with codeowners" || true
    git push origin dev
else
    # Update README.md
    sed -i "1s|^|Confluence URL - ${confluence_url}\n|" configs/README.md
    sed -i "1s|^|# ${repo_name}\n\n|" configs/README.md
    cp configs/README.md .

    # Update codeowners
    echo "*    ${code_owners}" > CODEOWNERS

    # Copy git hooks
    cp -r configs/bin .

    # Setup repo as per type
    mv .circleci/config.yml .circleci/create-repo-config.yml
    if [[ "java" == $repo_type ]]; then
        mvn install:install-file -Dfile=configs/hevo-java-archetype-1.0.0-SNAPSHOT.jar \
            -DgroupId=io.hevo -DartifactId=hevo-java-archetype -Dversion=1.0.0-SNAPSHOT -Dpackaging=jar
        mvn archetype:generate \
            -DarchetypeGroupId=io.hevo \
            -DarchetypeArtifactId=hevo-java-archetype \
            -DarchetypeVersion=1.0.0-SNAPSHOT \
            -DgroupId=${group_id} \
            -DartifactId=${artefact_id} \
            -DinteractiveMode=false -DarchetypeCatalog=local
        if [[ "service" == $java_package_type ]]; then
            sed -i "s/service_name_here/$artefact_id/g" configs/base-circleci-configs/java-config-service.yml
            mv configs/base-circleci-configs/java-config-service.yml .circleci/config.yml
        else
            mv configs/base-circleci-configs/java-config-library.yml .circleci/config.yml
        fi
    else
        mv configs/base-circleci-configs/non-java-config.yml .circleci/config.yml
    fi
    rm .circleci/create-repo-config.yml

    # Clean up files
    rm -rf configs
    rm .circleci/validate-json.sh
    rm -rf repos
    mv -f ${artefact_id}/{.,}* . || true
    git add .
    git commit -m "feat: sets up repo with circleci config"
    git push origin dev
fi

# Notify on slack
curl --silent \
    -X POST \
    -H "Accept: application/json" \
    "${DEVX_NOTIFICATION_SLACK_URL}" \
    -d '{"text": "'"${slack_message}"'"}'

# Notify Homer that repository creation is complete
curl --silent \
    -X POST \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${HOMER_API_KEY}" \
    "${HOMER_BASE_URL}/release/api/repositories/${repo_name}/status" \
    -d '{"status": "done"}'
