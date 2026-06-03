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

# Format and display a news entry
def display-entry [entry: record, show_read: bool = false] {
    let read_entries = load-read-entries
    let is_read = ($entry.id in $read_entries)
    let read_marker = if $is_read { " [read]" } else { " [NEW]" }
    
    if $show_read or (not $is_read) {
        print $"(ansi cyan_bold)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━(ansi reset)"
        print $"(ansi green_bold)($entry.date)(ansi reset)($read_marker) — (ansi yellow)($entry.id)(ansi reset)"
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
        
        print $"(ansi cyan)($unread | length) unread entries. Use 'gignews read-all' to mark all as read.(ansi reset)"
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

# Mark a specific entry as read
def "main read" [
    id: string                          # Entry ID to mark as read
    news_file: string = "@NEWS_JSON@"   # Will be substituted at build time
] {
    mark-read $id
    print $"(ansi green)Marked '($id)' as read.(ansi reset)"
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

# Show a specific entry
def "main show" [
    id: string                          # Entry ID to display
    news_file: string = "@NEWS_JSON@"   # Will be substituted at build time
] {
    let entries = load-news $news_file
    let entry = $entries | where id == $id | first
    
    if ($entry | is-empty) {
        print $"(ansi red)Error: Entry '($id)' not found.(ansi reset)"
    } else {
        display-entry $entry true
    }
}

# Main command - show unread entries by default
def main [
    news_file: string = "@NEWS_JSON@"  # Will be substituted at build time
] {
    show-unread $news_file
}
