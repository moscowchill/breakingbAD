#!/usr/bin/env bash
set -euo pipefail

# ── breakingbAD Lab Management ──────────────────────────────────────────────
# Manages the AD pentesting lab from WSL2 targeting VMware Workstation on the
# Windows host.  Handles socat tunnels, Vagrant VMs, and Ansible playbooks.
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_DIR="$SCRIPT_DIR/vagrant"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"
VENV_DIR="$ANSIBLE_DIR/.venv"
UTILITY_PORT=9922

# VM definitions: name -> expected static IP
declare -A VM_IPS=(
    [dc01]="192.168.100.10"
    [srv01]="192.168.100.20"
    [srv02]="192.168.100.21"
)

# Vulnerability catalog (ID | Name)
declare -A VULN_NAMES=(
    [01]="ESC8 (ADCS Web Enrollment)"
    [02]="NTLMv1"
    [03]="WebClient"
    [04]="GPO"
    [05]="IPv6"
    [06]="LLMNR, NBT-NS & mDNS"
    [07]="Password in user description"
    [08]="Kerberoasting"
    [09]="ASREProasting"
    [10]="ESC1"
    [11]="Anonymous Logon (Pre-Win2000)"
    [12]="Shared local admin password"
)

# IDs that support trigger action
TRIGGER_IDS="05 06"

# ── Helpers ─────────────────────────────────────────────────────────────────

red()    { printf '\033[0;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[0;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[0;33m%s\033[0m\n' "$*"; }
cyan()   { printf '\033[0;36m%s\033[0m\n' "$*"; }
bold()   { printf '\033[1m%s\033[0m\n' "$*"; }
dim()    { printf '\033[0;90m%s\033[0m\n' "$*"; }

win_host_ip() {
    ip route show default | awk '{print $3}'
}

# ── Socat Tunnel Management ────────────────────────────────────────────────
# Forwards local ports to the Windows host so Vagrant/VMware Utility traffic
# (which binds to Windows 127.0.0.1) is reachable from WSL2.

socat_forward() {
    local port="$1"
    local host
    host="$(win_host_ip)"
    if ss -tlnp 2>/dev/null | grep -q ":${port}.*socat"; then
        return 0  # already running
    fi
    socat TCP4-LISTEN:"${port}",fork,reuseaddr,bind=127.0.0.1 \
          TCP4:"${host}":"${port}" &disown 2>/dev/null
}

socat_stop_all() {
    pkill -f "socat.*TCP4-LISTEN:" 2>/dev/null || true
    sleep 0.5
}

socat_list() {
    ss -tlnp 2>/dev/null | grep socat | awk '{print $4}' | sed 's/127.0.0.1:/  port /'
}

# Start the VMware Utility tunnel (always needed)
tunnel_ensure_utility() {
    socat_forward "$UTILITY_PORT"
}

# Detect Vagrant forwarded ports for a VM and set up socat tunnels.
# Also outputs any NEW Windows portproxy commands needed.
tunnel_forward_vagrant_ports() {
    local vm="${1:-}"
    local host
    host="$(win_host_ip)"
    local new_ports=()

    if [[ -z "$vm" ]]; then
        # Forward for all running VMs
        for v in dc01 srv01 srv02; do
            tunnel_forward_vagrant_ports "$v" 2>/dev/null || true
        done
        return
    fi

    # Get forwarded ports from vagrant
    local port_output
    port_output=$(cd "$VAGRANT_DIR" && vagrant port "$vm" 2>/dev/null) || return 0

    while IFS= read -r line; do
        # Parse lines like "  5985 (guest) => 55985 (host)"
        local host_port
        host_port=$(echo "$line" | grep -oP '=> \K\d+' 2>/dev/null) || continue
        [[ -z "$host_port" ]] && continue

        if ! ss -tlnp 2>/dev/null | grep -q ":${host_port}.*socat"; then
            socat_forward "$host_port"
            new_ports+=("$host_port")
        fi
    done <<< "$port_output"

    if [[ ${#new_ports[@]} -gt 0 ]]; then
        yellow "New socat tunnels for $vm: ${new_ports[*]}"
        # Check if Windows portproxy exists for these ports
        local existing_proxies
        existing_proxies=$(powershell.exe -Command "netsh interface portproxy show v4tov4" 2>/dev/null || echo "")
        local missing=()
        for p in "${new_ports[@]}"; do
            if ! echo "$existing_proxies" | grep -q "$p"; then
                missing+=("$p")
            fi
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo
            yellow "Run in elevated PowerShell to add port proxies:"
            for p in "${missing[@]}"; do
                echo "  netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$p connectaddress=127.0.0.1 connectport=$p"
            done
            echo "  New-NetFirewallRule -DisplayName \"Vagrant $vm (WSL2)\" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $(IFS=,; echo "${missing[*]}") -Profile Any"
            echo
        fi
    fi
}

cmd_tunnel() {
    case "${1:-start}" in
        start)
            tunnel_ensure_utility
            tunnel_forward_vagrant_ports
            green "All tunnels active:"
            socat_list
            ;;
        stop)
            socat_stop_all
            green "All tunnels stopped"
            ;;
        status)
            local tunnels
            tunnels=$(socat_list)
            if [[ -n "$tunnels" ]]; then
                green "Active socat tunnels (-> $(win_host_ip)):"
                echo "$tunnels"
            else
                yellow "No tunnels running"
            fi
            ;;
        *) red "Usage: $0 tunnel [start|stop|status]"; return 1 ;;
    esac
}

# ── Vagrant Helpers ────────────────────────────────────────────────────────

vagrant_cmd() {
    tunnel_ensure_utility
    (cd "$VAGRANT_DIR" && vagrant "$@")
}

# ── Ansible Helpers ────────────────────────────────────────────────────────

activate_venv() {
    if [[ -f "$VENV_DIR/bin/activate" ]]; then
        # shellcheck disable=SC1091
        source "$VENV_DIR/bin/activate"
    else
        red "Python venv not found at $VENV_DIR"
        red "Create it:  python3 -m venv $VENV_DIR && source $VENV_DIR/bin/activate && pip install -r $SCRIPT_DIR/python/requirements.txt"
        return 1
    fi
}

ansible_cmd() {
    activate_venv
    (cd "$ANSIBLE_DIR" && ansible-playbook -i inventory.yml "$@")
}

# ── Commands ───────────────────────────────────────────────────────────────

cmd_up() {
    bold "Starting breakingbAD lab..."
    vagrant_cmd up "$@"
    echo
    cyan "Setting up port tunnels for running VMs..."
    tunnel_forward_vagrant_ports
}

cmd_halt() {
    bold "Halting VMs..."
    vagrant_cmd halt -f "$@"
}

cmd_destroy() {
    bold "Destroying VMs..."
    vagrant_cmd destroy "$@"
    echo
    cyan "Stopping tunnels..."
    socat_stop_all
    green "VMs destroyed and tunnels stopped"
}

cmd_status() {
    bold "breakingbAD Lab Status"
    echo

    # Tunnel info
    local tunnels
    tunnels=$(socat_list 2>/dev/null)
    if [[ -n "$tunnels" ]]; then
        green "Socat tunnels (-> $(win_host_ip)):"
        echo "$tunnels"
    else
        yellow "No socat tunnels running"
    fi
    echo

    # VM info
    cyan "Virtual Machines:"
    printf "  %-8s %-14s %-16s %s\n" "Name" "State" "Static IP" "Role"
    printf "  %-8s %-14s %-16s %s\n" "────" "─────" "─────────" "────"

    local vagrant_status
    vagrant_status=$(cd "$VAGRANT_DIR" && vagrant status 2>/dev/null) || vagrant_status=""

    for vm in dc01 srv01 srv02; do
        local state="unknown"
        if echo "$vagrant_status" | grep -q "$vm.*running"; then
            state="\033[0;32mrunning\033[0m"
        elif echo "$vagrant_status" | grep -q "$vm.*not created"; then
            state="\033[0;90mnot created\033[0m"
        elif echo "$vagrant_status" | grep -q "$vm.*poweroff\|$vm.*not running"; then
            state="\033[0;31mstopped\033[0m"
        elif echo "$vagrant_status" | grep -q "$vm.*suspended"; then
            state="\033[0;33msuspended\033[0m"
        fi

        local role="Server"
        [[ "$vm" == "dc01" ]] && role="Domain Controller"

        printf "  %-8s %-23b %-16s %s\n" "$vm" "$state" "${VM_IPS[$vm]}" "$role"
    done
    echo

    # Network info
    cyan "Network:"
    echo "  Domain:  breakingbad.local"
    echo "  Subnet:  192.168.100.0/24 (vmnet8)"
    echo "  DNS:     ${VM_IPS[dc01]} (dc01)"
    echo

    # Port forwards (if VMs are running)
    if echo "$vagrant_status" | grep -q "running"; then
        cyan "Forwarded Ports:"
        for vm in dc01 srv01 srv02; do
            if echo "$vagrant_status" | grep -q "$vm.*running"; then
                local ports
                ports=$(cd "$VAGRANT_DIR" && vagrant port "$vm" 2>/dev/null | grep "=>" || true)
                if [[ -n "$ports" ]]; then
                    echo "  $vm:"
                    echo "$ports" | sed 's/^/    /'
                fi
            fi
        done
        echo
    fi
}

cmd_build() {
    bold "Running base build (AD domain, DNS, OUs, ADCS)..."
    ansible_cmd playbooks/base_build/base_build.yml "$@"
}

cmd_vuln() {
    local subcmd="${1:-list}"
    shift || true

    case "$subcmd" in
        list)
            bold "Vulnerabilities:"
            printf "  %-4s %-40s %s\n" "ID" "Name" "Trigger?"
            printf "  %-4s %-40s %s\n" "──" "────" "────────"
            for id in $(echo "${!VULN_NAMES[@]}" | tr ' ' '\n' | sort); do
                local has_trigger="No"
                [[ " $TRIGGER_IDS " == *" $id "* ]] && has_trigger="Yes"
                printf "  %-4s %-40s %s\n" "$id" "${VULN_NAMES[$id]}" "$has_trigger"
            done
            echo
            cyan "Usage: $0 vuln <enable|disable|trigger> <ID|all>"
            ;;
        enable|disable)
            local target="${1:-}"
            if [[ -z "$target" ]]; then
                red "Usage: $0 vuln $subcmd <ID|all>"
                return 1
            fi
            if [[ "$target" == "all" ]]; then
                bold "${subcmd^}ing ALL vulnerabilities..."
                ansible_cmd playbooks/vulnerabilities/vulnerabilities.yml \
                    --extra-vars "action=$subcmd" "${@:2}"
            else
                local padded
                padded=$(printf "%02d" "$target")
                if [[ -z "${VULN_NAMES[$padded]:-}" ]]; then
                    red "Unknown vulnerability ID: $target"
                    return 1
                fi
                bold "${subcmd^}ing vuln $padded: ${VULN_NAMES[$padded]}..."
                ansible_cmd "playbooks/vulnerabilities/${padded}.yml" \
                    --extra-vars "action=$subcmd" "${@:2}"
            fi
            ;;
        trigger)
            local target="${1:-}"
            if [[ -z "$target" ]]; then
                red "Usage: $0 vuln trigger <ID>"
                return 1
            fi
            local padded
            padded=$(printf "%02d" "$target")
            if [[ " $TRIGGER_IDS " != *" $padded "* ]]; then
                red "Vulnerability $padded does not support trigger (only: $TRIGGER_IDS)"
                return 1
            fi
            bold "Triggering vuln $padded: ${VULN_NAMES[$padded]}..."
            ansible_cmd "playbooks/vulnerabilities/${padded}.yml" \
                --extra-vars "action=trigger" "${@:2}"
            ;;
        *)
            red "Unknown vuln subcommand: $subcmd"
            red "Usage: $0 vuln <list|enable|disable|trigger> [ID|all]"
            return 1
            ;;
    esac
}

cmd_deploy() {
    bold "Full deployment: up -> build -> enable all vulns"
    echo
    cmd_up
    echo
    cmd_build
    echo
    bold "Enabling all vulnerabilities..."
    cmd_vuln enable all
    echo
    green "Lab deployment complete!"
}

cmd_setup_windows() {
    bold "Windows Host Setup (run in elevated PowerShell)"
    echo
    cyan "# 1. Port proxy for VMware Utility"
    echo "netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=9922 connectaddress=127.0.0.1 connectport=9922"
    echo
    cyan "# 2. IP forwarding between WSL and VMnet8"
    local wsl_idx vmnet8_idx
    wsl_idx=$(powershell.exe -Command "(Get-NetAdapter -Name '*WSL*').InterfaceIndex" 2>/dev/null | tr -d '\r\n' || echo "?")
    vmnet8_idx=$(powershell.exe -Command "(Get-NetAdapter -Name '*VMnet8*').InterfaceIndex" 2>/dev/null | tr -d '\r\n' || echo "?")
    echo "Set-NetIPInterface -InterfaceIndex $wsl_idx -Forwarding Enabled   # WSL adapter"
    echo "Set-NetIPInterface -InterfaceIndex $vmnet8_idx -Forwarding Enabled   # VMnet8 adapter"
    echo
    cyan "# 3. Firewall rules"
    echo "New-NetFirewallRule -DisplayName 'Vagrant VMware Utility (WSL2)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 9922 -Profile Any"
    echo "New-NetFirewallRule -DisplayName 'Vagrant WinRM (WSL2)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 55985,55986,55987,55988,55989,55990,2222,2223,2224,3389 -Profile Any"
    echo
    cyan "# 4. Port proxies for Vagrant WinRM (common ports)"
    for p in 55985 55986 55987 55988 55989 55990 2222 2223 2224; do
        echo "netsh interface portproxy add v4tov4 listenaddress=0.0.0.0 listenport=$p connectaddress=127.0.0.1 connectport=$p"
    done
    echo
    dim "# Run once. Survives reboots for portproxy/firewall rules."
    dim "# IP forwarding may need to be re-enabled after WSL restarts."
}

cmd_help() {
    cat <<EOF
$(bold "breakingbAD Lab Manager")

$(cyan "Usage:") $0 <command> [options]

$(cyan "VM Management:")
  up [vm]              Start VMs (optionally specify dc01, srv01, srv02)
  halt [vm]            Stop VMs
  destroy [vm]         Destroy VMs
  status               Overview: VMs, IPs, tunnels, ports

$(cyan "Tunnel:")
  tunnel [start|stop|status]   Manage socat tunnels to Windows host

$(cyan "Provisioning:")
  build                Run base build (AD domain, DNS, OUs, users, ADCS)
  deploy               Full deployment: up + build + enable all vulns

$(cyan "Vulnerabilities:")
  vuln list                    List all vulnerabilities and IDs
  vuln enable <ID|all>         Enable a vulnerability (or all)
  vuln disable <ID|all>        Disable a vulnerability (or all)
  vuln trigger <ID>            Trigger a vulnerability (05, 06 only)

$(cyan "Setup:")
  setup-windows        Print PowerShell commands for Windows host setup

$(cyan "Examples:")
  $0 up                        # Start all VMs
  $0 status                    # Show lab overview with IPs and ports
  $0 vuln enable 8             # Enable Kerberoasting
  $0 vuln disable all          # Disable all vulnerabilities
  $0 deploy                    # Full lab deployment from scratch
  $0 destroy                   # Tear down all VMs
EOF
}

# ── Main ───────────────────────────────────────────────────────────────────

main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        up)              cmd_up "$@" ;;
        halt)            cmd_halt "$@" ;;
        destroy)         cmd_destroy "$@" ;;
        status)          cmd_status ;;
        tunnel)          cmd_tunnel "$@" ;;
        build)           cmd_build "$@" ;;
        vuln)            cmd_vuln "$@" ;;
        deploy)          cmd_deploy "$@" ;;
        setup-windows)   cmd_setup_windows ;;
        help|-h|--help)  cmd_help ;;
        *)
            red "Unknown command: $cmd"
            echo
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
