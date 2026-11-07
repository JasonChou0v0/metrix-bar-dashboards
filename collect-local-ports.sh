#!/bin/sh
set -eu
umask 077

mode=${1:-}
case "$mode" in
  ''|--watch) ;;
  *) printf '%s\n' '用法：sh collect-local-ports.sh [--watch]' >&2; exit 2 ;;
esac

state_dir=${METRIX_PORTS_DIR:-"$HOME/.local/state/metrix-bar/local-ports"}
/bin/mkdir -p "$state_dir"
snapshot="$state_dir/snapshot.tsv"

collect() (
  temporary=$(/usr/bin/mktemp "${snapshot}.XXXXXX")
  trap '/bin/rm -f "$temporary"' EXIT
  trap 'exit 1' HUP INT TERM

  # 使用内核的套接字清单，也能看见 lsof 可能漏掉的系统监听进程。
  if ! tcp=$(/usr/sbin/netstat -anv -p tcp) || ! udp=$(/usr/sbin/netstat -anv -p udp); then
    printf '%s\n' '本机端口：读取套接字失败，保留上一份快照。' >&2
    exit 1
  fi

  {
    /bin/date +%s
    printf '%s\n%s\n' "$tcp" "$udp" | /usr/bin/awk '
      ($1 ~ /^tcp[46]+$/ && $6 == "LISTEN") || ($1 ~ /^udp[46]+$/ && $5 == "*.*") {
        if ($4 !~ /\.[0-9]+$/) next
        address = $4
        sub(/\.[0-9]+$/, "", address)
        port = $4
        sub(/^.*\./, "", port)

        # UDP 行没有状态字段；进程名可以包含空格，以末尾的 :PID 结束。
        first = ($1 ~ /^tcp/ ? 11 : 10)
        owner = ""
        pid = ""
        for (field = first; field <= NF; field++) {
          owner = owner (field == first ? "" : " ") $field
          if ($field ~ /:-?[0-9]+$/) {
            pid = substr($field, index($field, ":") + 1)
            sub(/:-?[0-9]+$/, "", owner)
            break
          }
        }
        if (pid == "" || pid <= 0) {
          owner = "未知进程"
          pid = ""
        }
        line = $1 "\t" port "\t" address "\t" owner "\t" pid
        if (!seen[line]++) print line
      }'
  } > "$temporary"

  # 同目录原子替换，避免面板在写入过程中读到不完整的数据。
  /bin/mv -f "$temporary" "$snapshot"
)

if [ "$mode" = --watch ]; then
  trap 'exit 0' INT TERM
  printf '%s\n' '本机端口：每 15 秒采集一次，按 Ctrl+C 停止。'
  while :; do
    collect || :
    /bin/sleep 15
  done
else
  collect
  printf '%s\n' '本机端口：快照已更新。'
fi
