#!/usr/bin/env bash
set -euo pipefail

config='/etc/tproxy-server/config.json'
failed=0

check() {
	local description=$1
	shift
	if "$@" >/dev/null 2>&1; then
		printf '[ok]   %s\n' "$description"
	else
		printf '[fail] %s\n' "$description" >&2
		failed=1
	fi
}

check_certificate() {
	openssl s_client -connect 127.0.0.1:443 -servername "$hostname" </dev/null 2>/dev/null \
		| openssl x509 -noout -checkhost "$hostname"
}

[[ -r "$config" ]] || {
	echo 'tproxy-server configuration was not found' >&2
	exit 1
}
hostname="$(sed -n 's/.*"public_hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)"

for service_name in caddy tproxy-firewall mtproxy tproxy-server; do
	check "${service_name} is active" systemctl is-active --quiet "$service_name"
done
check 'relay readiness endpoint' curl --fail --silent --max-time 5 http://127.0.0.1:8081/readyz
check 'HTTPS endpoint' curl --noproxy '*' --resolve "${hostname}:443:127.0.0.1" \
	--fail --silent --max-time 15 "https://${hostname}/"
check 'public certificate hostname' check_certificate

disconnects="$(journalctl -u mtproxy --since=-5min --no-pager 2>/dev/null \
	| grep -c 'Disconnected from RPC Middle-End' || true)"
if (( disconnects == 0 )); then
	printf '[ok]   MTProxy middle-end connection is stable\n'
else
	printf '[fail] MTProxy disconnected from RPC middle-end %d times in five minutes\n' "$disconnects" >&2
	failed=1
fi

exit "$failed"
