#!/usr/bin/env nu
# gigpkgs-input — Manage flake inputs for gigpkgs
#
# Commands:
#   add <url>       - Add a new flake input
#   remove <name>   - Remove an existing input
#   update <name>   - Update an input (re-probe for changes)

# Print colored status messages
def status [msg: string, color: string = "cyan"] {
    print $"(ansi $color)▶(ansi reset) ($msg)"
}

def error [msg: string] {
    print $"(ansi red_bold)✗ Error:(ansi reset) ($msg)"
}

def success [msg: string] {
    print $"(ansi green_bold)✓(ansi reset) ($msg)"
}

# Generate a news entry for an action
def generate-news-entry [
    action: string     # "added", "removed", "updated"
    input_name: string
    details: record    # Additional details about the action
] {
    let date = date now | format date "%Y-%m-%d"
    let entry_id = $"($date)-($action)-($input_name)"
    let filename = $"news/entries/($entry_id).nix"
    
    status $"Generating news entry: ($filename)"
    
    # Build the message based on action
    let message = match $action {
        "added" => {
            let packages_list = if ($details.packages | is-empty) {
                "No packages exposed."
            } else {
                let pkg_lines = $details.packages | each { |pkg| $"  - pkgs.($pkg)" } | str join "\n"
                $"Available packages:\n($pkg_lines)"
            }
            
            let desc = $details | get --optional description | default "No description available"
            
            $"New flake input: ($input_name)

($desc)

Source: ($details.url)

($packages_list)

Added via: gigpkgs-input add"
        }
        "removed" => {
            let source = $details | get --optional url | default "N/A"
            
            $"Removed flake input: ($input_name)

The following input has been removed from gigpkgs:
  Source: ($source)

Any packages previously exposed from this input are no longer available.

Removed via: gigpkgs-input remove"
        }
        "updated" => {
            let changes = if ($details.new_packages | is-empty) and ($details.removed_packages | is-empty) {
                "No package changes detected."
            } else {
                mut change_text = []
                if not ($details.new_packages | is-empty) {
                    let new_list = $details.new_packages | each { |p| $"  + pkgs.($p)" } | str join "\n"
                    $change_text = ($change_text | append $"New packages:\n($new_list)")
                }
                if not ($details.removed_packages | is-empty) {
                    let removed_list = $details.removed_packages | each { |p| $"  - pkgs.($p)" } | str join "\n"
                    $change_text = ($change_text | append $"Removed packages:\n($removed_list)")
                }
                $change_text | str join "\n\n"
            }
            
            $"Updated flake input: ($input_name)

Source: ($details.url)

($changes)

Updated via: gigpkgs-input update"
        }
        _ => {
            error $"Unknown action: ($action)"
            exit 1
        }
    }
    
    # Generate the Nix file
    let content = $"{
  id = \"($entry_id)\";
  date = \"($date)\";
  message = ''
($message)
  '';
}
"
    
    mkdir news/entries
    $content | save -f $filename
    success $"News entry created: ($filename)"
    $filename
}

# Probe flake metadata
def probe-metadata [url: string] {
    status $"Probing flake metadata: ($url)"
    
    let metadata = try {
        nix flake metadata $url --json | from json
    } catch {
        error "Failed to fetch flake metadata. Check the URL and network connection."
        exit 1
    }
    
    status "Metadata retrieved successfully" "green"
    $metadata
}

# Probe flake outputs schema
def probe-outputs [url: string] {
    status $"Probing flake outputs: ($url)"
    
    let outputs = try {
        nix flake show $url --json | from json
    } catch {
        error "Failed to fetch flake outputs."
        exit 1
    }
    
    status "Outputs retrieved successfully" "green"
    $outputs
}

# Extract suggested name from URL
def suggest-name [url: string] {
    # Extract repo name from github:owner/repo or similar
    let parts = $url | split row "/"
    let last = $parts | last
    
    # Remove .git suffix if present
    $last | str replace ".git" ""
}

# Prompt user for input name
def prompt-name [suggested: string] {
    print ""
    print $"(ansi yellow_bold)Input Name Configuration(ansi reset)"
    print $"Suggested name: (ansi cyan)($suggested)(ansi reset)"
    
    let custom = input "Enter custom name (or press Enter to use suggested): "
    
    if ($custom | str trim | is-empty) {
        $suggested
    } else {
        $custom | str trim
    }
}

# Check if input exists in flake.nix
def input-exists [name: string] {
    let flake_content = open flake.nix
    $flake_content | str contains $"($name).url"
}

# Extract available packages from outputs
def extract-packages [outputs: record, system: string = "x86_64-linux"] {
    mut packages = []
    
    # Check packages.*
    if ($outputs | get --optional packages) != null {
        let pkg_systems = $outputs.packages
        if ($pkg_systems | get --optional $system) != null {
            let sys_pkgs = $pkg_systems | get $system
            $packages = ($sys_pkgs | columns)
        }
    }
    
    $packages
}

# Prompt for package alias naming
def prompt-alias [package: string, input_name: string] {
    let suggested = if $package == "default" {
        $input_name
    } else {
        $"($input_name)-($package)"
    }
    
    print $"Alias for package '(ansi cyan)($package)(ansi reset)' (suggested: (ansi green)($suggested)(ansi reset)):"
    let custom = input "> "
    
    if ($custom | str trim | is-empty) {
        $suggested
    } else {
        $custom | str trim
    }
}

# Create branch
def create-branch [name: string, prefix: string = "input"] {
    let branch_name = $"($prefix)/($name)"
    
    status $"Creating branch: ($branch_name)"
    
    # Check if we're on main/master
    let current = git branch --show-current | str trim
    if $current != "main" and $current != "master" {
        print $"(ansi yellow)Warning: Not on main branch (currently on ($current))(ansi reset)"
        let proceed = input "Continue anyway? (y/N): "
        if ($proceed | str downcase) != "y" {
            exit 0
        }
    }
    
    try {
        git checkout -b $branch_name
        success $"Branch ($branch_name) created"
        $branch_name
    } catch {
        error "Failed to create branch. It may already exist."
        exit 1
    }
}

# Generate per-input package file
def generate-input-file [input_name: string, aliases: record] {
    let filename = $"pkgs/inputs/($input_name).nix"
    
    status $"Generating ($filename)"
    
    # Create directory if it doesn't exist
    mkdir pkgs/inputs
    
    # Generate Nix file content
    mut content = "# Auto-generated by gigpkgs-input\n"
    $content = $content + $"# Input: ($input_name)\n\n"
    $content = $content + "{ inputs, system, ... }:\n"
    $content = $content + "{\n"
    
    for alias in ($aliases | transpose name pkg) {
        $content = $content + $"  ($alias.name) = inputs.($input_name).packages.\"${{system}}\".($alias.pkg);\n"
    }
    
    $content = $content + "}\n"
    
    $content | save -f $filename
    success $"Created ($filename)"
}

# Remove input file
def remove-input-file [input_name: string] {
    let filename = $"pkgs/inputs/($input_name).nix"
    
    if ($filename | path exists) {
        status $"Removing ($filename)"
        rm $filename
        success $"Removed ($filename)"
        true
    } else {
        print $"(ansi yellow)File ($filename) does not exist(ansi reset)"
        false
    }
}

# Generate flake.nix input entry
def generate-flake-input [name: string, url: string] {
    mut input_block = $"  ($name) = \{\n"
    $input_block = $input_block + $"    url = \"($url)\";\n"
    $input_block = $input_block + $"    # Add follows declarations here if needed\n"
    $input_block = $input_block + "  };\n"
    
    $input_block
}

# Patch flake.nix to add new input
def patch-flake-add [input_block: string] {
    status "Patching flake.nix (adding input)"
    
    let flake_content = open flake.nix
    let lines = $flake_content | lines
    
    mut new_lines = []
    mut inserted = false
    
    for line in $lines {
        # Look for the closing of inputs section
        if (not $inserted) and ($line | str trim | str starts-with "};") and ($new_lines | last | str contains "inputs") {
            # Insert new input before this closing brace
            $new_lines = ($new_lines | append ($input_block | lines))
            $inserted = true
        }
        
        $new_lines = ($new_lines | append $line)
    }
    
    if not $inserted {
        error "Could not find appropriate location to insert input in flake.nix"
        exit 1
    }
    
    $new_lines | str join "\n" | save -f flake.nix
    success "flake.nix patched (input added)"
}

# Remove input from flake.nix
def patch-flake-remove [input_name: string] {
    status "Patching flake.nix (removing input)"
    
    let flake_content = open flake.nix
    let lines = $flake_content | lines
    
    mut new_lines = []
    mut in_target_block = false
    mut brace_depth = 0
    
    for line in $lines {
        # Check if this line starts the target input block
        if ($line | str contains $"($input_name) = {") {
            $in_target_block = true
            $brace_depth = 1
            continue
        }
        
        # If we're in the target block, track braces
        if $in_target_block {
            if ($line | str contains "{") {
                $brace_depth = $brace_depth + 1
            }
            if ($line | str contains "}") {
                $brace_depth = $brace_depth - 1
                if $brace_depth == 0 {
                    $in_target_block = false
                    continue
                }
            }
            continue
        }
        
        $new_lines = ($new_lines | append $line)
    }
    
    $new_lines | str join "\n" | save -f flake.nix
    success "flake.nix patched (input removed)"
}

# Run locker to update flake.lock
def update-lock [input_name: string = ""] {
    if $input_name == "" {
        status "Updating flake.lock with locker"
        try {
            locker -y
            success "flake.lock updated"
        } catch {
            error "locker failed. You may need to run it manually."
            exit 1
        }
    } else {
        status $"Updating ($input_name) in flake.lock"
        try {
            locker $input_name -y
            success $"flake.lock updated for ($input_name)"
        } catch {
            error $"locker failed for ($input_name)"
            exit 1
        }
    }
}

# Commit changes
def commit-changes [action: string, input_name: string, details: string = ""] {
    status "Staging changes"
    
    git add -A
    
    let commit_msg = if $details == "" {
        $"($action) input: ($input_name)"
    } else {
        $"($action) input: ($input_name) - ($details)"
    }
    
    status $"Committing: ($commit_msg)"
    
    try {
        git commit -m $commit_msg
        success "Changes committed"
    } catch { |err|
        error $"Commit failed: ($err)"
        print "Branch has been left in place with staged changes."
        print "Fix any issues and commit manually."
        exit 1
    }
}

# ADD command - add a new flake input
def "main add" [
    url: string  # Flake URL (e.g., github:owner/repo)
] {
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print $"(ansi cyan_bold)   gigpkgs-input add — Onboard New Input  (ansi reset)"
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print ""
    
    # Step 1: Probe metadata
    let metadata = probe-metadata $url
    let resolved_url = $metadata.resolvedUrl
    
    print ""
    print $"(ansi green_bold)Metadata:(ansi reset)"
    print $"  Description: ($metadata.description? | default 'N/A')"
    print $"  Resolved: ($resolved_url)"
    print $"  Last Modified: ($metadata.lastModified? | default 'N/A')"
    
    # Step 2: Probe outputs
    let outputs = probe-outputs $url
    
    # Step 3: Suggest and prompt for name
    let suggested = suggest-name $url
    let name = prompt-name $suggested
    
    status $"Using input name: (ansi cyan_bold)($name)(ansi reset)" "green"
    
    # Check if input already exists
    if (input-exists $name) {
        error $"Input '($name)' already exists in flake.nix"
        print "Use 'gigpkgs-input update <name>' to update it instead."
        exit 1
    }
    
    # Step 4: Extract available packages and build aliases
    let packages = extract-packages $outputs
    
    let aliases = if ($packages | is-empty) {
        print ""
        print $"(ansi yellow)No packages found in this input(ansi reset)"
        {}
    } else {
        print ""
        print $"(ansi yellow_bold)Package Aliases(ansi reset)"
        print $"Available packages from ($name):"
        
        for pkg in $packages {
            print $"  - (ansi cyan)($pkg)(ansi reset)"
        }
        
        print ""
        print "Select packages to expose (comma-separated, or 'all', or press Enter to skip):"
        let selection = input "> "
        
        let selected_packages = if ($selection | str trim | is-empty) {
            []
        } else if ($selection | str trim | str downcase) == "all" {
            $packages
        } else {
            $selection | split row "," | each { |x| $x | str trim }
        }
        
        # Build aliases map
        mut alias_map = {}
        for pkg in $selected_packages {
            let alias = prompt-alias $pkg $name
            $alias_map = ($alias_map | insert $alias $pkg)
        }
        
        if not ($alias_map | is-empty) {
            print ""
            print $"(ansi green_bold)Package Aliases:(ansi reset)"
            for entry in ($alias_map | transpose alias package) {
                print $"  ($entry.alias) → ($name).packages.x86_64-linux.($entry.package)"
            }
        }
        
        $alias_map
    }
    
    # Confirm before proceeding
    print ""
    let confirm = input $"(ansi yellow_bold)Proceed with onboarding ($name)? \(y/N\): (ansi reset)"
    if ($confirm | str downcase) != "y" {
        print "Aborted."
        exit 0
    }
    
    # Step 5: Create branch
    let branch = create-branch $name "add-input"
    
    # Step 6: Generate files
    if not ($aliases | is-empty) {
        generate-input-file $name $aliases
    }
    
    # Step 7: Patch flake.nix
    let input_block = generate-flake-input $name $url
    patch-flake-add $input_block
    
    # Step 8: Update lock
    update-lock $name
    
    # Step 9: Generate news entry
    let news_file = generate-news-entry "added" $name {
        url: $resolved_url
        description: ($metadata.description? | default "")
        packages: ($aliases | columns)
    }
    
    # Step 10: Commit
    commit-changes "add" $name $resolved_url
    
    print ""
    success $"Input ($name) successfully added!"
    print $"Branch: (ansi cyan)($branch)(ansi reset)"
    print $"News entry: (ansi cyan)($news_file)(ansi reset)"
    print ""
    print "Next steps:"
    print "  1. Review the changes"
    print "  2. Test the new packages"
    print "  3. Merge into main when ready"
}

# REMOVE command - remove an existing input
def "main remove" [
    name: string  # Input name to remove
] {
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print $"(ansi cyan_bold)   gigpkgs-input remove — Remove Input    (ansi reset)"
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print ""
    
    # Check if input exists
    if not (input-exists $name) {
        error $"Input '($name)' not found in flake.nix"
        exit 1
    }
    
    # Get current URL for news entry
    let flake_content = open flake.nix
    let url_line = $flake_content | lines | find $"($name).url" | first
    let url = $url_line | parse "{before}url = \"{url}\"{after}" | get url.0
    
    print $"(ansi yellow_bold)Warning:(ansi reset) This will remove input '(ansi red)($name)(ansi reset)'"
    print $"  Source: ($url)"
    
    let confirm = input $"(ansi yellow_bold)Are you sure? \(y/N\): (ansi reset)"
    if ($confirm | str downcase) != "y" {
        print "Aborted."
        exit 0
    }
    
    # Create branch
    let branch = create-branch $name "remove-input"
    
    # Remove input file
    remove-input-file $name
    
    # Patch flake.nix
    patch-flake-remove $name
    
    # Update lock
    update-lock
    
    # Generate news entry
    let news_file = generate-news-entry "removed" $name {
        url: $url
    }
    
    # Commit
    commit-changes "remove" $name $url
    
    print ""
    success $"Input ($name) successfully removed!"
    print $"Branch: (ansi cyan)($branch)(ansi reset)"
    print $"News entry: (ansi cyan)($news_file)(ansi reset)"
}

# UPDATE command - update an existing input
def "main update" [
    name: string  # Input name to update
] {
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print $"(ansi cyan_bold)   gigpkgs-input update — Update Input    (ansi reset)"
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print ""
    
    # Check if input exists
    if not (input-exists $name) {
        error $"Input '($name)' not found in flake.nix"
        exit 1
    }
    
    # Get current URL
    let flake_content = open flake.nix
    let url_line = $flake_content | lines | find $"($name).url" | first
    let url = $url_line | parse "{before}url = \"{url}\"{after}" | get url.0
    
    print $"(ansi green_bold)Updating input:(ansi reset) ($name)"
    print $"  Source: ($url)"
    print ""
    
    # Get current packages
    let current_file = $"pkgs/inputs/($name).nix"
    let old_packages = if ($current_file | path exists) {
        let content = open $current_file
        # Extract package names from the file (simple pattern matching)
        $content | lines | where { |line| $line =~ ' = inputs' } | each { |line|
            let parts = $line | str trim | split row ' = '
            $parts.0
        }
    } else {
        []
    }
    
    # Probe outputs
    let metadata = probe-metadata $url
    let outputs = probe-outputs $url
    let new_available = extract-packages $outputs
    
    print $"(ansi green_bold)Available packages:(ansi reset)"
    for pkg in $new_available {
        print $"  - (ansi cyan)($pkg)(ansi reset)"
    }
    print ""
    
    # Detect changes
    let new_packages = $new_available | where { |p| $p not-in $old_packages }
    let removed_packages = $old_packages | where { |p| $p not-in $new_available }
    
    if ($new_packages | is-empty) and ($removed_packages | is-empty) {
        print $"(ansi yellow)No package changes detected.(ansi reset)"
        print "Update will still refresh the lock."
    } else {
        if not ($new_packages | is-empty) {
            print $"(ansi green_bold)New packages available:(ansi reset)"
            for pkg in $new_packages {
                print $"  + (ansi green)($pkg)(ansi reset)"
            }
        }
        if not ($removed_packages | is-empty) {
            print $"(ansi red_bold)Packages no longer available:(ansi reset)"
            for pkg in $removed_packages {
                print $"  - (ansi red)($pkg)(ansi reset)"
            }
        }
    }
    
    print ""
    print "Select packages to expose (comma-separated, or 'all', or 'keep' for current, or Enter to skip):"
    let selection = input "> "
    
    let selected_packages = if ($selection | str trim | is-empty) {
        []
    } else if ($selection | str trim | str downcase) == "all" {
        $new_available
    } else if ($selection | str trim | str downcase) == "keep" {
        $old_packages | where { |p| $p in $new_available }
    } else {
        $selection | split row "," | each { |x| $x | str trim }
    }
    
    # Build aliases
    mut aliases = {}
    for pkg in $selected_packages {
        let alias = prompt-alias $pkg $name
        $aliases = ($aliases | insert $alias $pkg)
    }
    
    let confirm = input $"(ansi yellow_bold)Proceed with update? \(y/N\): (ansi reset)"
    if ($confirm | str downcase) != "y" {
        print "Aborted."
        exit 0
    }
    
    # Create branch
    let branch = create-branch $name "update-input"
    
    # Regenerate input file if packages selected
    if not ($aliases | is-empty) {
        generate-input-file $name $aliases
    } else if ($current_file | path exists) {
        remove-input-file $name
    }
    
    # Update lock
    update-lock $name
    
    # Generate news entry
    let alias_names = $aliases | columns
    let news_file = generate-news-entry "updated" $name {
        url: $url
        new_packages: ($alias_names | where { |p| $p not-in $old_packages })
        removed_packages: ($removed_packages)
    }
    
    # Commit
    commit-changes "update" $name "refreshed packages and lock"
    
    print ""
    success $"Input ($name) successfully updated!"
    print $"Branch: (ansi cyan)($branch)(ansi reset)"
    print $"News entry: (ansi cyan)($news_file)(ansi reset)"
}

# Main entry point
def main [] {
    print $"(ansi red_bold)Error:(ansi reset) No command specified"
    print ""
    print $"(ansi cyan_bold)gigpkgs-input — Manage flake inputs(ansi reset)"
    print ""
    print "Usage:"
    print "  gigpkgs-input add <url>       Add a new flake input"
    print "  gigpkgs-input remove <name>   Remove an existing input"
    print "  gigpkgs-input update <name>   Update an input (re-probe for changes)"
    print ""
    exit 1
}
