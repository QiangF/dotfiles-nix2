#!/usr/bin/env bash

set -e

response=$(curl -s -H "Authorization: Bearer $GITHUB_ACCESS_TOKEN_WAYBAR" https://api.github.com/notifications | jq -r '. | length')

count=$response

echo $count
