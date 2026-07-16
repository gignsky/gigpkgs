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

# Format and display a news entry
def display-entry [entry: record, show_read: bool = false] {
    let read_entries = load-read-entries
    let is_read = ($entry.id in $read_entries)
    let read_marker = if $is_read { " [read]" } else { " [NEW]" }
    
    if $show_read or (not $is_read) {
        print $"(ansi cyan_bold)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━(ansi reset)"
        print $"(ansi purple_bold)#($entry.num)(ansi reset)  (ansi green_bold)($entry.date)(ansi reset)($read_marker) — (ansi yellow)($entry.id)(ansi reset)"
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

# Main command - show unread entries by default
def main [
    news_file: string = "@NEWS_JSON@"  # Will be substituted at build time
] {
    show-unread $news_file
}
