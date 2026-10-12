#!/bin/bash
#
# mac-trace-audit.sh
# Copyright (c) 2026 Itch Studio Ltd. MIT licence: https://github.com/Itch-Studio/trailsift-audit
# This is the audit behind TrailSift for Mac (https://trailsift.com).
#
# A read-only audit of where browsing, download and media traces live on a Mac.
# Nothing is deleted, moved or modified. Databases are copied into a private
# temp folder before they are queried, so the originals are never opened, and
# that temp folder is removed when the script exits.
#
# By default only counts, sizes and date ranges are printed, never URLs or
# file names, so the report is safe to read on a shared screen.
#
# Usage:
#   ./mac-trace-audit.sh          standard audit, with an explanation per finding
#   ./mac-trace-audit.sh -brief   the same, without the explanations
#   ./mac-trace-audit.sh -v       also list the top 10 sites per history database
#   ./mac-trace-audit.sh -deep    also find image and video files in caches and
#                                 hidden folders (slow: several minutes)
#   ./mac-trace-audit.sh -nolinks plain paths, without clickable terminal links
#   ./mac-trace-audit.sh -json    one JSON object per line, for the TrailSift app
#   ./mac-trace-audit.sh -search "word,another phrase"
#                                 instead of the audit, search browser histories,
#                                 the download log, file and folder names and
#                                 document text for the given words; add -deep
#                                 to look through every folder for names
#
# Under each finding the report prints where it lives. In terminals that support
# links (Terminal, iTerm2, the Claude app), Cmd-click the path to open its
# folder in Finder.
#
# Some locations (Safari, Messages, Trash, Screen Time) are protected by macOS.
# To audit them, give your terminal app Full Disk Access in
# System Settings > Privacy & Security > Full Disk Access, then run again.

VERBOSE=0
DEEP=0
NOLINKS=0
BRIEF=0
JSON=0
SEARCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    -v) VERBOSE=1 ;;
    -deep) DEEP=1 ;;
    -nolinks) NOLINKS=1 ;;
    -brief) BRIEF=1 ;;
    -json) JSON=1 ;;
    -search) shift; SEARCH="$1"; [ -n "$SEARCH" ] || { echo "-search needs words, separated by commas"; exit 1; } ;;
    -h|-help) sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1 (try -h)"; exit 1 ;;
  esac
  shift
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/trace-audit.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

NEED_FDA=0
LIB="$HOME/Library"
# The tests point this at a stand-in for /Library.
SYSLIB="${TRAILSIFT_SYSTEM_LIBRARY:-/Library}"
APPSUP="$LIB/Application Support"

B=""; D=""; Y=""; R=""; LINKS=0
if [ -t 1 ] && [ "$JSON" = 0 ]; then
  B=$'\033[1m'; D=$'\033[2m'; Y=$'\033[33m'; R=$'\033[0m'
  [ "$NOLINKS" = 0 ] && LINKS=1
fi

# ===========================================================================
# Output. Every line of the report goes through these helpers, which print
# either the terminal report or, with -json, one JSON object per line.

json() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/ }; s=${s//$'\n'/ }; s=${s//$'\r'/ }
  printf '"%s"' "$s"
}

section() {
  if [ "$JSON" = 1 ]; then printf '{"t":"section","title":%s}\n' "$(json "$1")"
  else printf "\n%s%s%s\n" "$B" "$1" "$R"; fi
}

# row LABEL VALUE [STATUS]. Status is found, missing or blocked; when it is not
# given it is worked out from the value.
row() {
  local status="$3"
  if [ -z "$status" ]; then
    case "$2" in
      "not found"*|"not installed"*|"none installed"*|"not signed in"*) status=missing ;;
      0|"0 "*|no|none|*", empty") status=missing ;;
      *) status=found ;;
    esac
  fi
  if [ "$JSON" = 1 ]; then
    printf '{"t":"row","label":%s,"value":%s,"status":"%s"}\n' "$(json "$1")" "$(json "$2")" "$status"
  else
    printf "  %-44s %s\n" "$1" "$2"
  fi
}

note() {
  if [ "$JSON" = 1 ]; then printf '{"t":"note","text":%s}\n' "$(json "$1")"
  else printf "  %s%s%s\n" "$D" "$1" "$R"; fi
}

flag() {
  if [ "$JSON" = 1 ]; then printf '{"t":"flag","text":%s}\n' "$(json "$1")"
  else printf "  %s! %s%s\n" "$Y" "$1" "$R"; fi
}

# about TEXT [URL]: what a section or finding is, and where to read more.
about() {
  if [ "$JSON" = 1 ]; then
    printf '{"t":"about","text":%s,"url":%s}\n' "$(json "$1")" "$(json "$2")"
    return
  fi
  [ "$BRIEF" = 1 ] && return
  [ -n "$1" ] && printf '%s\n' "$1" | fold -s -w 74 | while IFS= read -r l; do printf "  %s    %s%s\n" "$D" "$l" "$R"; done
  [ -n "$2" ] && printf "  %s    More: %s%s\n" "$D" "$2" "$R"
}

# item COUNT TEXT [PATH]: one line of a breakdown under a finding.
item() {
  if [ "$JSON" = 1 ]; then
    printf '{"t":"item","count":%s,"text":%s,"path":%s}\n' "$(json "$1")" "$(json "$2")" "$(json "$3")"
  elif [ -n "$3" ]; then
    printf "    %7s  " "$1"; link "$3" "$2"; echo
  else
    printf "        %6s  %s\n" "$1" "$2"
  fi
}

day() { [ -n "$1" ] && date -r "$1" '+%Y-%m-%d'; }

urlencode() {
  local LC_ALL=C s="$1" out="" c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9/._~-]) out="$out$c" ;;
      *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
  done
  echo "$out"
}

tilde() { case "$1" in "$HOME"*) echo "~${1#"$HOME"}" ;; *) echo "$1" ;; esac; }

# Print text that, in terminals supporting OSC 8 links, opens a folder in Finder.
link() {
  if [ "$LINKS" = 1 ]; then
    printf '\e]8;;file://%s\e\\%s\e]8;;\e\\' "$(urlencode "$1")" "$2"
  else
    printf '%s' "$2"
  fi
}

# Print where a finding lives, under its row. For a file, the link opens the
# folder containing it rather than the file itself. "force" prints the path
# even when macOS hides whether it exists.
loc() {
  local p="$1" dir
  [ -e "$p" ] || [ "$2" = force ] || return
  if [ -d "$p" ]; then dir="$p"; else dir=$(dirname "$p"); fi
  if [ "$JSON" = 1 ]; then
    printf '{"t":"loc","path":%s,"dir":%s}\n' "$(json "$p")" "$(json "$dir")"
  else
    printf "  %s    " "$D"; link "$dir" "$(tilde "$p")"; printf "%s\n" "$R"
  fi
}

blocked() { row "$1" "present, blocked (needs Full Disk Access)" blocked; NEED_FDA=1; }

# ===========================================================================
# Data helpers

# Copy a SQLite database (plus its WAL and SHM files) to the temp folder and
# print the path of the copy. Each copy gets a unique name so a stale WAL from
# one database is never applied to another.
copy_db() {
  local src="$1" dst
  [ -f "$src" ] || return 1
  dst=$(mktemp "$TMP/db.XXXXXX") || return 1
  cp "$src" "$dst" 2>/dev/null || return 2
  [ -f "$src-wal" ] && cp "$src-wal" "$dst-wal" 2>/dev/null
  [ -f "$src-shm" ] && cp "$src-shm" "$dst-shm" 2>/dev/null
  echo "$dst"
}

query() { sqlite3 "$1" "$2" 2>/dev/null; }

# The browser's name from its folder under Application Support.
browser_name() {
  case "$1" in
    Google/Chrome) echo "Chrome" ;;
    "Google/Chrome Beta") echo "Chrome Beta" ;;
    BraveSoftware/*) echo "Brave" ;;
    "Arc/User Data") echo "Arc" ;;
    com.operasoftware.Opera) echo "Opera" ;;
    *) echo "$1" ;;
  esac
}

# "1 match", "2 matches", "500 or more matches".
matches() { if [ "$1" = 1 ]; then echo "1 match"; else echo "$1 matches"; fi; }
# plural N WORD [PLURAL]: "1 folder", "3 folders".
plural() { if [ "$1" = 1 ]; then echo "1 $2"; else echo "$1 ${3:-${2}s}"; fi; }

# Print "N items, first to last" from a "count|first|last" query result.
span() {
  local n a b
  IFS='|' read -r n a b <<< "$1"
  n=${n:-0}
  if [ "$n" -gt 0 ] 2>/dev/null; then echo "$n $2, $a to $b"; else echo "0 $2"; fi
}

top_hosts() {
  [ "$VERBOSE" = 1 ] || return
  [ "$JSON" = 1 ] || note "    Top sites:"
  query "$1" "$2" \
    | sed -E 's#^[a-zA-Z]+://([^/:]+).*#\1#' \
    | sort | uniq -c | sort -rn | head -10 \
    | while read -r c h; do item "$c" "$h"; done
}

# Size, file count and oldest/newest modification date for a file or folder.
path_stats() {
  local label="$1" p="$2" size n times
  if [ ! -e "$p" ]; then
    # macOS privacy protection can hide an item from tests while its name
    # still shows in the parent listing, or hide the parent's contents entirely.
    local parent; parent=$(dirname "$p")
    if [ -e "$parent" ] && { ! ls "$parent" >/dev/null 2>&1 || ls -a "$parent" 2>/dev/null | grep -qxF "$(basename "$p")"; }; then
      blocked "$label"; loc "$p" force
    else
      row "$label" "not found"
    fi
    return
  fi
  if ! ls "$p" >/dev/null 2>&1; then blocked "$label"; loc "$p"; return; fi
  size=$(du -sh "$p" 2>/dev/null | cut -f1 | tr -d ' ')
  if [ -d "$p" ]; then
    times=$(find "$p" -type f -exec stat -f '%m' {} + 2>/dev/null | sort -n)
    n=$(printf '%s' "$times" | grep -c .)
    if [ "$n" -eq 0 ]; then
      row "$label" "$size, empty"
    else
      row "$label" "$size, $n files, $(day "$(head -1 <<< "$times")") to $(day "$(tail -1 <<< "$times")")"
    fi
  else
    row "$label" "$size, modified $(day "$(stat -f '%m' "$p")")"
  fi
  loc "$p"
}

chromium_profile() {
  local label="$1" dir="$2" db rc
  db=$(copy_db "$dir/History"); rc=$?
  if [ $rc -ne 0 ]; then row "$label history" "unreadable"; return; fi
  row "$label history" "$(span "$(query "$db" "select count(*), date(min(visit_time)/1000000-11644473600,'unixepoch'), date(max(visit_time)/1000000-11644473600,'unixepoch') from visits;")" visits)"
  loc "$dir/History"
  top_hosts "$db" "select u.url from visits v join urls u on u.id = v.url;"
  row "$label downloads list" "$(span "$(query "$db" "select count(*), date(min(start_time)/1000000-11644473600,'unixepoch'), date(max(start_time)/1000000-11644473600,'unixepoch') from downloads;")" entries)"
  [ -f "$dir/Favicons" ] && path_stats "$label favicons" "$dir/Favicons"
  [ -d "$dir/Sessions" ] && path_stats "$label saved sessions" "$dir/Sessions"
  if [ -f "$dir/TransportSecurity" ]; then
    row "$label secure-site list" "$(grep -o '"host":' "$dir/TransportSecurity" 2>/dev/null | grep -c .) sites"
    loc "$dir/TransportSecurity"
  fi
}

# Firefox and Tor Browser share this format.
firefox_profile() {
  local label="$1" dir="$2" db rc
  db=$(copy_db "$dir/places.sqlite"); rc=$?
  if [ $rc -ne 0 ]; then row "$label history" "unreadable"; return; fi
  row "$label history" "$(span "$(query "$db" "select count(*), date(min(visit_date)/1000000,'unixepoch'), date(max(visit_date)/1000000,'unixepoch') from moz_historyvisits;")" visits)"
  loc "$dir/places.sqlite"
  top_hosts "$db" "select p.url from moz_historyvisits v join moz_places p on p.id = v.place_id;"
  row "$label downloads list" "$(query "$db" "select count(*) from moz_annos a join moz_anno_attributes t on t.id = a.anno_attribute_id where t.name = 'downloads/destinationFileURI';") entries"
  row "$label bookmarks" "$(query "$db" "select count(*) from moz_bookmarks where type = 1 and fk is not null;")"
  [ -f "$dir/favicons.sqlite" ] && path_stats "$label favicons" "$dir/favicons.sqlite"
  if [ -f "$dir/sessionstore.jsonlz4" ] || [ -d "$dir/sessionstore-backups" ]; then
    path_stats "$label saved session" "$dir/sessionstore-backups"
  fi
  if [ -f "$dir/SiteSecurityServiceState.txt" ]; then
    row "$label secure-site list" "$(grep -c . "$dir/SiteSecurityServiceState.txt") sites"
    loc "$dir/SiteSecurityServiceState.txt"
  fi
}

# Group a list of paths by their first few folders under $HOME and list the
# 20 busiest folders.
group_by_folder() {
  awk -F/ -v h="$HOME/" '
    { if (index($0, h) == 1) $0 = substr($0, length(h) + 1)
      n = NF - 1; if (n > 5) n = 5; if (n < 1) n = 1
      d = $1; for (i = 2; i <= n; i++) d = d "/" $i
      print d }' \
    | sort | uniq -c | sort -rn | head -20 \
    | while read -r c d; do item "$c" "~/$d" "$HOME/$d"; done
}

# ===========================================================================
# Word search (-search). Runs instead of the audit. Every term is matched
# case-insensitively as part of a word, so "porn" also finds "pornhub".

US=$'\x1f'

# Search one history-style database. The SQL must return date, title and
# address separated by $US, and contain TERM where the search word goes.
search_db() {
  local label="$1" src="$2" sql="$3" db rc t results n
  db=$(copy_db "$src"); rc=$?
  if [ $rc -eq 1 ]; then return; fi
  if [ $rc -ne 0 ]; then blocked "$label"; loc "$src"; return; fi
  for t in "${TERMS[@]}"; do
    results=$(sqlite3 -separator "$US" "$db" "${sql//TERM/$t}" 2>/dev/null)
    n=$(printf '%s' "$results" | grep -c .)
    if [ "$n" -eq 0 ]; then
      row "$label: \"$t\"" "no matches" missing
      continue
    fi
    [ "$n" -ge 500 ] && n="500 or more"
    row "$label: \"$t\"" "$(matches "$n")" found
    loc "$src"
    printf '%s\n' "$results" | head -50 | while IFS="$US" read -r d title addr; do
      if [ -n "$title" ]; then item "$d" "$title  $addr"; else item "$d" "$addr"; fi
    done
  done
}

run_search() {
  local raw t
  TERMS=()
  IFS=',' read -r -a raw <<< "$SEARCH"
  for t in "${raw[@]}"; do
    # Letters, digits, spaces, dots and hyphens only, so a term can't break
    # out of the SQL, find or Spotlight queries it is placed in.
    t=$(printf '%s' "$t" | tr -cd '[:alnum:] .-' | tr '[:upper:]' '[:lower:]' | sed -E 's/^ +//; s/ +$//')
    [ ${#t} -ge 2 ] && TERMS+=("$t")
  done
  if [ ${#TERMS[@]} -eq 0 ]; then echo "No usable search words (two or more letters or digits each)."; exit 1; fi

  if [ "$JSON" = 1 ]; then
    printf '{"t":"meta","date":%s,"macos":%s,"user":%s,"mode":"search"}\n' \
      "$(json "$(date '+%Y-%m-%d %H:%M')")" "$(json "$(sw_vers -productVersion)")" "$(json "$(id -un)")"
  else
    printf "%sMac trace search%s  %s, user %s\n" "$B" "$R" "$(date '+%Y-%m-%d %H:%M')" "$(id -un)"
    note "Read-only. Searching for: $(printf '"%s" ' "${TERMS[@]}")"
  fi

  section "Browsing history"
  about "Pages whose address or title contains a search word, newest first, with the date of the last visit. Up to 50 are listed per browser and word."
  for sdb in "Safari:$LIB/Safari/History.db" "Safari Technology Preview:$LIB/SafariTechnologyPreview/History.db"; do
    search_db "${sdb%%:*}" "${sdb#*:}" \
      "select date(max(v.visit_time)+978307200,'unixepoch'), ifnull(max(v.title),''), i.url from history_items i join history_visits v on v.history_item = i.id where lower(i.url) like '%TERM%' or lower(ifnull(v.title,'')) like '%TERM%' group by i.id order by max(v.visit_time) desc limit 500;"
  done
  for b in "Google/Chrome" "Google/Chrome Beta" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc/User Data" "Vivaldi" "Chromium" "com.operasoftware.Opera"; do
    [ -d "$APPSUP/$b" ] || continue
    while IFS= read -r h; do
      search_db "$(browser_name "$b") ($(basename "$(dirname "$h")"))" "$h" \
        "select date(last_visit_time/1000000-11644473600,'unixepoch'), ifnull(title,''), url from urls where lower(url) like '%TERM%' or lower(ifnull(title,'')) like '%TERM%' order by last_visit_time desc limit 500;"
    done < <(find "$APPSUP/$b" -maxdepth 2 -name History -type f 2>/dev/null)
  done
  while IFS= read -r p; do
    case "$p" in
      *TorBrowser-Data*) name="Tor Browser" ;;
      */zen/*) name="Zen" ;;
      */librewolf/*) name="LibreWolf" ;;
      */Waterfox/*) name="Waterfox" ;;
      *) name="Firefox" ;;
    esac
    search_db "$name" "$p" \
      "select date(last_visit_date/1000000,'unixepoch'), ifnull(title,''), url from moz_places where lower(url) like '%TERM%' or lower(ifnull(title,'')) like '%TERM%' order by last_visit_date desc limit 500;"
  done < <(find "$APPSUP/Firefox/Profiles" "$APPSUP/TorBrowser-Data/Browser" "$APPSUP/zen/Profiles" \
             "$APPSUP/librewolf/Profiles" "$APPSUP/Waterfox/Profiles" -maxdepth 3 -name places.sqlite 2>/dev/null)

  section "Downloads"
  about "Downloads whose web address or page title contains a search word: the macOS download log, which survives clearing browser history, and each browser's own downloads list."
  search_db "Download log" "$LIB/Preferences/com.apple.LaunchServices.QuarantineEventsV2" \
    "select date(LSQuarantineTimeStamp+978307200,'unixepoch'), ifnull(LSQuarantineOriginTitle,''), ifnull(LSQuarantineOriginURLString, ifnull(LSQuarantineDataURLString,'')) from LSQuarantineEvent where lower(ifnull(LSQuarantineDataURLString,'')) like '%TERM%' or lower(ifnull(LSQuarantineOriginURLString,'')) like '%TERM%' or lower(ifnull(LSQuarantineOriginTitle,'')) like '%TERM%' order by LSQuarantineTimeStamp desc limit 500;"
  for b in "Google/Chrome" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc/User Data"; do
    [ -d "$APPSUP/$b" ] || continue
    while IFS= read -r h; do
      search_db "$(browser_name "$b") downloads ($(basename "$(dirname "$h")"))" "$h" \
        "select date(start_time/1000000-11644473600,'unixepoch'), '', ifnull(target_path,'') || ' from ' || ifnull(tab_url,'') from downloads where lower(ifnull(target_path,'')) like '%TERM%' or lower(ifnull(tab_url,'')) like '%TERM%' order by start_time desc limit 500;"
    done < <(find "$APPSUP/$b" -maxdepth 2 -name History -type f 2>/dev/null)
  done

  for t in "${TERMS[@]}"; do
    local from n
    from=$(mdfind -onlyin "$HOME" "kMDItemWhereFroms == \"*$t*\"cd" 2>/dev/null | grep -v '\.photoslibrary/')
    n=$(printf '%s' "$from" | grep -c .)
    if [ "$n" -eq 0 ]; then row "Files downloaded from \"$t\"" "no matches" missing; continue; fi
    row "Files downloaded from \"$t\"" "$(matches "$n")" found
    head -100 <<< "$from" | while IFS= read -r f; do item "" "$(tilde "$f")" "$f"; done
  done

  section "File and folder names"
  if [ "$DEEP" = 1 ]; then
    about "Files and folders in your home folder whose name contains a search word. Thorough search: every folder is looked through, including hidden folders and Library. Only names are read, so files kept in iCloud are not downloaded. Developer tool folders such as node_modules and .git, and app caches, whose files have generated names, are skipped. Up to 100 are listed per word."
  else
    about "Files and folders in your home folder whose name contains a search word. Visible folders are searched through Spotlight's name index, and Library and hidden folders, which Spotlight skips, are looked through directly. Developer tool folders such as node_modules and .git, and app caches, whose files have generated names, are skipped. Hidden folders inside your other folders need a thorough search. Only names are read. Up to 100 are listed per word."
  fi
  local expr=() query="" roots=() e names
  for t in "${TERMS[@]}"; do
    [ ${#expr[@]} -gt 0 ] && expr+=(-o)
    expr+=(-iname "*$t*")
    query="$query${query:+ || }kMDItemFSName == \"*$t*\"cd"
  done
  # Folders of developer tool files, whose names are package names rather than
  # anything personal, app caches, whose files have generated names, and the
  # Photos library, whose originals have generated names too. Together they are
  # most of what a walk would visit, so skipping them is what keeps it fast.
  local prune=( \( -name '*.photoslibrary' -o -name node_modules -o -name .git -o -name .npm \
    -o -name .cargo -o -name .rustup -o -name .gradle -o -name .m2 -o -name .pub-cache \
    -o -name .cocoapods -o -name .swiftpm -o -name .build -o -name DerivedData \
    -o -name site-packages -o -name .venv -o -name .pyenv -o -path "$HOME/.local/share/uv" \
    -o -path "$HOME/.*/extensions" \
    -o -name .cache -o -name Cache -o -name Caches -o -name 'Code Cache' -o -name GPUCache \
    -o -name CacheStorage -o -name 'Service Worker' \
    -o -path "$LIB/Developer" \) -prune )
  # The same folders, for Spotlight's results.
  local skipped='\.photoslibrary/|/(node_modules|\.git|\.build|DerivedData|site-packages|\.venv|\.cache|Cache|Caches|Code Cache|GPUCache|CacheStorage|Service Worker)/'
  if [ "$DEEP" = 1 ]; then
    for e in "$HOME"/* "$LIB"/* "$HOME"/.[!.]*; do [ -e "$e" ] && [ "$e" != "$LIB" ] && roots+=("$e"); done
  else
    for e in "$LIB"/* "$HOME"/.[!.]*; do [ -e "$e" ] && roots+=("$e"); done
  fi
  # Walk the roots eight at a time. Spotlight answers for the visible folders
  # in a fraction of a second, so the fast search only walks what it skips.
  names=$( {
    [ "$DEEP" = 1 ] || mdfind -onlyin "$HOME" "$query" 2>/dev/null | grep -vE "$skipped"
    [ ${#roots[@]} -gt 0 ] && printf '%s\0' "${roots[@]}" \
      | xargs -0 -P 8 -I{} find {} "${prune[@]}" -o \( "${expr[@]}" \) -print 2>/dev/null
  } | sort -u )
  for t in "${TERMS[@]}"; do
    local hits n
    hits=$(printf '%s\n' "$names" | awk -v t="$t" 'NF { n = split($0, p, "/"); if (index(tolower(p[n]), t)) print }')
    n=$(printf '%s' "$hits" | grep -c .)
    if [ "$n" -eq 0 ]; then row "Names containing \"$t\"" "no matches" missing; continue; fi
    row "Names containing \"$t\"" "$(matches "$n")" found
    head -100 <<< "$hits" | while IFS= read -r f; do item "" "$(tilde "$f")" "$f"; done
  done

  section "Document text (Spotlight)"
  about "Documents in your home folder whose text contains a search word, using the Spotlight index: text files, PDFs, Word and Pages documents, and other files Spotlight reads. Folders Spotlight skips, such as hidden ones, aren't covered. Up to 100 are listed per word."
  for t in "${TERMS[@]}"; do
    local docs n
    docs=$(mdfind -onlyin "$HOME" "kMDItemTextContent == \"*$t*\"cd" 2>/dev/null | grep -v '\.photoslibrary/')
    n=$(printf '%s' "$docs" | grep -c .)
    if [ "$n" -eq 0 ]; then row "Documents containing \"$t\"" "no matches" missing; continue; fi
    row "Documents containing \"$t\"" "$(matches "$n")" found
    head -100 <<< "$docs" | while IFS= read -r f; do item "" "$(tilde "$f")" "$f"; done
  done

  if [ "$JSON" = 1 ]; then
    printf '{"t":"done","needFullDiskAccess":%s}\n' "$( [ "$NEED_FDA" = 1 ] && echo true || echo false )"
  else
    section "Done"
    [ "$NEED_FDA" = 1 ] && flag "Some places were blocked. Grant Full Disk Access and search again to include them."
    note "Nothing was changed."
  fi
}

[ -n "$SEARCH" ] && { run_search; exit 0; }

# ===========================================================================
if [ "$JSON" = 1 ]; then
  printf '{"t":"meta","date":%s,"macos":%s,"user":%s,"verbose":%s,"deep":%s}\n' \
    "$(json "$(date '+%Y-%m-%d %H:%M')")" "$(json "$(sw_vers -productVersion)")" "$(json "$(id -un)")" \
    "$( [ "$VERBOSE" = 1 ] && echo true || echo false )" "$( [ "$DEEP" = 1 ] && echo true || echo false )"
else
  printf "%sMac trace audit%s  %s, macOS %s, user %s\n" "$B" "$R" "$(date '+%Y-%m-%d %H:%M')" "$(sw_vers -productVersion)" "$(id -un)"
  note "Read-only. Counts and dates only$( [ "$VERBOSE" = 1 ] && echo ', plus top sites (-v)')."
fi

# ===========================================================================
section "Disk protection"
about "FileVault encrypts your whole startup disk. With it on, files deleted from an SSD can't be brought back with recovery tools, so what matters is the data that still exists in the places below." \
  "https://support.apple.com/guide/mac-help/protect-data-on-your-mac-with-filevault-mh11785/mac"
row "FileVault" "$(fdesetup status 2>/dev/null | head -1)"

# ===========================================================================
section "Download history (LaunchServices quarantine log)"
about "When an app downloads a file, macOS marks it so Gatekeeper can check it before it first opens. It also logs every download in this database: the date, the app, and the web address it came from. Clearing browser history does not touch it. AirDrop and Messages entries are files other people sent you." \
  "https://eclecticlight.co/?s=QuarantineEventsV2"
QDB_SRC="$LIB/Preferences/com.apple.LaunchServices.QuarantineEventsV2"
QDB=$(copy_db "$QDB_SRC"); rc=$?
if [ $rc -eq 1 ]; then
  row "Quarantine log" "not found"
elif [ $rc -ne 0 ]; then
  blocked "Quarantine log"; loc "$QDB_SRC"
else
  row "Recorded downloads" "$(span "$(query "$QDB" "select count(*), date(min(LSQuarantineTimeStamp)+978307200,'unixepoch'), date(max(LSQuarantineTimeStamp)+978307200,'unixepoch') from LSQuarantineEvent;")" entries)"
  loc "$QDB_SRC"
  [ "$JSON" = 1 ] || note "By app:"
  query "$QDB" "select ifnull(LSQuarantineAgentName, 'unknown'), count(*) from LSQuarantineEvent group by 1 order by 2 desc limit 10;" \
    | while IFS='|' read -r a c; do
        [ "$a" = sharingd ] && a="AirDrop (sharingd)"
        item "$c" "$a"
      done
  top_hosts "$QDB" "select ifnull(LSQuarantineOriginURLString, LSQuarantineDataURLString) from LSQuarantineEvent where ifnull(LSQuarantineOriginURLString, LSQuarantineDataURLString) is not null;"
fi
# Downloaded files carry the address they came from on the file itself. Spotlight
# knows most of them; Downloads, Desktop and Documents are also looked through
# directly, for files it hasn't indexed.
WHEREFROM=$( { mdfind -onlyin "$HOME" 'kMDItemWhereFroms == "*"' 2>/dev/null
  for d in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents"; do
    [ -d "$d" ] && find "$d" -xattrname com.apple.metadata:kMDItemWhereFroms 2>/dev/null
  done; } | grep -v '\.photoslibrary/' | sort -u)
n=$(printf '%s' "$WHEREFROM" | grep -c .)
row "Files that remember where they came from" "$n files"
[ "$n" -gt 0 ] && loc "$HOME/Downloads"
about "Every downloaded file keeps the address it came from on the file itself, which Get Info shows as Where from. Clearing browser history and the download log leaves it in place, so a file in Downloads can still say which site it came from." \
  "https://eclecticlight.co/?s=kMDItemWhereFroms"

# ===========================================================================
section "Safari"
about "History.db records every page visit. The favicon cache keeps the small icons of sites you visited and can outlive a history clear. Last session and recently closed tabs let Safari reopen your tabs, and the cache holds copies of images and pages you loaded. History > Clear History removes most of this." \
  "https://support.apple.com/guide/safari/clear-your-browsing-history-sfri47acf5d6/mac"
if [ ! -d "$LIB/Safari" ]; then
  row "Safari data" "not found"
elif ! ls "$LIB/Safari" >/dev/null 2>&1; then
  blocked "Safari data"; loc "$LIB/Safari"
else
  SDB=$(copy_db "$LIB/Safari/History.db")
  if [ -n "$SDB" ]; then
    row "History" "$(span "$(query "$SDB" "select count(*), date(min(visit_time)+978307200,'unixepoch'), date(max(visit_time)+978307200,'unixepoch') from history_visits;")" visits)"
    loc "$LIB/Safari/History.db"
    top_hosts "$SDB" "select i.url from history_visits v join history_items i on i.id = v.history_item;"
  fi
  if [ -f "$LIB/Safari/Downloads.plist" ]; then
    row "Downloads list" "$(plutil -extract DownloadHistory raw -o - "$LIB/Safari/Downloads.plist" 2>/dev/null || echo 0) entries"
  fi
  path_stats "Favicon cache" "$LIB/Safari/Favicon Cache"
  [ -f "$LIB/Safari/RecentlyClosedTabs.plist" ] && path_stats "Recently closed tabs" "$LIB/Safari/RecentlyClosedTabs.plist"
  [ -f "$LIB/Safari/LastSession.plist" ] && path_stats "Last session" "$LIB/Safari/LastSession.plist"
fi
path_stats "Cache" "$LIB/Containers/com.apple.Safari/Data/Library/Caches"
[ -d "$LIB/Caches/com.apple.Safari" ] && path_stats "Cache (legacy)" "$LIB/Caches/com.apple.Safari"
# macOS keeps one list of secure sites for Safari and other apps that load web pages.
HSTS="$LIB/Cookies/HSTS.plist"
if [ -r "$HSTS" ]; then
  row "Secure-site list (HSTS)" "$(plutil -extract com.apple.CFNetwork.defaultStorageSession raw "$HSTS" 2>/dev/null || echo 0) sites"
  loc "$HSTS"
else
  path_stats "Secure-site list (HSTS)" "$HSTS"
fi
about "Browsers remember every site they've used over a secure connection, to insist on it next time. The list is kept apart from history, and clearing history leaves it in place." \
  "https://developer.mozilla.org/docs/Web/HTTP/Reference/Headers/Strict-Transport-Security"

# ===========================================================================
section "Chrome-family browsers"
about "Each profile has a History database (visits and downloads), Favicons (site icons) and Sessions (tabs to restore). The disk cache in ~/Library/Caches holds copies of images and pages you loaded. Delete browsing data in the browser's settings clears them." \
  "https://support.google.com/chrome/answer/2392709?co=GENIE.Platform%3DDesktop"
found_chromium=0
for b in "Google/Chrome" "Google/Chrome Beta" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc/User Data" "Vivaldi" "Chromium" "com.operasoftware.Opera"; do
  base="$APPSUP/$b"
  [ -d "$base" ] || continue
  found_chromium=1
  name=$(browser_name "$b")
  while IFS= read -r h; do
    chromium_profile "$name ($(basename "$(dirname "$h")"))" "$(dirname "$h")"
  done < <(find "$base" -maxdepth 2 -name History -type f 2>/dev/null)
  [ -d "$LIB/Caches/$b" ] && path_stats "$name cache" "$LIB/Caches/$b"
done
[ $found_chromium = 0 ] && row "Chrome, Brave, Edge, Arc, Opera" "none installed"

# ===========================================================================
section "Firefox"
about "places.sqlite holds history, bookmarks and the downloads list. favicons.sqlite holds site icons, the session store keeps your open tabs, and the cache holds copies of pages and images." \
  "https://support.mozilla.org/kb/delete-browsing-search-download-history-firefox"
if [ -d "$APPSUP/Firefox/Profiles" ]; then
  while IFS= read -r p; do
    firefox_profile "Firefox ($(basename "$(dirname "$p")" | cut -d. -f2))" "$(dirname "$p")"
  done < <(find "$APPSUP/Firefox/Profiles" -maxdepth 2 -name places.sqlite 2>/dev/null)
  path_stats "Firefox cache" "$LIB/Caches/Firefox"
else
  row "Firefox" "not installed"
fi

# ===========================================================================
section "Tor Browser"
about "Tor Browser runs in permanent private browsing, so it normally saves no history. Its profile still keeps bookmarks, site icons and settings, and its Tor folder records network state. Dragging the app to the Trash leaves the TorBrowser-Data folder behind, and macOS keeps its own records of the app: the download log, saved window state and the Dock." \
  "https://tb-manual.torproject.org/uninstalling/"
TOR_APPS=$( { mdfind "kMDItemCFBundleIdentifier == 'org.torproject.torbrowser'" 2>/dev/null
              for a in "/Applications/Tor Browser.app" "$HOME/Applications/Tor Browser.app"; do [ -d "$a" ] && echo "$a"; done
            } | sort -u)
if [ -n "$TOR_APPS" ]; then
  echo "$TOR_APPS" | while IFS= read -r a; do row "App installed" "$a"; loc "$a"; done
elif [ -d "$APPSUP/TorBrowser-Data" ]; then
  row "App installed" "not found (app removed, but its data remains)"
else
  row "App installed" "not found"
fi

TBD="$APPSUP/TorBrowser-Data"
if [ -d "$TBD" ]; then
  path_stats "TorBrowser-Data folder" "$TBD"
  if [ -f "$TBD/Tor/state" ]; then
    row "Tor last connected" "$(grep '^LastWritten' "$TBD/Tor/state" | cut -d' ' -f2-)"
    loc "$TBD/Tor/state"
    about "Tor's state file remembers the entry relays it used. Tor rewrites it while running, so its LastWritten time is roughly the last time Tor Browser was in use."
  fi
  while IFS= read -r p; do
    prof="$(dirname "$p")"
    firefox_profile "Tor ($(basename "$prof"))" "$prof"
    if [ -f "$prof/prefs.js" ]; then
      if grep -q '"browser.privatebrowsing.autostart", false' "$prof/prefs.js"; then
        flag "History has been turned ON in this Tor profile (privacy mode disabled)."
      fi
      if grep -q '"browser.download.lastDir"' "$prof/prefs.js"; then
        if [ "$VERBOSE" = 1 ]; then
          row "Last download folder" "$(grep '"browser.download.lastDir"' "$prof/prefs.js" | sed -E 's/.*, "(.*)"\);/\1/')"
        else
          row "Last download folder" "recorded in prefs.js (-v to show)"
        fi
        loc "$prof/prefs.js"
        about "Tor Browser remembers the last folder you saved a download to, even in private mode."
      fi
    fi
  done < <(find "$TBD/Browser" -maxdepth 3 -name places.sqlite 2>/dev/null)
else
  row "TorBrowser-Data folder" "not found"
fi
# Older bundles kept their profile inside the app.
if [ -n "$TOR_APPS" ]; then
  echo "$TOR_APPS" | while IFS= read -r a; do
    find "$a" -maxdepth 6 -name places.sqlite 2>/dev/null | while IFS= read -r p; do
      firefox_profile "Tor (in app bundle)" "$(dirname "$p")"
    done
  done
fi
[ -d "$LIB/Caches/TorBrowser-Data" ] && path_stats "Tor cache" "$LIB/Caches/TorBrowser-Data"
for s in "$LIB/Saved Application State/org.torproject.torbrowser.savedState"; do
  [ -d "$s" ] && path_stats "Tor saved window state" "$s"
done
if [ -n "$QDB" ] && [ -f "$QDB" ]; then
  row "Downloads made by Tor (quarantine)" "$(query "$QDB" "select count(*) from LSQuarantineEvent where LSQuarantineAgentBundleIdentifier like '%torproject%' or LSQuarantineAgentName like 'Tor%';")"
  row "Downloads from .onion addresses" "$(query "$QDB" "select count(*) from LSQuarantineEvent where LSQuarantineOriginURLString like '%.onion%' or LSQuarantineDataURLString like '%.onion%';")"
  row "Tor installer downloads (quarantine)" "$(query "$QDB" "select count(*) from LSQuarantineEvent where lower(LSQuarantineDataURLString) like '%torbrowser%' or lower(LSQuarantineDataURLString) like '%torproject%';")"
fi
n=$(find "$HOME/Downloads" -maxdepth 2 -iname '*tor*browser*.dmg' 2>/dev/null | grep -c .)
row "Tor installer files in Downloads" "$n"
[ "$n" -gt 0 ] && loc "$HOME/Downloads"
n=$(defaults read com.apple.dock persistent-apps 2>/dev/null | grep -ci torbrowser)
row "Tor in the Dock" "$( [ "$n" -gt 0 ] && echo yes || echo no )"

# ===========================================================================
# Smaller browsers: a section for each one installed, so each shows on its own.
found_other=0
for f in "zen:Zen" "librewolf:LibreWolf" "Waterfox:Waterfox"; do
  dir="$APPSUP/${f%%:*}/Profiles"
  [ -d "$dir" ] || continue
  found_other=1
  section "${f#*:}"
  about "${f#*:} is built on Firefox and keeps history, bookmarks and the downloads list in the same places.sqlite file, with site icons and your open tabs beside it. Press Shift-Command-Delete in ${f#*:} to clear them." \
    "https://support.mozilla.org/kb/profiles-where-firefox-stores-user-data"
  while IFS= read -r p; do
    firefox_profile "${f#*:} ($(basename "$(dirname "$p")" | cut -d. -f2))" "$(dirname "$p")"
  done < <(find "$dir" -maxdepth 2 -name places.sqlite 2>/dev/null)
done
STP="$LIB/SafariTechnologyPreview"
if [ -d "$STP" ]; then
  found_other=1
  section "Safari Technology Preview"
  about "Apple's preview of the next Safari keeps its own History.db, apart from Safari's, so clearing Safari's history leaves it as it was. Choose History > Clear History in Safari Technology Preview." \
    "https://developer.apple.com/safari/technology-preview/"
  STPDB=$(copy_db "$STP/History.db"); rc=$?
  if [ $rc -eq 0 ]; then
    row "History" "$(span "$(query "$STPDB" "select count(*), date(min(visit_time)+978307200,'unixepoch'), date(max(visit_time)+978307200,'unixepoch') from history_visits;")" visits)"
    loc "$STP/History.db"
    top_hosts "$STPDB" "select i.url from history_visits v join history_items i on i.id = v.history_item;"
  elif [ $rc -ne 1 ] || ! ls "$STP" >/dev/null 2>&1; then
    blocked "History"; loc "$STP" force
  else
    row "History" "not found"
  fi
fi
if [ -d "$APPSUP/Orion" ]; then
  found_other=1
  section "Orion"
  about "Kagi's Orion browser keeps history, site icons and caches in its own data folder. Clear them from Orion's History menu." "https://kagi.com/orion/"
  path_stats "Orion data" "$APPSUP/Orion"
fi
for d in "$LIB/Containers/com.duckduckgo.macos.browser" "$APPSUP/com.duckduckgo.macos.browser"; do
  [ -d "$d" ] || continue
  if [ "$found_other" != duck ]; then
    section "DuckDuckGo"
    about "The DuckDuckGo browser keeps history, site icons and the sites you've fireproofed in its own data folder. Its Fire button clears them."
  fi
  found_other=duck
  path_stats "DuckDuckGo data" "$d"
done
if [ "$found_other" = 0 ]; then
  section "Other browsers"
  about "Smaller browsers keep the same kinds of records as the big ones: Zen, LibreWolf and Waterfox, which are built on Firefox, Safari Technology Preview, Orion and DuckDuckGo. Each one installed here gets a section of its own." \
    "https://support.mozilla.org/kb/profiles-where-firefox-stores-user-data"
  row "Zen, LibreWolf, Waterfox, Orion, DuckDuckGo, Safari Technology Preview" "none installed"
fi

# ===========================================================================
section "Browser extensions"
about "Extensions run inside your browser. Many can read and change every page you visit, which means they see what you browse, and some keep their own history or send it to their maker. Extensions you no longer use are worth removing." \
  "https://support.google.com/chrome_webstore/answer/2664769"
# The name in a Chrome extension's manifest, looked up in its messages
# file when the manifest only names a message.
ext_name() {
  local dir="$1" name key loc
  name=$(plutil -extract name raw "$dir/manifest.json" 2>/dev/null)
  case "$name" in
    __MSG_*__)
      key=${name#__MSG_}; key=${key%__}
      loc=$(plutil -extract default_locale raw "$dir/manifest.json" 2>/dev/null)
      for l in "$loc" en en_US en_GB; do
        [ -f "$dir/_locales/$l/messages.json" ] || continue
        # Message names aren't case-sensitive; files usually use lower case.
        name=$(plutil -extract "$key.message" raw "$dir/_locales/$l/messages.json" 2>/dev/null \
          || plutil -extract "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]').message" raw "$dir/_locales/$l/messages.json" 2>/dev/null)
        [ -n "$name" ] && break
      done ;;
  esac
  echo "${name:-$(basename "$(dirname "$dir")")}"
}
ALL_SITES='"(<all_urls>|\*://\*/\*|https?://\*/\*)"'
# Extensions that can read every site first, then the rest, each by name.
every_site_first() { local l; l=$(cat); { grep ' (every site)$' <<< "$l" | sort; grep -v ' (every site)$' <<< "$l" | sort; } | grep .; }
found_ext=0
for b in "Google/Chrome" "Google/Chrome Beta" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc/User Data" "Vivaldi" "Chromium" "com.operasoftware.Opera"; do
  [ -d "$APPSUP/$b" ] || continue
  while IFS= read -r h; do
    prof=$(dirname "$h")
    [ -d "$prof/Extensions" ] || continue
    found_ext=1
    n=0; all=0; list=""
    for e in "$prof/Extensions"/*/; do
      v=$(ls -d "$e"*/ 2>/dev/null | tail -1)
      [ -f "$v/manifest.json" ] || continue
      # Chrome's own helpers have no page access and aren't listed.
      grep -q '"update_url"' "$v/manifest.json" 2>/dev/null || [ -d "$v/_metadata" ] || continue
      n=$((n + 1))
      if grep -Eq "$ALL_SITES" "$v/manifest.json"; then all=$((all + 1)); list="$list$(ext_name "${v%/}") (every site)"$'\n'
      else list="$list$(ext_name "${v%/}")"$'\n'; fi
    done
    label="$(browser_name "$b") ($(basename "$prof")) extensions"
    if [ "$n" -gt 0 ]; then row "$label" "$n extensions, $all can read every site"; else row "$label" "0"; fi
    loc "$prof/Extensions"
    printf '%s' "$list" | every_site_first | while IFS= read -r x; do [ -n "$x" ] && item "" "$x"; done
  done < <(find "$APPSUP/$b" -maxdepth 2 -name History -type f 2>/dev/null)
done
while IFS= read -r p; do
  prof=$(dirname "$p")
  found_ext=1
  case "$prof" in */zen/*) name=Zen ;; */librewolf/*) name=LibreWolf ;; */Waterfox/*) name=Waterfox ;; *) name=Firefox ;; esac
  total=$(plutil -extract addons raw "$p" 2>/dev/null || echo 0)
  n=0; all=0; list=""
  for ((i = 0; i < total; i++)); do
    [ "$(plutil -extract "addons.$i.type" raw "$p" 2>/dev/null)" = extension ] || continue
    [ "$(plutil -extract "addons.$i.location" raw "$p" 2>/dev/null)" = app-profile ] || continue
    n=$((n + 1))
    x=$(plutil -extract "addons.$i.defaultLocale.name" raw "$p" 2>/dev/null)
    if plutil -extract "addons.$i.userPermissions.origins" json -o - "$p" 2>/dev/null | grep -Eq "$ALL_SITES"; then
      all=$((all + 1)); list="$list$x (every site)"$'\n'
    else list="$list$x"$'\n'; fi
  done
  row "$name ($(basename "$prof" | cut -d. -f2)) extensions" "$( [ "$n" -gt 0 ] && echo "$n extensions, $all can read every site" || echo 0)"
  loc "$p"
  printf '%s' "$list" | every_site_first | while IFS= read -r x; do [ -n "$x" ] && item "" "$x"; done
done < <(find "$APPSUP/Firefox/Profiles" "$APPSUP/zen/Profiles" "$APPSUP/librewolf/Profiles" "$APPSUP/Waterfox/Profiles" -maxdepth 2 -name extensions.json 2>/dev/null)
n=$(pluginkit -m -p com.apple.Safari.web-extension 2>/dev/null | grep -c .)
row "Safari web extensions" "$n"
[ $found_ext = 0 ] && [ "$n" = 0 ] && row "Chrome-family and Firefox extensions" "none installed"

# ===========================================================================
section "Cookies and site data"
about "Cookies keep you signed in and remember settings, and tracking cookies follow you from site to site. Sites also store data in your browser: local storage, databases and offline copies. Clearing history leaves all of this in place, and it names every site that set it." \
  "https://support.google.com/chrome/answer/95647"
for b in "Google/Chrome" "Google/Chrome Beta" "BraveSoftware/Brave-Browser" "Microsoft Edge" "Arc/User Data" "Vivaldi" "Chromium" "com.operasoftware.Opera"; do
  [ -d "$APPSUP/$b" ] || continue
  while IFS= read -r h; do
    prof=$(dirname "$h"); label="$(browser_name "$b") ($(basename "$prof"))"
    ck="$prof/Cookies"; [ -f "$prof/Network/Cookies" ] && ck="$prof/Network/Cookies"
    if [ -f "$ck" ]; then
      db=$(copy_db "$ck")
      if [ -n "$db" ]; then
        IFS='|' read -r c s <<< "$(query "$db" "select count(*), count(distinct host_key) from cookies;")"
        row "$label cookies" "${c:-0} cookies, ${s:-0} sites"
        loc "$ck"
      fi
    fi
    stores=()
    for d in "Local Storage" "IndexedDB" "Service Worker" "Session Storage" "File System"; do [ -d "$prof/$d" ] && stores+=("$prof/$d"); done
    if [ ${#stores[@]} -gt 0 ]; then
      row "$label site storage" "$(du -sch "${stores[@]}" 2>/dev/null | tail -1 | cut -f1 | tr -d ' ')"
      loc "$prof"
    fi
  done < <(find "$APPSUP/$b" -maxdepth 2 -name History -type f 2>/dev/null)
done
while IFS= read -r p; do
  prof=$(dirname "$p")
  case "$prof" in */zen/*) name=Zen ;; */librewolf/*) name=LibreWolf ;; */Waterfox/*) name=Waterfox ;; *TorBrowser*) continue ;; *) name=Firefox ;; esac
  db=$(copy_db "$p")
  [ -n "$db" ] || continue
  IFS='|' read -r c s <<< "$(query "$db" "select count(*), count(distinct host) from moz_cookies;")"
  row "$name ($(basename "$prof" | cut -d. -f2)) cookies" "${c:-0} cookies, ${s:-0} sites"
  loc "$p"
  [ -d "$prof/storage" ] && path_stats "$name ($(basename "$prof" | cut -d. -f2)) site storage" "$prof/storage"
done < <(find "$APPSUP/Firefox/Profiles" "$APPSUP/zen/Profiles" "$APPSUP/librewolf/Profiles" "$APPSUP/Waterfox/Profiles" -maxdepth 2 -name cookies.sqlite 2>/dev/null)
path_stats "Safari cookies" "$LIB/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
path_stats "Safari site storage" "$LIB/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData"

# ===========================================================================
section "Thumbnails and previews"
about "When Finder shows a file's icon preview, or you press Space to look at a file, macOS saves a small thumbnail in this hidden system cache. Thumbnails stay after the original file is deleted. Running qlmanage -r cache in Terminal resets it." \
  "https://eclecticlight.co/?s=QuickLook+thumbnail+cache"
UCD="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null)"
QL="${UCD}com.apple.quicklook.ThumbnailsAgent/com.apple.QuickLook.thumbnailcache"
[ -d "${UCD}com.apple.quicklook.ThumbnailsAgent" ] || QL="${UCD}com.apple.QuickLook.thumbnailcache"
path_stats "Quick Look thumbnail cache" "$QL"
if [ -f "$QL/index.sqlite" ]; then
  QLDB=$(copy_db "$QL/index.sqlite")
  [ -n "$QLDB" ] && row "Files with cached thumbnails" "$(query "$QLDB" "select count(*) from files;")"
fi

# ===========================================================================
section "Recent items and window state"
about "macOS keeps lists of recently used documents, apps and servers: Apple menu > Recent Items, and File > Open Recent in each app. Finder separately remembers recent folders for Go > Go to Folder." \
  "https://eclecticlight.co/?s=sharedfilelist"
SFL="$APPSUP/com.apple.sharedfilelist"
if [ ! -d "$SFL" ]; then
  row "System recent-item lists" "not found"
elif ! ls "$SFL" >/dev/null 2>&1; then
  blocked "System recent-item lists"; loc "$SFL"
else
  row "System recent-item lists" "$(ls "$SFL" | grep -c 'sfl')"; loc "$SFL"
fi
path_stats "Per-app recent documents" "$APPSUP/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"
n=$(defaults read com.apple.finder FXRecentFolders 2>/dev/null | grep -c 'name =')
row "Finder recent folders" "$n"
path_stats "Saved Application State (all apps)" "$LIB/Saved Application State"
about "This is macOS Resume: when an app quits, its open windows are saved so they come back next time. For browsers this can include window titles, which are page titles. Apps of interest:" \
  "https://eclecticlight.co/?s=Saved+Application+State"
ls "$LIB/Saved Application State" 2>/dev/null \
  | grep -Ei 'safari|chrome|firefox|torproject|brave|edge|arc|opera|vivaldi|vlc|iina|quicktime|preview|telegram|whatsapp' \
  | while IFS= read -r s; do item "" "${s%.savedState}" "$LIB/Saved Application State/$s"; done

# ===========================================================================
section "Code editors and IDEs"
about "Code editors keep their own lists of the folders and files you've opened, apart from macOS's Recent Items, and clearing those leaves these in place. VS Code and editors built on it also keep the history of their built-in terminal, every command typed there, and a folder of saved state for each project ever opened, which stays after the project is deleted." \
  "https://code.visualstudio.com/docs/editor/command-line#_opening-vs-code-with-urls"
found_ed=0
for e in "Code:VS Code" "Code - Insiders:VS Code Insiders" "Cursor:Cursor" "VSCodium:VSCodium" "Windsurf:Windsurf"; do
  dir="$APPSUP/${e%%:*}/User"; name="${e#*:}"
  [ -d "$dir" ] || continue
  found_ed=1
  st="$dir/globalStorage/state.vscdb"
  if [ -f "$st" ]; then
    db=$(copy_db "$st")
    if [ -n "$db" ]; then
      n=$(query "$db" "select ifnull(sum(json_array_length(value, '\$.entries')), 0) from ItemTable where key = 'history.recentlyOpenedPathsList';")
      row "$name: recently opened" "$(plural "${n:-0}" "folder or file" "folders and files")"; loc "$st"
      c=$(query "$db" "select ifnull(sum(json_array_length(value, '\$.entries')), 0) from ItemTable where key = 'terminal.history.entries.commands';")
      f=$(query "$db" "select ifnull(sum(json_array_length(value, '\$.entries')), 0) from ItemTable where key = 'terminal.history.entries.dirs';")
      if [ "${c:-0}" -gt 0 ] || [ "${f:-0}" -gt 0 ]; then row "$name: terminal history" "$(plural "${c:-0}" command), $(plural "${f:-0}" folder)" found; loc "$st"
      else row "$name: terminal history" "0"; fi
    fi
  fi
  ws="$dir/workspaceStorage"
  if [ -d "$ws" ]; then
    total=0; gone=0
    for w in "$ws"/*/workspace.json; do
      [ -f "$w" ] || continue
      total=$((total + 1))
      u=$(sed -n 's/.*"folder": *"file:\/\/\([^"]*\)".*/\1/p' "$w" | head -1)
      [ -n "$u" ] || continue
      u=$(printf '%b' "${u//%/\\x}")
      case "$u" in /Volumes/*) continue ;; esac
      [ -e "$u" ] || gone=$((gone + 1))
    done
    if [ "$total" -gt 0 ]; then row "$name: projects it keeps state for" "$(plural "$total" folder), $gone no longer $([ "$gone" = 1 ] && echo exists || echo exist)"; loc "$ws"
    else row "$name: projects it keeps state for" "0"; fi
  fi
done
for d in "$APPSUP"/JetBrains/* "$APPSUP"/Google/AndroidStudio*; do
  f="$d/options/recentProjects.xml"
  [ -f "$f" ] || continue
  found_ed=1
  name=$(basename "$d" | sed -E 's/^AndroidStudio/Android Studio/; s/([A-Za-z])([0-9])/\1 \2/')
  row "$name: recent projects" "$(plural "$(grep -c '<RecentProjectMetaInfo' "$f")" project)"; loc "$f"
done
for d in "$APPSUP/Sublime Text" "$APPSUP/Sublime Text 3"; do
  f="$d/Local/Session.sublime_session"
  [ -f "$f" ] || continue
  found_ed=1
  row "Sublime Text: session and recent files" "modified $(day "$(stat -f '%m' "$f")")"; loc "$f"
done
[ $found_ed = 0 ] && row "VS Code, Cursor, JetBrains, Sublime Text" "none installed"

# ===========================================================================
section "Keyboard and spelling"
about "macOS learns from what you type. Words you teach the spell checker go in a list, and the keyboard keeps a model of the words and phrases you use for its suggestions and autocorrection, including words you've stopped it correcting. Together they can show names, places and terms you've typed." \
  "https://support.apple.com/guide/mac-help/typing-suggestions-correct-mistakes-mac-mchlp2299/mac"
if [ -f "$LIB/Spelling/LocalDictionary" ]; then
  row "Learned spellings" "$(grep -c . "$LIB/Spelling/LocalDictionary") words"
  loc "$LIB/Spelling/LocalDictionary"
else
  row "Learned spellings" "0"
fi
path_stats "Typing suggestions and autocorrection data" "$LIB/Keyboard"

# ===========================================================================
section "Media players"
about "VLC and IINA keep their own recently played lists (File > Open Recent), and IINA also caches thumbnails for its timeline previews."
if [ -f "$LIB/Preferences/org.videolan.vlc.plist" ]; then
  row "VLC recently played" "$(defaults read org.videolan.vlc recentlyPlayedMedia 2>/dev/null | grep -c '=')"
  loc "$LIB/Preferences/org.videolan.vlc.plist"
else
  row "VLC" "not found"
fi
IINA="$APPSUP/com.colliderli.iina"
if [ -d "$IINA" ]; then path_stats "IINA history and thumbnails" "$IINA"; else row "IINA" "not found"; fi

# ===========================================================================
section "Photos and messaging"
about "Photos keeps deleted items in Recently Deleted for 30 days before removing them, and Hidden items stay in the library. Messaging apps store every photo and video you send or receive as ordinary files, apart from the chat, and deleting a conversation doesn't always remove them." \
  "https://support.apple.com/guide/photos/delete-photos-videos-recover-deleted-pht3bfab2f96/mac"
PDB_SRC="$HOME/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"
if [ -f "$PDB_SRC" ]; then
  PDB=$(copy_db "$PDB_SRC")
  if [ -n "$PDB" ]; then
    row "Photos: Recently Deleted" "$(span "$(query "$PDB" "select count(*), date(min(ZTRASHEDDATE)+978307200,'unixepoch'), date(max(ZTRASHEDDATE)+978307200,'unixepoch') from ZASSET where ZTRASHEDSTATE = 1;")" items)"
    row "Photos: Hidden album" "$(query "$PDB" "select count(*) from ZASSET where ZHIDDEN = 1 and ZTRASHEDSTATE = 0;") items"
    about "Review these in the Photos app sidebar, under Utilities: Recently Deleted and Hidden."
  else
    blocked "Photos library database"
  fi
else
  row "Photos library" "not found in ~/Pictures"
fi
path_stats "Messages attachments" "$LIB/Messages/Attachments"
path_stats "WhatsApp media" "$LIB/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"
TG=$(ls -d "$LIB/Group Containers/"*.ru.keepcoder.Telegram 2>/dev/null | head -1)
if [ -n "$TG" ]; then path_stats "Telegram data" "$TG"; else row "Telegram data" "not found"; fi
path_stats "Signal attachments" "$APPSUP/Signal/attachments.noindex"
path_stats "Discord cache" "$APPSUP/discord/Cache"

# ===========================================================================
section "Location in photos"
about "A photo taken on a phone records where it was taken, often to within a few metres, and the location goes with the file when it's emailed, sent by AirDrop or uploaded to a site that keeps it. Home, school and work show up in photos people share without a second thought. Counted here from Spotlight, for photos outside the Photos library." \
  "https://support.apple.com/guide/photos/view-photos-by-location-phtfbb7a1b7a/mac"
total=0
for d in Downloads Desktop Documents Pictures; do
  [ -d "$HOME/$d" ] || continue
  n=$(mdfind -onlyin "$HOME/$d" 'kMDItemLatitude == * && kMDItemContentTypeTree == "public.image"' 2>/dev/null | grep -v '\.photoslibrary/' | grep -c .)
  total=$((total + n))
  eval "loc_$d=$n"
done
row "Photos that record where they were taken" "$(plural "$total" photo)"
for d in Downloads Desktop Documents Pictures; do
  eval "n=\${loc_$d:-0}"
  [ "$n" -gt 0 ] && item "$n" "$d" "$HOME/$d"
done
about "TrailSift's Photo Locations page lists them with where each was taken, and makes copies without the location for sharing. The originals stay as they are. To share from Photos without it, click Options in the Share or Export window and turn off Location."

# ===========================================================================
section "Mail and documents"
about "Opening an attachment in Mail saves a copy in Mail Downloads, which can stay after the message is deleted. Preview and TextEdit keep autosaved copies of documents you haven't saved yet. Word, Excel and PowerPoint remember every file they've opened, so they can reopen it from the File menu." \
  "https://support.apple.com/guide/mail/view-save-or-delete-email-attachments-mlhlp1123/mac"
path_stats "Mail Downloads" "$LIB/Containers/com.apple.mail/Data/Library/Mail Downloads"
for a in Preview TextEdit; do
  d="$LIB/Containers/com.apple.$a/Data/Library/Autosave Information"
  [ -d "$d" ] && path_stats "$a autosaved documents" "$d"
done
for a in Word Excel PowerPoint; do
  bm="$LIB/Containers/com.microsoft.$a/Data/Library/Preferences/com.microsoft.$a.securebookmarks.plist"
  [ "$a" = PowerPoint ] && [ ! -f "$bm" ] && bm="$LIB/Containers/com.microsoft.Powerpoint/Data/Library/Preferences/com.microsoft.Powerpoint.securebookmarks.plist"
  [ -f "$bm" ] || continue
  row "$a: files it can reopen" "$(plutil -convert xml1 -o - "$bm" 2>/dev/null | grep -c '<key>file:') files"
  loc "$bm"
done
# Everyone you've emailed or messaged, kept by macOS to suggest them again,
# including people who aren't in Contacts. The store is private to macOS, so
# its rows are counted from whichever table names them.
REC="$LIB/Containers/com.apple.corerecents.recentsd/Data/Library/Recents"
if [ -d "$REC" ] && ls "$REC" >/dev/null 2>&1; then
  n=""
  for f in "$REC"/*; do
    case "$f" in *-wal|*-shm) continue ;; esac
    [ "$(head -c 15 "$f" 2>/dev/null)" = "SQLite format 3" ] || continue
    db=$(copy_db "$f") || continue
    if [ -n "$(query "$db" "select 1 from sqlite_master where type = 'table' and name = 'contacts';")" ]; then
      n=$(query "$db" "select count(distinct lower(address)) from contacts where ifnull(address, '') <> '';")
    else
      t=$(query "$db" "select name from sqlite_master where type = 'table' and name like '%recent%' order by length(name) limit 1;")
      [ -n "$t" ] && n=$(query "$db" "select count(*) from \"$t\";")
    fi
  done
  if [ -n "$n" ]; then row "Remembered addresses (Mail and Messages)" "$n addresses"; loc "$REC"
  else path_stats "Remembered addresses (Mail and Messages)" "$REC"; fi
else
  path_stats "Remembered addresses (Mail and Messages)" "$REC"
fi
about "Office's recent files are cleared in each app: Control-click a file under File > Open Recent and choose to clear the list, or remove files one at a time." \
  "https://support.microsoft.com/en-gb/office/customize-the-list-of-recently-used-files-in-office-apps-b70b195a-eaba-4750-87d3-d9723820137e"

# ===========================================================================
section "Meeting and chat apps"
about "Zoom saves meetings you record on this Mac in Documents/Zoom. Slack and Teams are built on a web browser, and their data folders hold a cache of the images, files and pages you've viewed in them, as well as sign-in data. Clearing the cache keeps your messages, which stay on the service." \
  "https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-administration/clear-teams-cache"
found_chat=0
if [ -d "$APPSUP/zoom.us" ]; then found_chat=1; path_stats "Zoom data" "$APPSUP/zoom.us/data"; fi
if [ -d "$HOME/Documents/Zoom" ]; then found_chat=1; path_stats "Zoom recordings" "$HOME/Documents/Zoom"; fi
for d in "$LIB/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack" "$APPSUP/Slack"; do
  [ -d "$d" ] || continue
  found_chat=1; path_stats "Slack data" "$d"
done
d="$LIB/Containers/com.microsoft.teams2/Data/Library/Application Support/Microsoft/MSTeams"
if [ -d "$d" ]; then found_chat=1; path_stats "Teams data" "$d"; fi
if [ -d "$APPSUP/Microsoft/Teams" ]; then found_chat=1; path_stats "Teams (classic) data" "$APPSUP/Microsoft/Teams"; fi
[ $found_chat = 0 ] && row "Zoom, Slack, Teams" "none installed"

# ===========================================================================
section "Shell history, clipboard and printing"
about "The shell saves every command typed in Terminal, which can include file names, server addresses and, by mistake, passwords. Terminal also keeps a history per window so it can restore them. Clipboard managers keep everything you copy, and macOS keeps a record of each finished print job." \
  "https://zsh.sourceforge.io/Doc/Release/Options.html"
for h in .zsh_history .bash_history; do
  [ -f "$HOME/$h" ] || continue
  row "Shell history ($h)" "$(grep -c . "$HOME/$h" 2>/dev/null) commands, modified $(day "$(stat -f '%m' "$HOME/$h")")"
  loc "$HOME/$h"
done
[ -d "$HOME/.zsh_sessions" ] && path_stats "Terminal window histories" "$HOME/.zsh_sessions"
found_clip=0
for c in "Maccy:$LIB/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy" \
         "Paste:$LIB/Containers/com.wiheads.paste/Data/Library/Application Support/Paste" \
         "Pastebot:$LIB/Containers/com.tapbots.Pastebot2Mac/Data/Library/Application Support" \
         "Alfred clipboard:$APPSUP/Alfred/Databases/clipboard.alfdb" \
         "Raycast:$APPSUP/com.raycast.macos" \
         "CopyClip:$LIB/Containers/com.fiplab.copyclip2/Data/Library/Application Support"; do
  [ -e "${c#*:}" ] || continue
  found_clip=1; path_stats "${c%%:*} history" "${c#*:}"
done
[ $found_clip = 0 ] && row "Clipboard managers" "none installed"
about "Clear a clipboard manager's history from its own menu or settings." "https://github.com/p0deje/Maccy"
jobs=$(lpstat -W completed -o 2>/dev/null | awk -v u="$(id -un)" '$2 == u')
n=$(printf '%s' "$jobs" | grep -c .)
if [ "$n" -gt 0 ]; then
  newest=$(head -1 <<< "$jobs" | awk '{print $4, $5, $6, $7, $8}')
  oldest=$(tail -1 <<< "$jobs" | awk '{print $4, $5, $6, $7, $8}')
  row "Finished print jobs" "$n entries, $(date -j -f '%a %b %e %T %Y' "$oldest" '+%Y-%m-%d' 2>/dev/null) to $(date -j -f '%a %b %e %T %Y' "$newest" '+%Y-%m-%d' 2>/dev/null)"
else
  row "Finished print jobs" "0"
fi
about "macOS's printing system keeps a list of finished jobs, with the printer, size and time of each, and lpstat -W completed shows it. An administrator can clear it in Terminal with sudo cancel -a -x, which also cancels anything still waiting to print." \
  "https://www.cups.org/doc/man-cancel.html"

# ===========================================================================
section "Trash and Downloads"
about "Files in the Trash still exist until it's emptied. Downloads holds everything browsers and apps saved, and is often never cleared."
path_stats "Trash" "$HOME/.Trash"
if [ -d "$HOME/Downloads" ]; then
  times=$(find "$HOME/Downloads" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.webp' -o -iname '*.heic' -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.m4v' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.avi' \) -exec stat -f '%m' {} + 2>/dev/null | sort -n)
  n=$(printf '%s' "$times" | grep -c .)
  if [ "$n" -gt 0 ]; then
    row "Images and videos in Downloads" "$n files, $(day "$(head -1 <<< "$times")") to $(day "$(tail -1 <<< "$times")")"
  else
    row "Images and videos in Downloads" "0"
  fi
  loc "$HOME/Downloads"
fi

# ===========================================================================
section "Activity databases (Screen Time, Siri, app usage)"
about "These databases power Screen Time, Siri Suggestions and other on-device intelligence. They are some of the most detailed records on a Mac, and forensic examiners use them to rebuild a timeline of what was used and when." \
  "https://support.apple.com/guide/mac-help/set-up-screen-time-for-yourself-mchle4e2edfe/mac"
path_stats "knowledgeC.db" "$APPSUP/Knowledge/knowledgeC.db"
about "knowledgeC.db is the older activity database: which app was in front and for how long, when the Mac was locked and unlocked, what media was playing and, with Screen Time on, which websites were used." \
  "https://rud.is/b/2019/10/28/spelunking-macos-screentime-app-usage-with-r/"
path_stats "Biome streams" "$LIB/Biome"
about "Biome is Apple's newer system for the same job and has been taking over from knowledgeC. It stores activity as many small stream files, one stream per kind of event, such as app use, media and notifications. In macOS 26 Tahoe a new stream records the name of every menu command you choose. Some streams sync to your other devices through iCloud." \
  "https://unit42.paloaltonetworks.com/new-macos-artifact-discovered/"

# ===========================================================================
section "Notification history"
about "macOS keeps the notifications apps have shown, with their text, in a database of its own: a message preview, a code sent by text, a calendar invitation. Notifications you've dismissed can stay there for days, and other clean-up tools leave it alone. It's protected, so reading it needs Full Disk Access." \
  "https://support.apple.com/guide/mac-help/change-notifications-settings-mh40583/mac"
NDB_SRC="$LIB/Group Containers/group.com.apple.usernoted/db2/db"
[ -e "$NDB_SRC" ] || [ ! -e "$(getconf DARWIN_USER_DIR 2>/dev/null)com.apple.notificationcenter/db2/db" ] || NDB_SRC="$(getconf DARWIN_USER_DIR)com.apple.notificationcenter/db2/db"
NDB=""
[ -f "$NDB_SRC" ] && NDB=$(copy_db "$NDB_SRC" 2>/dev/null)
if [ -n "$NDB" ] && [ -n "$(query "$NDB" "select 1 from sqlite_master where name = 'record';")" ]; then
  n=$(query "$NDB" "select count(*) from record;")
  apps=$(query "$NDB" "select count(distinct app_id) from record;")
  if [ "${n:-0}" -gt 0 ]; then
    range=$(query "$NDB" "select date(min(delivered_date) + 978307200, 'unixepoch'), date(max(delivered_date) + 978307200, 'unixepoch') from record where delivered_date > 0;")
    row "Notifications kept" "$(plural "$n" notification) from $(plural "$apps" app)${range:+, ${range%%|*} to ${range#*|}}"
    loc "$NDB_SRC"
    query "$NDB" "select a.identifier, count(*) from record r join app a on a.app_id = r.app_id group by a.identifier order by 2 desc limit 8;" \
      | while IFS='|' read -r id count; do item "$count" "$id"; done
  else
    row "Notifications kept" "0"
  fi
elif [ -n "$NDB" ]; then
  path_stats "Notifications kept" "$NDB_SRC"
elif [ -e "$NDB_SRC" ] || { [ -e "$LIB/Group Containers/group.com.apple.usernoted" ] && ! ls "$LIB/Group Containers/group.com.apple.usernoted" >/dev/null 2>&1; }; then
  blocked "Notifications kept"; loc "$NDB_SRC" force
else
  row "Notifications kept" "not found"
fi
about "To keep message text out of it, set Show previews to When Unlocked or Never in System Settings > Notifications, and turn off Show in Notification Centre for apps whose notifications you'd rather weren't kept. Clearing notifications in Notification Centre removes them."

# ===========================================================================
section "Startup items left by removed apps"
about "Apps that start helpers at login or in the background install launch agents and daemons. Removing an app by dragging it to the Trash usually leaves them, and macOS tries to start their missing programs at every login. The ones in /Library work for every account and need an administrator to remove." \
  "https://support.apple.com/guide/terminal/script-management-with-launchd-apdc6c1077b-5d5d-4d35-9c19-60f2397b2369/mac"
# The program a launch item runs, if it names one by full path.
launch_program() {
  local p
  p=$(plutil -extract Program raw "$1" 2>/dev/null || plutil -extract ProgramArguments.0 raw "$1" 2>/dev/null)
  case "$p" in /*) echo "$p" ;; esac
}
for scope in "Your launch agents:$LIB/LaunchAgents" "Launch agents for every account:$SYSLIB/LaunchAgents" "Launch daemons:$SYSLIB/LaunchDaemons"; do
  dir="${scope#*:}"; label="${scope%%:*}"
  stale=""
  for f in "$dir"/*.plist; do
    [ -f "$f" ] || continue
    prog=$(launch_program "$f")
    [ -n "$prog" ] && [ ! -e "$prog" ] && stale="$stale$f"$'\n'
  done
  n=$(printf '%s' "$stale" | grep -c .)
  row "$label whose app is gone" "$n"
  if [ "$n" -gt 0 ]; then
    loc "$dir"
    printf '%s' "$stale" | while IFS= read -r f; do [ -n "$f" ] && item "" "$(basename "$f" .plist)" "$f"; done
  fi
done

# ===========================================================================
section "iPhone and iPad backups"
about "When an iPhone or iPad is backed up to this Mac in Finder, the whole device is copied here: messages, photos, call history, Safari history and app data, unless the backup is encrypted. Backups of old devices stay until they're deleted, and they're often the largest forgotten files on a Mac." \
  "https://support.apple.com/en-us/108809"
MS="$APPSUP/MobileSync/Backup"
if [ ! -d "$MS" ]; then
  row "Device backups" "not found"
elif ! ls "$MS" >/dev/null 2>&1; then
  blocked "Device backups"; loc "$MS"
else
  n=0
  for d in "$MS"/*/; do
    [ -f "$d/Info.plist" ] || continue
    n=$((n + 1))
    dev=$(plutil -extract "Device Name" raw "$d/Info.plist" 2>/dev/null || echo "Device")
    when=$(plutil -extract "Last Backup Date" raw "$d/Info.plist" 2>/dev/null | cut -c1-10)
    enc=$(plutil -extract IsEncrypted raw "$d/Manifest.plist" 2>/dev/null)
    row "Backup of $dev" "$(du -sh "$d" 2>/dev/null | cut -f1 | tr -d ' '), last backed up ${when:-unknown}$( [ "$enc" = true ] && echo ', encrypted' || echo ', not encrypted')"
    loc "${d%/}"
  done
  [ "$n" = 0 ] && row "Device backups" "0"
fi

# ===========================================================================
section "Remembered Wi-Fi networks"
about "Your Mac remembers every Wi-Fi network it has joined so it can join again. The list of names is a record of where the Mac has been: homes, offices, hotels, cafés and airports. It syncs to your other devices through iCloud Keychain." \
  "https://support.apple.com/guide/mac-help/reset-or-remove-wi-fi-network-settings-on-mac-mchl6129bcb2/mac"
WIFI=$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/ { getline; print $2; exit }')
if [ -z "$WIFI" ]; then
  row "Wi-Fi" "not found"
else
  nets=$(networksetup -listpreferredwirelessnetworks "$WIFI" 2>/dev/null | tail -n +2 | sed 's/^[[:space:]]*//')
  row "Remembered networks" "$(printf '%s' "$nets" | grep -c .)"
  if [ "$VERBOSE" = 1 ]; then printf '%s\n' "$nets" | while IFS= read -r x; do [ -n "$x" ] && item "" "$x"; done; fi
fi

# ===========================================================================
section "Copies elsewhere"
about "Deleting a file on this Mac doesn't delete copies elsewhere. With iCloud Desktop & Documents on, those two folders also live in iCloud and on your other devices. Safari, Photos and Messages can sync too: check System Settings > Apple Account > iCloud." \
  "https://support.apple.com/en-us/109344"
if defaults read MobileMeAccounts Accounts 2>/dev/null | grep -q AccountID; then
  row "iCloud" "signed in"
  [ -d "$LIB/Mobile Documents/com~apple~CloudDocs/Desktop" ] && row "iCloud Desktop & Documents" "on"
else
  row "iCloud" "not signed in"
fi
dest=$(tmutil destinationinfo 2>/dev/null | awk -F': ' '/^Name/ {print $2}' | paste -sd ',' -)
row "Time Machine destinations" "${dest:-none}"
last=$(tmutil latestbackup 2>/dev/null | xargs basename 2>/dev/null)
[ -n "$last" ] && row "Latest backup" "$last"
n=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple')
row "Local APFS snapshots" "$n"
about "Time Machine backups and local snapshots keep files as they were when the backup was made, even after you delete them here." \
  "https://support.apple.com/en-us/102154"

# ===========================================================================
if [ "$DEEP" = 1 ]; then
  section "Deep scan: images and videos outside the Photos library"
  about "Finds image and video files outside the Photos library and lists the 20 busiest folders. Visible folders come from the Spotlight index. Library and hidden folders are checked by reading each file's first bytes, so images saved without a file extension are found too. iCloud and cloud-storage folders are skipped so nothing downloads."
  row "Visible folders (Spotlight)" "busiest folders below"
  mdfind -onlyin "$HOME" "kMDItemContentTypeTree == 'public.image' || kMDItemContentTypeTree == 'public.movie'" 2>/dev/null \
    | grep -v '\.photoslibrary/' | group_by_folder

  row "Library and hidden folders (content checked)" "busiest folders below"
  {
    find "$LIB" \
      \( -path "$LIB/Mobile Documents" -o -path "$LIB/CloudStorage" -o -name '*.photoslibrary' -o -path "$LIB/Mail" \) -prune \
      -o -type f -size +2k -print0 2>/dev/null
    for d in "$HOME"/.[!.]*; do
      [ -d "$d" ] && [ "$d" != "$HOME/.Trash" ] && find "$d" -type f -size +2k -print0 2>/dev/null
    done
  } | xargs -0 file -N -I 2>/dev/null \
    | grep -E ':[[:space:]]+(image|video)/' \
    | sed -E 's/:[[:space:]]+[a-z]+\/[^:]*$//' \
    | group_by_folder
fi

# ===========================================================================
if [ "$JSON" = 1 ]; then
  printf '{"t":"done","needFullDiskAccess":%s}\n' "$( [ "$NEED_FDA" = 1 ] && echo true || echo false )"
else
  section "Done"
  if [ "$NEED_FDA" = 1 ]; then
    flag "Some locations were blocked. Grant your terminal Full Disk Access and run again for a full audit."
    about "" "https://support.apple.com/guide/mac-help/control-access-to-files-and-folders-on-mac-mchld5a35146/mac"
  fi
  note "Nothing was changed. Temporary database copies have been removed."
fi
