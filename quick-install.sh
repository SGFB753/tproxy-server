#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

repository_url="${TPROXY_REPOSITORY_URL:-https://github.com/SGFB753/tproxy-server.git}"
install_directory="${TPROXY_SOURCE_DIR:-/opt/tproxy-server}"
hostname=''
email=''
secret=''
site_dir=''
cover_site=''
base_path='none'
workers=1
max_connections=4096
assume_yes=0
skip_dns_check=0

usage() {
	cat <<'EOF'
Quick installer for Telegram WEB Proxy

Usage:
  sudo ./quick-install.sh [DOMAIN] [options]
  curl -fsSL RAW_SCRIPT_URL | sudo bash

Options:
  --hostname DOMAIN          Public lowercase DNS hostname
  --email EMAIL              Optional ACME contact email
  --secret HEX               16-byte MTProxy secret (generated when omitted)
  --cover-site DOMAIN        HTTPS masking site (a hostname or https:// URL)
  --site-dir DIR             Existing cover site containing index.html
  --base-path SLUG|none      Relay base path (default: none for mobile compatibility)
  --workers N                Official MTProxy workers (default: 1)
  --max-connections N        Connections per worker (default: 4096)
  --repository URL           Git repository used by curl/pipe installs
  --install-directory DIR    Source checkout (default: /opt/tproxy-server)
  --skip-dns-check           Continue when DNS does not match the public IPv4
  --yes                      Skip the final confirmation
  -h, --help                 Show this help
EOF
}

die() {
	echo "quick-install: $*" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--hostname) hostname="${2:-}"; shift 2 ;;
		--email) email="${2:-}"; shift 2 ;;
		--secret) secret="${2:-}"; shift 2 ;;
		--cover-site) cover_site="${2:-}"; shift 2 ;;
		--site-dir) site_dir="${2:-}"; shift 2 ;;
		--base-path) base_path="${2:-}"; shift 2 ;;
		--workers) workers="${2:-}"; shift 2 ;;
		--max-connections) max_connections="${2:-}"; shift 2 ;;
		--repository) repository_url="${2:-}"; shift 2 ;;
		--install-directory) install_directory="${2:-}"; shift 2 ;;
		--skip-dns-check) skip_dns_check=1; shift ;;
		--yes) assume_yes=1; shift ;;
		-h|--help) usage; exit 0 ;;
		--*) usage >&2; die "unknown option: $1" ;;
		*)
			[[ -z "$hostname" ]] || die 'only one positional hostname is accepted'
			hostname=$1
			shift
			;;
	esac
done

[[ $EUID -eq 0 ]] || die 'run as root'
[[ "$(uname -m)" == 'x86_64' ]] || die 'only x86_64 servers are supported by the official MTProxy backend'
[[ -r /etc/os-release ]] || die '/etc/os-release was not found'
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == debian || "${ID:-}" == ubuntu || "${ID_LIKE:-}" == *debian* ]] \
	|| die 'this quick installer supports Debian and Ubuntu'

if [[ -z "$hostname" ]]; then
	[[ -r /dev/tty ]] || die 'no terminal is available; pass the domain with --hostname'
	read -r -p 'Proxy domain (for example, proxy.example.com): ' hostname </dev/tty
fi
[[ "$hostname" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$hostname" == *.* ]] \
	|| die 'pass a lowercase DNS hostname with --hostname'
if [[ -n "$email" ]] && ! [[ "$email" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
	die 'invalid contact address passed with --email'
fi
[[ "$base_path" == none || "$base_path" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]] \
	|| die 'invalid base path'

if [[ -z "$secret" ]]; then
	[[ -r /dev/tty ]] || die 'no terminal is available; pass an existing key with --secret or use an interactive terminal'
	read -r -s -p 'Existing proxy key (32 hex, or 34 with dd; leave empty to generate): ' secret </dev/tty
	printf '\n' >/dev/tty
fi
if [[ -z "$cover_site" && -z "$site_dir" ]]; then
	[[ -r /dev/tty ]] || die 'no terminal is available; pass the masking site with --cover-site'
	read -r -p 'Masking site (for example, example.com): ' cover_site </dev/tty
fi

export DEBIAN_FRONTEND=noninteractive
if ! apt-get update; then
	# An old, malformed Ookla source was installed by some speedtest packages.
	# Disable only this exact invalid entry; leave all other repositories alone.
	bad_source='/etc/apt/sources.list.d/speedtest.list'
	if [[ -f "$bad_source" ]] && [[ "$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$bad_source")" == 'deb https://packagecloud.io jammy main' ]]; then
		install -d -m 0700 /root/apt-source-backups
		backup_source='/root/apt-source-backups/speedtest.list.disabled-by-tproxy'
		[[ ! -e "$backup_source" ]] || die 'APT source backup already exists; fix repositories manually'
		mv -- "$bad_source" "$backup_source"
		printf 'Disabled invalid APT source %s (backup: %s).\n' "$bad_source" "$backup_source" >&2
		apt-get update
	else
		die 'APT update failed; fix the repository error above and rerun the installer'
	fi
fi
apt-get install -y --no-install-recommends ca-certificates curl git openssl

if [[ -z "$secret" ]]; then
	secret="$(openssl rand -hex 16)"
fi
[[ "$secret" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || die 'secret must be 32 lowercase hex characters, optionally prefixed with dd'

if (( skip_dns_check == 0 )); then
	mapfile -t resolved_ips < <(getent ahostsv4 "$hostname" 2>/dev/null | awk '{print $1}' | sort -u)
	public_ip=''
	for probe in https://api.ipify.org https://ifconfig.co/ip https://icanhazip.com; do
		public_ip="$(curl --fail --silent --show-error --location --ipv4 --max-time 15 "$probe" 2>/dev/null | tr -d '[:space:]')" || true
		[[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
		public_ip=''
	done
	(( ${#resolved_ips[@]} > 0 )) || die "${hostname} has no IPv4 record"
	if [[ -z "$public_ip" ]]; then
		printf 'WARNING: could not determine this server outbound IPv4; continuing with DNS address %s.\n' "${resolved_ips[*]}" >&2
	elif ! printf '%s\n' "${resolved_ips[@]}" | grep -Fxq "$public_ip"; then
		printf 'WARNING: %s resolves to %s, while this server uses %s for outbound traffic.\n' \
			"$hostname" "${resolved_ips[*]}" "$public_ip" >&2
		printf 'This is valid for servers behind NAT or with separate inbound/outbound addresses; continuing.\n' >&2
	fi
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P || true)"
if [[ -n "$script_directory" && -f "$script_directory/deploy/install.sh" ]]; then
	repository="$script_directory"
else
	if [[ -d "$install_directory/.git" ]]; then
		[[ -z "$(git -C "$install_directory" status --porcelain)" ]] \
			|| die "source checkout has local changes: ${install_directory}"
		git -C "$install_directory" fetch --prune origin
		remote_head="$(git -C "$install_directory" symbolic-ref --quiet --short refs/remotes/origin/HEAD)"
		[[ -n "$remote_head" ]] || die 'could not determine the repository default branch'
		git -C "$install_directory" merge --ff-only "$remote_head"
	else
		[[ ! -e "$install_directory" ]] || die "install directory exists and is not a Git checkout: ${install_directory}"
		git clone --depth=1 "$repository_url" "$install_directory"
	fi
	repository="$install_directory"
fi

if [[ -z "$site_dir" && -z "$cover_site" ]]; then
	site_dir='/srv/tproxy-quick-site'
	install -d -m 0755 "$site_dir"
	if [[ ! -f "$site_dir/index.html" ]]; then
		install -m 0644 "$repository/deploy/quick-site.html" "$site_dir/index.html"
	fi
fi

for required_port in 80 443; do
	if ss -lntH "sport = :${required_port}" | grep -q .; then
		listener="$(ss -lntpH "sport = :${required_port}" || true)"
		if [[ "$listener" != *'"caddy"'* ]]; then
			die "TCP port ${required_port} is already occupied: ${listener}. Stop the conflicting service and rerun."
		fi
	fi
done
if [[ -n "$site_dir" ]]; then
	[[ -f "$site_dir/index.html" ]] || die "cover site has no index.html: ${site_dir}"
fi

printf '\nHost:          %s\n' "$hostname"
printf 'Masking site:  %s\n' "${cover_site:-$site_dir}"
printf 'Base path:     %s\n' "$base_path"
printf 'Source:        %s\n\n' "$repository"
if (( assume_yes == 0 )); then
	[[ -r /dev/tty ]] || die 'no terminal is available; pass --yes for unattended installation'
	read -r -p 'Install Telegram WEB Proxy now? [y/N] ' confirmation </dev/tty
	[[ "$confirmation" == y || "$confirmation" == Y ]] || die 'cancelled'
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
	ufw allow 80/tcp
	ufw allow 443/tcp
fi

installer_arguments=(
	--hostname "$hostname"
	--base-path "$base_path"
	--mtproxy-workers "$workers"
	--mtproxy-max-connections "$max_connections"
)
if [[ -n "$cover_site" ]]; then
	installer_arguments+=(--cover-site "$cover_site")
else
	installer_arguments+=(--site-dir "$site_dir")
fi
if [[ -n "$email" ]]; then
	installer_arguments+=(--email "$email")
fi
printf '%s\n' "$secret" | "$repository/deploy/install.sh" "${installer_arguments[@]}"

printf '\nInstallation complete.\n'
/usr/local/sbin/tproxy-show-link
printf '\nRun this any time for diagnostics:\n  sudo tproxy-health-check\n'
