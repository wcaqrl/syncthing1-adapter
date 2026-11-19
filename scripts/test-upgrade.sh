#!/usr/bin/env bash
set -euo pipefail

candidate=${1-}
if (( $# == 0 )); then
  manifest="$(dirname -- "$0")/../lzc-manifest.yml"
  candidate=$(sed -n 's/^[[:blank:]]*# upstream:[[:blank:]]*//p' "$manifest")
fi
if [[ ! $candidate =~ ^ghcr\.io/syncthing/syncthing:([0-9]+\.[0-9]+\.[0-9]+)@sha256:[a-f0-9]{64}$ ]]; then
  echo 'Expected the selected official Syncthing image with an immutable digest.' >&2
  exit 2
fi
version="v${BASH_REMATCH[1]}"
# The public amd64 image has the same filesystem layers and effective root
# entrypoint as the old store image. CI can pull it without registry credentials.
legacy='ghcr.io/syncthing/syncthing:2.0.10@sha256:c9557fc2aac2ba31dedc57017f959ad86be45126a17046355843d973e09f5a3f'
temp=$(mktemp -d -t syncthing1-upgrade.XXXXXXXX)
prefix=$(basename "$temp")
container="$prefix-server"
fresh="$prefix-fresh"
persisted="$prefix-persisted"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$fresh" "$persisted" >/dev/null 2>&1 || true
  rm -r -- "$temp"
}
trap cleanup EXIT

for image in "$legacy" "$candidate"; do
  docker --config "$temp" pull --platform linux/amd64 "$image" >/dev/null
done
docker volume create "$fresh" >/dev/null
docker volume create "$persisted" >/dev/null

start() {
  local image=$1 volume=$2 group=$3
  docker run --detach --name "$container" --platform linux/amd64 \
    --network none --memory 256m --cpus 0.75 \
    --env PUID=0 --env "$group" \
    --mount "type=volume,src=$volume,dst=/var/syncthing" "$image" >/dev/null
  local deadline=$((SECONDS + 90))
  while (( SECONDS < deadline )); do
    if docker exec "$container" curl -fsS --max-time 2 http://127.0.0.1:8384/rest/noauth/health 2>/dev/null \
      | jq -e '.status == "OK"' >/dev/null; then
      return
    fi
    sleep 1
  done
  docker logs --tail 40 "$container" >&2
  echo 'Syncthing did not become healthy.' >&2
  return 1
}

stop() {
  docker stop --time 20 "$container" >/dev/null
  docker rm "$container" >/dev/null
}

api() {
  local endpoint=$1
  shift
  docker exec "$container" sh -ec '
    key=$(sed -n "s|.*<apikey>\([^<]*\)</apikey>.*|\1|p" "$STHOMEDIR/config.xml")
    test -n "$key"
    endpoint=$1; shift
    curl -fsS --max-time 8 -H "X-API-Key: $key" "$@" "http://127.0.0.1:8384/rest/$endpoint"
  ' sh "$endpoint" "$@"
}

check_version() {
  api system/version | jq -e --arg expected "$1" '.version == $expected' >/dev/null
}

check_gui() {
  docker exec "$container" curl -fsS --max-time 8 \
    -H 'Host: syncthing.example.test' http://127.0.0.1:8384/ \
    | grep -F 'ng-app="syncthing"' >/dev/null
}

start "$candidate" "$fresh" PGID=1000
check_version "$version"
check_gui
stop

# Use the legacy release's actual environment, including its ignored GUID key.
start "$legacy" "$persisted" GUID=0
check_version v2.0.10
identity=$(api system/status | jq -er '.myID | select(type == "string" and length > 0)')
fixture=/var/syncthing/adapter-fixture
docker exec "$container" sh -ec 'mkdir -p "$1"; printf "%s\n" existing-syncthing-data > "$1/example.txt"' sh "$fixture"
folder=$(api config/defaults/folder | jq --arg path "$fixture" '. + {id: "adapter-fixture", label: "Upgrade fixture", path: $path}')
api config/folders -X POST -H 'Content-Type: application/json' --data-binary "$folder" >/dev/null
api 'db/scan?folder=adapter-fixture' -X POST >/dev/null
api 'db/status?folder=adapter-fixture' | jq -e '.localFiles == 1' >/dev/null
stop

start "$candidate" "$persisted" PGID=1000
check_version "$version"
check_gui
api system/status | jq -e --arg identity "$identity" '.myID == $identity' >/dev/null
api config/folders/adapter-fixture | jq -e --arg path "$fixture" '.path == $path and .label == "Upgrade fixture"' >/dev/null
docker exec "$container" sh -ec 'test "$(cat "$1/example.txt")" = existing-syncthing-data' sh "$fixture"
api 'db/scan?folder=adapter-fixture' -X POST >/dev/null
api 'db/status?folder=adapter-fixture' | jq -e '.localFiles == 1' >/dev/null
echo "PASS: fresh ${version} GUI and v2.0.10 → ${version} upgrade preserved identity, configuration, data and index."
