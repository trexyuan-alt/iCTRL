#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=$(mktemp -d)
trap 'rm -f "$out/prewarm-tests"; rmdir "$out"' EXIT
swiftc -swift-version 5 -parse-as-library \
 "$repo/iCTRLApp/Models/OwnerAuthorityStatus.swift" \
 "$repo/iCTRLApp/Models/OwnerControlClient.swift" \
 "$repo/iCTRLApp/Models/PrewarmClient.swift" \
 "$repo/Scripts/prewarm_test_support.swift" \
 "$repo/Scripts/prewarm_entrypoint_zero_phone.swift" -o "$out/prewarm-tests"
"$out/prewarm-tests"
swiftc -frontend -parse "$repo/iCTRLApp/Intents/PrewarmIntent.swift"
python3 "$repo/Scripts/prewarm_source_contract_test.py" -v