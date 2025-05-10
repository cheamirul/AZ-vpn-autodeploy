#!/bin/bash

RESOURCE_GROUP="vpn-rg-tmp"

echo "This will delete ALL resources in $RESOURCE_GROUP"
read -p "Are you sure? (y/n): " confirm

if [[ "$confirm" == "y" ]]; then
    az group delete --name $RESOURCE_GROUP --yes --no-wait
    echo "✅ Deletion started. May take a minute to fully clean up."
else
    echo "❌ Canceled."
fi
