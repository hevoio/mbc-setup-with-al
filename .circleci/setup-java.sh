#!/bin/bash
# Setup java and maven if repo type is java

if [[ "java" != $repo_type ]]; then
    exit 0
fi

echo "Java type repo configuration found"
curl -s "https://get.sdkman.io" | bash
echo sdkman_auto_answer=true > $HOME/.sdkman/etc/config
echo sdkman_auto_selfupdate=true >> $HOME/.sdkman/etc/config
source "$HOME/.sdkman/bin/sdkman-init.sh"
echo 'export SDKMAN_DIR="$HOME/.sdkman"' >> $BASH_ENV
echo 'source "$HOME/.sdkman/bin/sdkman-init.sh"' >> $BASH_ENV
cp configs/.sdkmanrc .
sdk env install
