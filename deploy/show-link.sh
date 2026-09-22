#!/usr/bin/env bash
set -euo pipefail

config='/etc/tproxy-server/config.json'
profiles='/etc/tproxy-server/profiles.json'

[[ $EUID -eq 0 ]] || {
	echo 'run as root: sudo tproxy-show-link' >&2
	exit 1
}
[[ -r "$config" && -r "$profiles" ]] || {
	echo 'tproxy-server configuration was not found' >&2
	exit 1
}

hostname="$(sed -n 's/.*"public_hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)"
base_path="$(sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)"
secret="$(sed -n 's/.*"secret"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$profiles" | head -n1)"

[[ "$hostname" =~ ^[a-z0-9.-]+$ ]] || {
	echo 'invalid public hostname in the configuration' >&2
	exit 1
}
[[ "$secret" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || {
	echo 'unsupported proxy secret in the configuration' >&2
	exit 1
}

client_address="$hostname"
client_secret="$secret"
if [[ -n "$base_path" ]]; then
	client_address="${hostname}/${base_path}"
	client_secret="$({
		printf '\x70'
		# The value is constrained to lowercase hexadecimal above.
		# shellcheck disable=SC2059
		printf "$(printf %s "$secret" | sed 's/../\\x&/g')"
	} | base64 | tr '+/' '-_' | tr -d '=\n')"
fi

encoded_address="${client_address//\//%2F}"
printf 'Proxy server: %s\n' "$client_address"
printf 'Proxy secret: %s\n' "$client_secret"
printf 'HTTPS link:   https://t.me/webproxy?server=%s&secret=%s\n' "$encoded_address" "$client_secret"
printf 'Direct link:  tg://webproxy?server=%s&secret=%s\n' "$encoded_address" "$client_secret"
