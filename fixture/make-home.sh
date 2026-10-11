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

# A JPEG with no file extension in a hidden folder, for the deep scan.
printf '\xff\xd8\xff\xe0' > "$H/.hidden/img"
head -c 4000 /dev/zero >> "$H/.hidden/img"
