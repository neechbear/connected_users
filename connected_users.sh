#!/bin/bash
# 
# MIT License
# 
# Copyright (c) 2018 Nicola Worthington
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -Eeuo pipefail
trap '>&2 printf "\e[0;1;31mFatal error executing $BASH_COMMAND at ${BASH_SOURCE[0]} line $LINENO; exit code $?.\e[0m\n"' ERR

# Define some contstnats.
if [[ "$(readlink -f ${BASH_SOURCE[0]})" == "$HOME"* ]] ; then
  declare -r map_file="$HOME/.$(basename "${0%.*}").map"
  declare -r config_file="$HOME/.$(basename "${0%.*}").cnf"
else
  declare -r map_file="/etc/$(basename "${0%.*}").map"
  declare -r config_file="/etc/$(basename "${0%.*}").cnf"
fi
declare -r mac_regex='[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}:[a-f0-9]{2}'

extract_mac () {
  grep -Eo "$mac_regex"
}

load_configuration () {
  declare file="$1"
  echo "Loading configuration file $file ..."

  while read -e var ; do
    if [[ ! "$var" == *"PASSWORD"* ]] ; then
      printf "%q\n" "$var"
    fi
    declare -g "$var"
  done < <(
    before="$(compgen -v | grep -E '^[A-Z][A-Z0-9_]*[A-Z0-9]+$')"
    source "$file" >/dev/null || true
    after="$(compgen -v | grep -E '^[A-Z][A-Z0-9_]*[A-Z0-9]+$')"
    for var in $(comm -1 -3 <(sort <<< "$before") <(sort <<< "$after")) ; do
      if [[ "$(declare -p "$var")" == "declare -- $var="* ]] ; then
        printf '%s=%q\n' "$var" "${!var}"
      fi
    done
  ) || true

  declare -ag MAP_COLUMNS=($(grep -Ei -m 1 '^([a-z][a-z_]*,?)+$' "$map_file" | tr "," " "))
  if ! contains "mac"     "${MAP_COLUMNS[@]}" || \
     ! contains "enabled" "${MAP_COLUMNS[@]}" || \
     ! contains "notify"  "${MAP_COLUMNS[@]}" ; then
    >&2 echo "Missing mandatory column 'mac', 'enabled' or 'notify' from '$map_file'; exiting!"
    exit 3
  fi

  echo "Configuration loaded."
}

config_changes () {
  declare file="$1"
  while : ; do
    inotifywait -q -e close_write "$file" | while read events ; do
      echo $events
    done || true
  done
}

syslog_messages () {
  declare sudo=""
  if [[ ! -r "$SYSLOG_FILENAME" ]] ; then
    sudo="sudo"
  fi 
  $sudo tail -F "$SYSLOG_FILENAME" \
    | grep --line-buffered -Ew "$mac_regex" \
      | grep --line-buffered -Ew \
        '(AP-STA-CONNECTED|associated|handshake completed|dhcps-rx)'
}

dhcp_leases () {
  _active_dhcp_leases () {
    curl -s --user "$DHCP_LEASE_XML_URL_USERNAME:$DHCP_LEASE_XML_URL_PASSWORD" \
      "$DHCP_LEASE_XML_URL" \
      | grep -Ev "^<form ['a-zA-Z0-9/=<> ]+></form>$" \
      | xml2 | grep '/active/@mac='
  }
  last_leases="$(_active_dhcp_leases)"
  while : ; do
    leases="$(_active_dhcp_leases)"
    comm -1 -3 <(sort <<< "$last_leases") <(sort <<< "$leases")
    last_leases="$leases"
    sleep ${DHCP_POLL_INTERVAL:-30}
  done
}

is_false () {
  shopt -s nocasematch
  [[ "${1:-}" =~ ^false|no|off|0|disable|disabled$ ]]
}

is_true () {
  shopt -s nocasematch
  [[ "${1:-}" =~ ^true|yes|on|1|enable|enabled$ ]]
}

notify_user () {
  set -x
  "$NOTIFY_CMD" "${FUNCNAME[0]}" "$source_name" "$@"
  { set +x; } 2>/dev/null
}

notify_admin () {
  set -x
  "$NOTIFY_CMD" "${FUNCNAME[0]}" "$source_name" "$@"
  { set +x; } 2>/dev/null
}

contains () {
  declare str="${1:-}" v=""; shift || true
  for v in "$@" ; do
    [[ "$v" != "$str" ]] || return 0
  done
  return 1
}

process_message_queue () {
  declare source_name="$1"
  declare source_fd="$2"
  if read -u "$source_fd" -t 0 ; then
    while read -r -t 1 -u "$source_fd" unqueued_msg ; do
      if IFS=, read -r ${MAP_COLUMNS[@]} < <(grep -iw "^$(extract_mac <<< "$unqueued_msg")" "$map_file") ; then
        is_true "$enabled" || continue
        mac="${mac,,}"
        export ${MAP_COLUMNS[@]}
        if [[ -z "${activated_cache[HW${mac//:/}]:-}" ]] ; then
          eval "notify_admin '${MAP_COLUMNS[@]}' $(printf '"$%q" ' "${MAP_COLUMNS[@]}")"
          if is_true "$notify" ; then
            eval "notify_user '${MAP_COLUMNS[@]}' $(printf '"$%q" ' "${MAP_COLUMNS[@]}")"
          fi
        fi
        activated_cache[HW${mac//:/}]="$(printf "%(%s)T" -1)"
        unset ${MAP_COLUMNS[@]}
      fi
    done
  fi
}

main () {
  trap 'load_configuration "$config_file"' HUP USR1 USR2
  declare -A activated_cache=()

  while : ; do 
    for cache in "${!activated_cache[@]}" ; do
      if [[ -n "${activated_cache[$cache]:-}" && \
        $(( $(printf "%(%s)T" -1) - ${activated_cache[$cache]} )) -ge ${CACHE_TTL_SECONDS:-86400} ]] ; then
        unset activated_cache[$cache]
        echo "Expired $cache from cache."
      fi
    done

    if read -u 3 -t 0 ; then
      while read -r -t 1 -u 3 fd3 ; do
        echo "$fd3"
        load_configuration "$config_file"
      done
    fi

    declare msg_source_name="" msg_source_fd=""
    for msg_source_name in "${!message_queues[@]}" ; do
      msg_source_fd="${message_queues[$msg_source_name]}"
      process_message_queue "$msg_source_name" "$msg_source_fd"
    done

    sleep ${POLL_LOOP_INTERVAL:-1}
  done
}

exec \
  1> >(2>&-;logger -s -t "${0##*/}[$$]" -p user.info 2>&1) \
  2> >(     logger -s -t "${0##*/}[$$]" -p user.error    )

echo "Using map file $map_file"
load_configuration "$config_file"
exec \
  3< <(config_changes "$config_file")

# Add any new message queues here.
declare -rA message_queues=( [syslog_messages]=4 [dhcp_leases]=5 )
exec \
  4< <(syslog_messages) \
  5< <(dhcp_leases)

main "$@"
exit $?

