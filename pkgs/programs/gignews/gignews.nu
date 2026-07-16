#!/usr/bin/env nu
# gignews — View and manage gigpkgs news entries

# Get state directory
def state-dir [] {
    $env.HOME | path join ".local" "share" "gigpkgs"
}

# Get state file path
def state-file [] {
    state-dir | path join "news-read"
}

# Load read entries from state file
def load-read-entries [] {
    let file = state-file
    if ($file | path exists) {
        open $file | lines | where { |it| $it != "" }
    } else {
        []
    }
}

# Save read entries to state file
def save-read-entries [entries: list<string>] {
    let dir = state-dir
    let file = state-file
    mkdir $dir
    $entries | str join "\n" | save --force $file
}

# Mark an entry as read
def mark-read [id: string] {
    let read_entries = load-read-entries
    if $id not-in $read_entries {
        save-read-entries ($read_entries | append $id)
    }
}

# Load news entries from JSON file
def load-news [news_file: string] {
    if ($news_file | path exists) {
        open $news_file
    } else {
        print $"Error: news file not found: ($news_file)"
        []
    }
}

# Resolve a reference (a numeric `num` or a full string `id`) to an entry id.
# Returns null if nothing matches.
def resolve-ref [entries: list, ref: string] {
    let by_num = if ($ref =~ '^[0-9]+$') {
        $entries | where num == ($ref | into int)
    } else {
        []
    }

    if (not ($by_num | is-empty)) {
        ($by_num | first | get id)
    } else {
        let by_id = $entries | where id == $ref
        if (not ($by_id | is-empty)) {
            ($by_id | first | get id)
        } else {
            null
        }
    }
}

# --- Authoring helpers (`gignews post`) ---

# Locate a repo's `news/entries/` directory. Precedence: explicit override arg,
# then $GIGNEWS_ENTRIES_DIR, then walk up from the current directory. Returns null
# if none is found.
def find-entries-dir [override: string] {
    if ($override | is-not-empty) {
        return $override
    }
    if ("GIGNEWS_ENTRIES_DIR" in $env) and (($env.GIGNEWS_ENTRIES_DIR | into string) != "") {
        return $env.GIGNEWS_ENTRIES_DIR
    }
    mut dir = (pwd)
    loop {
        let candidate = ($dir | path join "news" "entries")
        if ($candidate | path type) == "dir" {
            return $candidate
        }
        let parent = ($dir | path dirname)
        if $parent == $dir {
            break
        }
        $dir = $parent
    }
    null
}

# Next unused `num` for a new entry: max existing `num` + 1 (or 1 if none exist).
def next-num [entries_dir: string] {
    let nums = (glob ($entries_dir | path join "*.nix")) | each { |f|
        let m = (open $f | into string | parse --regex 'num\s*=\s*(?<n>\d+)')
        if ($m | is-empty) { null } else { $m.n.0 | into int }
    } | where { |it| $it != null }
    if ($nums | is-empty) { 1 } else { ($nums | math max) + 1 }
}

# Normalize a free-form slug into a filesystem/id-safe token.
def slugify [raw: string] {
    $raw | str downcase | str replace --all --regex '[^a-z0-9]+' '-' | str trim --char '-'
}

# Format and display a news entry
def display-entry [entry: record, show_read: bool = false] {
    let read_entries = load-read-entries
    let is_read = ($entry.id in $read_entries)
    let read_marker = if $is_read { " [read]" } else { " [NEW]" }
    
    # Prefer the precise UTC `timestamp` (shown in the viewer's local time);
    # fall back to the plain `date` for entries without one.
    let when = if ($entry.timestamp? | is-not-empty) {
        try {
            $entry.timestamp | into datetime | format date "%Y-%m-%d %H:%M"
        } catch {
            $entry.date
        }
    } else {
        $entry.date
    }

    if $show_read or (not $is_read) {
        print $"(ansi cyan_bold)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━(ansi reset)"
        print $"(ansi purple_bold)#($entry.num)(ansi reset)  (ansi green_bold)($when)(ansi reset)($read_marker) — (ansi yellow)($entry.id)(ansi reset)"
        print ""
        print $entry.message
        print ""
    }
}

# Show unread entries (default command)
def show-unread [news_file: string] {
    let entries = load-news $news_file
    let read_entries = load-read-entries
    let unread = $entries | where { |e| $e.id not-in $read_entries }
    
    if ($unread | is-empty) {
        print $"(ansi green)No unread news entries.(ansi reset)"
    } else {
        print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
        print $"(ansi cyan_bold)       gigpkgs News — Unread Entries      (ansi reset)"
        print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
        print ""
        
        for entry in $unread {
            display-entry $entry false
        }
        
        print $"(ansi cyan)($unread | length) unread entries. Use 'gignews read <#>' to mark one, or 'gignews read-all' to mark all as read.(ansi reset)"
    }
}

# List all entries
def "main list" [
    news_file: string = "@NEWS_JSON@"  # Will be substituted at build time
] {
    let entries = load-news $news_file
    
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print $"(ansi cyan_bold)       gigpkgs News — All Entries          (ansi reset)"
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print ""
    
    for entry in $entries {
        display-entry $entry true
    }
}

# Mark one or more entries as read (by number or string id).
# Accepts space- or comma-separated refs, e.g. `gignews read 3 4 5` or `gignews read 3,4,5`.
def "main read" [
    ...refs: string                        # Entry numbers (#) or string ids to mark as read
    --news-file: string = "@NEWS_JSON@"    # Will be substituted at build time
] {
    let entries = load-news $news_file
    # Split any comma-separated tokens (e.g. "3,4,5") into individual refs
    let all_refs = $refs | each { |r| $r | split row "," } | flatten | where { |it| $it != "" }

    if ($all_refs | is-empty) {
        print $"(ansi red)Error: no entry given. Usage: gignews read <#|id> [<#|id> ...](ansi reset)"
        return
    }

    for ref in $all_refs {
        let resolved = resolve-ref $entries $ref
        if ($resolved == null) {
            print $"(ansi red)Error: no news entry matching '($ref)'.(ansi reset)"
        } else {
            mark-read $resolved
            print $"(ansi green)Marked '($resolved)' as read.(ansi reset)"
        }
    }
}

# Mark all entries as read
def "main read-all" [
    news_file: string = "@NEWS_JSON@"  # Will be substituted at build time
] {
    let entries = load-news $news_file
    let all_ids = $entries | get id
    save-read-entries $all_ids
    print $"(ansi green)Marked all ($all_ids | length) entries as read.(ansi reset)"
}

# Show a specific entry (by number or string id)
def "main show" [
    ref: string                         # Entry number (#) or string id to display
    news_file: string = "@NEWS_JSON@"   # Will be substituted at build time
] {
    let entries = load-news $news_file
    let resolved = resolve-ref $entries $ref

    if ($resolved == null) {
        print $"(ansi red)Error: Entry '($ref)' not found.(ansi reset)"
    } else {
        let entry = $entries | where id == $resolved | first
        display-entry $entry true
    }
}

# Scaffold a new news entry from a template and (by default) open it in $EDITOR.
# Writes into a repo's news/entries/ (discovered via find-entries-dir). Pass
# --message to fill the body non-interactively (e.g. from another tool like
# inputMan), which also skips the editor; --no-edit skips the editor too.
def "main post" [
    slug?: string                  # Short slug for the entry (prompted if omitted)
    --message (-m): string = ""    # Entry body; when given, skips the editor (for scripting)
    --entries-dir: string = ""     # Override the news/entries directory
    --no-edit                      # Do not open $EDITOR after creating the file
] {
    let dir = (find-entries-dir $entries_dir)
    if ($dir == null) {
        print $"(ansi red)Error: could not find a 'news/entries' directory. Run from a gigpkgs checkout, set $GIGNEWS_ENTRIES_DIR, or pass --entries-dir.(ansi reset)"
        return
    }

    let raw_slug = if ($slug | is-not-empty) { $slug } else { (input "Entry slug: ") }
    let s = (slugify $raw_slug)
    if ($s == "") {
        print $"(ansi red)Error: empty slug.(ansi reset)"
        return
    }

    let now = (date now)
    let today = ($now | format date "%Y-%m-%d")
    let stamp = ($now | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ")
    let entry_id = $"($today)-($s)"
    let file = ($dir | path join $"($entry_id).nix")

    if ($file | path exists) {
        print $"(ansi red)Error: ($file) already exists.(ansi reset)"
        return
    }

    let num = (next-num $dir)
    let body = if ($message | is-not-empty) { $message } else { "TITLE HERE\n\nDescribe what changed. This text is shown to users when they activate a new home-manager generation." }
    # Indent each body line to sit inside the Nix `''` multiline block
    let indented = ($body | lines | each { |l| $"    ($l)" } | str join "\n")

    let template = $"{
  id = \"($entry_id)\";
  num = ($num);
  date = \"($today)\";
  timestamp = \"($stamp)\";
  message = ''
($indented)
  '';
}
"
    $template | save --force $file
    print $"(ansi green)Created ($file) as #($num).(ansi reset)"

    # Open the editor unless suppressed or the body was supplied non-interactively
    if (not $no_edit) and ($message | is-empty) {
        let editor = ($env.EDITOR? | default "vi")
        run-external $editor $file
    }
}

# Main command - show unread entries by default
def main [
    news_file: string = "@NEWS_JSON@"  # Will be substituted at build time
] {
    show-unread $news_file
}
