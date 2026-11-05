#!/usr/bin/env bash
# Configure the read-only deploy key CI uses to check out the private SDK. Run once by the repo owner:
# generates a one-off ed25519 key, adds the public half to tianting-sdk-swift as a read-only deploy key, stores the private
# half as this repo's Actions secret TIANTING_SDK_SWIFT_DEPLOY_KEY, then deletes the local key files.
# The private key only goes through stdin; it is never printed.
set -euo pipefail
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
ssh-keygen -q -t ed25519 -N '' -C tianting-ios-ci -f "$dir/key"
gh repo deploy-key add "$dir/key.pub" -R leetonny001/tianting-sdk-swift -t tianting-ios-ci
gh secret set TIANTING_SDK_SWIFT_DEPLOY_KEY -R leetonny001/tianting-ios < "$dir/key"
echo "done: read-only deploy key added to tianting-sdk-swift, secret set on tianting-ios, local key removed."
