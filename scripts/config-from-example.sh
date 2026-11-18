#!/usr/bin/env bash
# Writes clusters-example.yaml, from stdin, to stdout as the private
# .config/clusters.yaml for the one-command install (make config; install
# guide, page 9). It uncomments the lines make install needs and gives each a
# REQUIRED- placeholder: the hub's and each site's username and password,
# catalog.token, and the quay: and stage: sections. The token alternatives and
# deployment: stay commented out: they're optional. Everything else is copied
# as it is, comments included.
#
#   scripts/config-from-example.sh < clusters-example.yaml > .config/clusters.yaml
#
# It fails when a line it expects isn't in the example, so a change to the
# example can't quietly leave a secret commented out.
set -euo pipefail
awk '
  # The top-level key the line is in; "# quay:" and "# stage:" open their (commented) sections.
  /^[a-z]+:/ { sec = $0; sub(/:.*/, "", sec) }
  /^# (quay|stage|deployment):$/ { sec = substr($0, 3); sub(/:$/, "", sec) }
  /^# (quay|stage):$/ { print sec ":"; seen[sec]++; next }
  sec == "hub" && /^  # (username|password): / { key(2, "hub"); next }
  sec == "sites" && /^    # (username|password): / { key(4, "site"); next }
  sec == "catalog" && /^  # token: / { print "  token: REQUIRED-catalogToken"; seen["catalogToken"]++; next }
  (sec == "quay" || sec == "stage") && /^#   (username|password): / { key(2, sec); next }
  { print }
  function key(indent, prefix,   k) {
    k = $0; sub(/^[ #]*/, "", k); sub(/:.*/, "", k); k = prefix toupper(substr(k, 1, 1)) substr(k, 2)
    printf "%*s%s: REQUIRED-%s\n", indent, "", (k ~ /Username$/ ? "username" : "password"), k
    seen[k]++
  }
  END {
    n = split("hubUsername hubPassword siteUsername sitePassword catalogToken quay quayUsername quayPassword stage stageUsername stagePassword", want, " ")
    for (i = 1; i <= n; i++) if (!seen[want[i]]) { missing = missing " " want[i] }
    if (missing != "") { print "error: clusters-example.yaml has changed: no commented line for" missing > "/dev/stderr"; exit 1 }
  }'
