# Trailsift audit

The script behind [Trailsift for Mac](https://trailsift.com): a read-only audit of where a Mac keeps traces of what you browse, download and view. Browser histories and caches, the macOS download log, Tor Browser leftovers, Quick Look thumbnails, recent items, saved windows, messaging attachments, the activity databases behind Screen Time, iCloud and backups. Each finding says what it is, where it lives, and where to read more.

It's published so anyone can check what Trailsift reads, and that it changes nothing. The Trailsift app runs this same script; everything it cleans, in Pro, is separate app code that only runs after you see and confirm each change.

## What it promises

- **It only reads.** Nothing is deleted, moved or changed. Databases are copied into a private temporary folder before they are queried, so the originals are never opened, and that folder is removed when the script ends.
- **Counts, not contents.** The audit prints how many items there are, their size and date range, never web addresses or file names, so the report is safe on a shared screen. Only the word search shows names, because that is what you ask it for.
- **Nothing leaves your Mac.** The script makes no network connections.

`test.sh` checks the first promise: it builds a fake home folder with known traces, fingerprints every file, runs the audit, the deep scan and the word search against it, and fingerprints again.

## Run it

```bash
./mac-trace-audit.sh
```

| Option | What it does |
|-|-|
| `-brief` | the audit without the explanations |
| `-v` | also list the 10 most visited sites in each history |
| `-deep` | also find images and videos in caches and hidden folders (several minutes) |
| `-nolinks` | plain paths, without clickable terminal links |
| `-json` | one JSON object per line, as the app reads it |
| `-search "word,another phrase"` | instead of the audit, search histories, download lists, the download log, file and folder names and document text |
| `-h` | help |

Some places, such as Safari, Messages and the Trash, are protected by macOS. To include them, give your terminal app Full Disk Access in System Settings > Privacy & Security > Full Disk Access, then run again.

What each place is, why it matters and how to clear it yourself: [What Trailsift checks](https://trailsift.com/checks/).

## Check it matches the app

Each release of Trailsift is tagged here with its version. The app carries its copy of the script inside its bundle:

```bash
shasum -a 256 /Applications/Trailsift.app/Contents/Resources/mac-trace-audit.sh
shasum -a 256 mac-trace-audit.sh
```

With the tag for your version of Trailsift checked out, the two match.

## Licence

MIT, © 2026 Itch Studio Ltd. See [LICENSE](LICENSE). Issues and questions: [support@trailsift.com](mailto:support@trailsift.com).
