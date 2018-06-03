#!/usr/bin/env bash
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

# https://github.com/vysheng/tg

set -Eeuo pipefail
trap '>&2 printf "\e[0;1;31mFatal error executing $BASH_COMMAND at ${BASH_SOURCE[0]} line $LINENO; exit code $?.\e[0m\n"' ERR

declare -r admin_telegram="@janedoe"

is_false () {
  shopt -s nocasematch
  [[ "${1:-}" =~ ^false|no|off|0|disable|disabled$ ]]
}

is_true () {
  shopt -s nocasematch
  [[ "${1:-}" =~ ^true|yes|on|1|enable|enabled$ ]]
}

telegram_msg () {
  declare recipient="${1:-}"; shift || true
  declare msg="${*:-}"
  if [[ -n "$recipient" && -n "${msg// /}" ]] ; then
    set -x
    telegram-cli -D -C -W -e "msg @${recipient#@} \"$msg\"" >/dev/null
    { set +x; } 2>/dev/null
  fi
}

is_evening () {
  [[ $(printf "%(%H)T") -gt 16 ]]
}

notify_user () {
  declare recipient="${1:-}"

  case "${recipient,,}" in
    @johndoe)
      telegram_msg "$recipient" "Toot toot!"
      if is_evening ; then
        # https://github.com/neechbear/bash_phue
        phue lights state \
          '{"on":true,"bri":255,"hue":8500,"sat":200,"effect":"none","alert":"none"}' \
          6 >/dev/null
      fi
      ;;

    @janedoe)
      if is_evening ; then
        # https://github.com/neechbear/bash_phue
        phue lights state \
          '{"on":true,"bri":255,"hue":8500,"sat":200,"effect":"none","alert":"none"}' \
          7 >/dev/null
      fi
      ;;

    *)
      telegram_msg "$recipient" \
        "$(cat <<EOM | sed -e ':a;N;$!ba;s/\n/\\n/g'
Hello $1. Welcome back!

If you would like to use Jane Doe's wifi, please connect to the wireless network called 'Stuff and Fluff'. If after a few seconds, your device does not prompt you to login to wifi, you should open your web browser where you will be redirected to a guest access sign-in page. Simply enter the guest password of 'q1w2e3r4', and press the 'CONNECT' button.  

Ok, great.
EOM
)"
    ;;
  esac

  if is_evening ; then
    # https://github.com/neechbear/bash_phue
    phue lights state \
      '{"on":true,"bri":255,"hue":8500,"sat":200,"effect":"none","alert":"none"}' \
      9 >/dev/null
  fi
}

notify_admin () {
  declare recipient="${1:-}" telegram="${2:-}" owner="${2:-}" \
          device="${3:-}" mac="${4:-}"
  case "${telegram,,}" in
    @janejoe) ;;
    *)
      telegram_msg "$recipient" \
        "$owner has connected using their $device (MAC $mac)"
      ;;
  esac
}

main () {
  if [[ $# -lt 4 ]] ; then
    >&2 echo "Syntax: ${BASH_SOURCE##*/} <function> <origin> <field_list> <field1> .. [fieldn]"
    exit 64
  fi

  declare function="$1"; shift || true
  declare origin="$1"; shift || true
  declare -a fields=($1); shift || true

  if is_true "${DEBUG:-false}" ; then
    echo =================================================
    echo "function=$function"
    echo "origin=$origin"
    echo "fields=${fields[@]}"
    echo -------------------------------------------------
    declare i=0 v=""
    for v in "$@" ; do
      echo "[$i] ${fields[$i]}=$v"
      i=$(( i + 1 ))
    done
    echo =================================================
  fi

  case "${function,,}" in
    notify_user) notify_user "$telegram" ;;
    notify_admin) notify_admin "$admin_telegram" "$telegram" "$owner" "$device" "$mac" ;;
    *) ;;
  esac
}

main "$@"
