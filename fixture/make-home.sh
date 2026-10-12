#!/bin/bash
# Build a fake home folder with known traces, for testing the audit script.
# The word "zebrafixture" is planted once in each place the word search covers.
#   Tests/Fixtures/make-home.sh DIR
#
# DIR must not exist yet. Every value here is asserted on in the tests, so
# change both together.
set -e
H="$1"
[ -n "$H" ] && [ ! -e "$H" ] || { echo "usage: make-home.sh NEW_DIR" >&2; exit 1; }

L="$H/Library"
AS="$L/Application Support"
mkdir -p "$L/Preferences" "$AS/Google/Chrome/Default" "$AS/Firefox/Profiles/x.default-release" \
  "$AS/TorBrowser-Data/Browser/abc.default" "$AS/TorBrowser-Data/Tor" "$L/Caches/Google/Chrome" \
  "$L/Saved Application State/org.torproject.torbrowser.savedState" "$H/Downloads" "$H/.hidden" "$H/Documents"

# Download log: one Tor download from an onion address, one Chrome download,
# and the Tor installer downloaded in Safari.
sqlite3 "$L/Preferences/com.apple.LaunchServices.QuarantineEventsV2" "
create table LSQuarantineEvent(LSQuarantineEventIdentifier, LSQuarantineTimeStamp REAL,
  LSQuarantineAgentBundleIdentifier, LSQuarantineAgentName, LSQuarantineDataURLString,
  LSQuarantineSenderName, LSQuarantineSenderAddress, LSQuarantineTypeNumber,
  LSQuarantineOriginTitle, LSQuarantineOriginURLString, LSQuarantineOriginAlias);
insert into LSQuarantineEvent values
  ('a', 600000000, 'org.torproject.torbrowser', 'Tor Browser', 'http://abc.onion/x.jpg', null, null, 0, null, 'http://abc.onion/', null),
  ('b', 700000000, 'com.google.Chrome', 'Google Chrome', 'https://example.com/f.zip', null, null, 0, 'Zebrafixture downloads', 'https://example.com/', null),
  ('c', 650000000, 'com.apple.Safari', 'Safari', 'https://dist.torproject.org/torbrowser/TorBrowser.dmg', null, null, 0, null, null, null);"

# Chrome: two visits to one page and one download.
sqlite3 "$AS/Google/Chrome/Default/History" "
create table urls(id integer primary key, url, title, visit_count default 0, last_visit_time);
create table visits(id integer primary key, url, visit_time);
create table downloads(id integer primary key, start_time, target_path, tab_url, tab_referrer_url);
insert into urls (id, url, title, visit_count, last_visit_time) values (1, 'https://example.com/a', 'A Zebrafixture page', 2, 13350000000000000);
insert into visits values (1, 1, 13300000000000000), (2, 1, 13350000000000000);
insert into downloads values (1, 13340000000000000, '/Users/test/Downloads/f.zip', 'https://example.com/', '');"
head -c 3000 /dev/zero > "$L/Caches/Google/Chrome/blob"

# Chrome site icons: one for example.com and one for another site.
sqlite3 "$AS/Google/Chrome/Default/Favicons" "
create table icon_mapping(id integer primary key, page_url, icon_id, page_url_type default 0);
create table favicons(id integer primary key, url, icon_type);
create table favicon_bitmaps(id integer primary key, icon_id, last_updated, image_data, width, height, last_requested);
insert into favicons values (1, 'https://example.com/favicon.ico', 1), (2, 'https://other.org/favicon.ico', 1);
insert into icon_mapping (page_url, icon_id) values ('https://example.com/a', 1), ('https://other.org/', 2);
insert into favicon_bitmaps (icon_id, width, height) values (1, 16, 16), (2, 16, 16);"

places_schema="
create table moz_places(id integer primary key, url, title, last_visit_date);
create table moz_historyvisits(id, place_id, visit_date);
create table moz_bookmarks(id, type, fk);
create table moz_annos(id, anno_attribute_id);
create table moz_anno_attributes(id, name);"

# Firefox: one visit.
sqlite3 "$AS/Firefox/Profiles/x.default-release/places.sqlite" "$places_schema
insert into moz_places values (1, 'https://zebrafixture.example/', 'Example', 1700000000000000);
insert into moz_historyvisits values (1, 1, 1700000000000000);"

# Tor: no history, one bookmark, a last download folder and a state file.
P="$AS/TorBrowser-Data/Browser/abc.default"
sqlite3 "$P/places.sqlite" "$places_schema
insert into moz_bookmarks values (1, 1, 5);"
echo 'user_pref("browser.download.lastDir", "/Users/test/Downloads");' > "$P/prefs.js"
printf 'LastWritten 2026-09-30 21:14:02\n' > "$AS/TorBrowser-Data/Tor/state"

# Zen, a Firefox-based browser: one visit, with the search word in its title.
mkdir -p "$AS/zen/Profiles/z.Default (release)"
sqlite3 "$AS/zen/Profiles/z.Default (release)/places.sqlite" "$places_schema
insert into moz_places values (1, 'https://zen.example/', 'Zebrafixture in Zen', 1710000000000000);
insert into moz_historyvisits values (1, 1, 1710000000000000);"

# Mail and documents: an opened attachment, an autosaved TextEdit document,
# and two files Word can reopen.
C="$L/Containers"
mkdir -p "$C/com.apple.mail/Data/Library/Mail Downloads/AB12" "$C/com.apple.TextEdit/Data/Library/Autosave Information" \
  "$C/com.microsoft.Word/Data/Library/Preferences"
printf 'x' > "$C/com.apple.mail/Data/Library/Mail Downloads/AB12/invoice.pdf"
printf 'x' > "$C/com.apple.TextEdit/Data/Library/Autosave Information/Unsaved Document.rtf"
cat > "$C/com.microsoft.Word/Data/Library/Preferences/com.microsoft.Word.securebookmarks.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>file:///Users/test/Documents/a.docx</key><dict/>
<key>file:///Users/test/Documents/b.docx</key><dict/>
</dict></plist>
PLIST

# Three remembered addresses, in a store like macOS's.
mkdir -p "$C/com.apple.corerecents.recentsd/Data/Library/Recents"
sqlite3 "$C/com.apple.corerecents.recentsd/Data/Library/Recents/Recents" "
create table recents(ROWID integer primary key autoincrement, display_name text, bundle_identifier text, sending_address text,
  original_source text, dates text not null, last_date integer, weight float, record_hash text not null, count integer, group_kind integer);
create table contacts(ROWID integer primary key autoincrement, recent_id integer, display_name text, kind text, address text);
create table metadata(ROWID integer primary key autoincrement, recent_id integer, key text, value, unique (recent_id, key));
insert into recents (display_name, bundle_identifier, dates, last_date, record_hash) values
  ('Alex', 'com.apple.mail', '', 1760000000, 'a'), ('Sam', 'com.apple.mail', '', 1700000000, 'b'), ('', 'com.apple.MobileSMS', '', 1750000000, 'c');
insert into contacts (recent_id, display_name, kind, address) values
  (1, 'Alex', 'email', 'alex@example.com'), (2, 'Sam', 'email', 'sam@example.com'), (3, '', 'phone', '+441234567890');
insert into metadata (recent_id, key, value) values (1, 'k', 'v'), (2, 'k', 'v');"

# Slack's data folder, and a shell history of three commands.
mkdir -p "$C/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache"
head -c 2000 /dev/zero > "$C/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack/Cache/blob"
printf 'ls\ncd Documents\nssh server.example\n' > "$H/.zsh_history"

# A Chrome extension that can read every site, and a Firefox one that can't.
X="$AS/Google/Chrome/Default/Extensions/abcdefghijklmnopabcdefghijklmnop/1.0_0"
mkdir -p "$X/_locales/en"
printf '{"name": "__MSG_APP_NAME__", "default_locale": "en", "update_url": "https://clients2.google.com/service/update2/crx", "host_permissions": ["<all_urls>"]}' > "$X/manifest.json"
printf '{"app_name": {"message": "Page Reader"}}' > "$X/_locales/en/messages.json"
printf '{"addons": [{"type": "extension", "location": "app-profile", "defaultLocale": {"name": "Tab Counter"}, "userPermissions": {"origins": []}}, {"type": "extension", "location": "app-system-defaults", "defaultLocale": {"name": "Built In"}}]}' \
  > "$AS/Firefox/Profiles/x.default-release/extensions.json"

# Cookies: three in Chrome from two sites, one in Firefox.
sqlite3 "$AS/Google/Chrome/Default/Cookies" "
create table cookies(host_key, name, value, path);
insert into cookies values ('.example.com', 'a', '1', '/'), ('shop.example.com', 'b', '2', '/'), ('.other.org', 'c', '3', '/');"
mkdir -p "$AS/Google/Chrome/Default/Local Storage/leveldb"
head -c 3000 /dev/zero > "$AS/Google/Chrome/Default/Local Storage/leveldb/000003.log"
sqlite3 "$AS/Firefox/Profiles/x.default-release/cookies.sqlite" "
create table moz_cookies(id integer primary key, host, name, value);
insert into moz_cookies (host, name, value) values ('.example.com', 'a', '1');"

# Two learned spellings and the keyboard's learned data.
mkdir -p "$L/Spelling" "$L/Keyboard"
printf 'zebrafixtures\nTrailSift\n' > "$L/Spelling/LocalDictionary"
head -c 2000 /dev/zero > "$L/Keyboard/AutocorrectionRejections.db"

# A backup of an old iPhone.
B="$AS/MobileSync/Backup/00008030-0011223344556677"
mkdir -p "$B/ab"
cat > "$B/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Device Name</key><string>Old iPhone</string>
<key>Last Backup Date</key><date>2023-05-01T10:00:00Z</date>
</dict></plist>
PLIST
head -c 5000 /dev/zero > "$B/ab/abcdef0123"

# A file named with the search word, and one inside an app cache, which the
# name search skips.
printf 'x' > "$H/Documents/zebrafixture notes.txt"
mkdir -p "$AS/SomeApp/Cache"
printf 'x' > "$AS/SomeApp/Cache/zebrafixture.bin"

# Downloads: one image and the Tor installer.
printf 'x' > "$H/Downloads/photo.jpg"
printf 'x' > "$H/Downloads/TorBrowser-14.dmg"

# The downloaded photo remembers where it came from, as macOS records it.
cat > "$H/.wherefrom.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><string>https://cdn.example.com/photo.jpg</string><string>https://example.com/gallery</string></array></plist>
PLIST
plutil -convert binary1 "$H/.wherefrom.plist"
xattr -wx com.apple.metadata:kMDItemWhereFroms "$(xxd -p "$H/.wherefrom.plist" | tr -d '\n')" "$H/Downloads/photo.jpg"
rm "$H/.wherefrom.plist"

# Secure-site lists: Chrome's, with example.com and another site hashed, and Firefox's.
/usr/bin/python3 - "$AS/Google/Chrome/Default/TransportSecurity" <<'PY'
import base64, hashlib, json, sys
def h(name):
    wire = b"".join(bytes([len(l)]) + l.encode() for l in name.split(".")) + b"\x00"
    return base64.b64encode(hashlib.sha256(wire).digest()).decode()
json.dump({"version": 2, "sts": [{"host": h(n), "mode": "force-https", "expiry": 2e9} for n in ("example.com", "www.example.com", "other.org")]}, open(sys.argv[1], "w"))
PY
printf 'example.com:HSTS\t0\t20000\t2000000000000,1,0\nother.org:HSTS\t0\t20000\t2000000000000,1,0\n' > "$AS/Firefox/Profiles/x.default-release/SiteSecurityServiceState.txt"

# Launch agents: one left by a removed app, one whose program is there.
mkdir -p "$L/LaunchAgents" "$H/SystemLibrary/LaunchAgents" "$H/SystemLibrary/LaunchDaemons"
for f in "com.gone.reader.helper:/Applications/Gone Reader.app/Contents/MacOS/Helper" "com.present.tool:/bin/ls"; do
  plutil -create xml1 "$L/LaunchAgents/${f%%:*}.plist"
  plutil -insert Label -string "${f%%:*}" "$L/LaunchAgents/${f%%:*}.plist"
  plutil -insert ProgramArguments -array "$L/LaunchAgents/${f%%:*}.plist"
  plutil -insert ProgramArguments.0 -string "${f#*:}" "$L/LaunchAgents/${f%%:*}.plist"
done
plutil -create xml1 "$H/SystemLibrary/LaunchDaemons/com.gone.reader.daemon.plist"
plutil -insert Label -string com.gone.reader.daemon "$H/SystemLibrary/LaunchDaemons/com.gone.reader.daemon.plist"
plutil -insert Program -string "/Library/Application Support/Gone Reader/daemon" "$H/SystemLibrary/LaunchDaemons/com.gone.reader.daemon.plist"

# A JPEG with no file extension in a hidden folder, for the deep scan.
printf '\xff\xd8\xff\xe0' > "$H/.hidden/img"
head -c 4000 /dev/zero >> "$H/.hidden/img"

# VS Code: two recently opened folders, a terminal history of three commands
# and one folder, with the copy it keeps beside them, and saved state for a
# project that exists and one that's gone.
V="$AS/Code/User"
mkdir -p "$V/globalStorage" "$V/workspaceStorage/aaa" "$V/workspaceStorage/bbb"
sqlite3 "$V/globalStorage/state.vscdb" "
create table ItemTable (key text unique on conflict replace, value blob);
insert into ItemTable values ('history.recentlyOpenedPathsList', '{\"entries\":[{\"folderUri\":\"file:///Users/x/one\"},{\"folderUri\":\"file:///Users/x/two\"}]}'),
  ('terminal.history.entries.commands', '{\"entries\":[{\"key\":\"ls\",\"value\":{}},{\"key\":\"git push\",\"value\":{}},{\"key\":\"ssh server.example\",\"value\":{}}]}'),
  ('terminal.history.timestamp.commands', '1760000000000'),
  ('terminal.history.entries.dirs', '{\"entries\":[{\"key\":\"/Users/x/one\",\"value\":{}}]}'),
  ('workbench.colorTheme', 'Dark');"
cp "$V/globalStorage/state.vscdb" "$V/globalStorage/state.vscdb.backup"
printf '{"folder": "file://%s"}' "$H/Documents" > "$V/workspaceStorage/aaa/workspace.json"
printf '{"folder": "file://%s"}' "$H/Old%20Project" > "$V/workspaceStorage/bbb/workspace.json"
head -c 2000 /dev/zero > "$V/workspaceStorage/bbb/state.vscdb"

# PyCharm's recent projects: two.
mkdir -p "$AS/JetBrains/PyCharm2024.1/options"
printf '<application>\n<component name="RecentProjectsManager">\n<RecentProjectMetaInfo opened="false"/>\n<RecentProjectMetaInfo opened="false"/>\n</component>\n</application>\n' \
  > "$AS/JetBrains/PyCharm2024.1/options/recentProjects.xml"

# macOS's notification history: three notifications from two apps.
N="$L/Group Containers/group.com.apple.usernoted/db2"
mkdir -p "$N"
sqlite3 "$N/db" "
create table app (app_id integer primary key, identifier varchar);
create table record (rec_id integer primary key, app_id integer, uuid blob, data blob, request_date real, request_last_date real, delivered_date real, presented bool, style integer, snooze_fire_date real);
insert into app values (1, 'com.apple.mobilesms'), (2, 'com.apple.mail');
insert into record (app_id, delivered_date) values (1, 780000000), (1, 781000000), (2, 782000000);"
