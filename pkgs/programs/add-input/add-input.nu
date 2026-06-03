#!/usr/bin/env nu
# add-input — Interactive flake input installer for gigpkgs
#
# Fully onboards a new flake input: probes metadata, prompts for configuration,
# writes package files, updates flake.nix, locks, and commits.

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

# Check if input already exists in flake.nix
def check-existing-input [name: string] {
    let flake_content = open flake.nix
    
    if ($flake_content | str contains $"($name).url") {
        print ""
        error $"Input '($name)' already exists in flake.nix"
        
        let response = input "Do you want to update it? (y/N): "
        if ($response | str downcase) != "y" {
            print "Aborted."
            exit 0
        }
        true
    } else {
        false
    }
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

# Extract available overlays from outputs
def extract-overlays [outputs: record] {
    if ($outputs | get --optional overlays) != null {
        $outputs.overlays | columns
    } else {
        []
    }
}

# Prompt for package aliases
def prompt-packages [packages: list<string>, input_name: string] {
    if ($packages | is-empty) {
        return []
    }
    
    print ""
    print $"(ansi yellow_bold)Package Aliases(ansi reset)"
    print $"Available packages from ($input_name):"
    
    for pkg in $packages {
        print $"  - (ansi cyan)($pkg)(ansi reset)"
    }
    
    print ""
    print "Select packages to expose (comma-separated, or 'all', or press Enter to skip):"
    let selection = input "> "
    
    if ($selection | str trim | is-empty) {
        return []
    }
    
    if ($selection | str trim | str downcase) == "all" {
        return $packages
    }
    
    $selection | split row "," | each { |x| $x | str trim }
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
def create-branch [name: string] {
    let branch_name = $"add-input/($name)"
    
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
    mut content = "# Auto-generated by add-input\n"
    $content = $content + $"# Input: ($input_name)\n\n"
    $content = $content + "{ inputs, system, ... }:\n"
    $content = $content + "{\n"
    
    for alias in ($aliases | transpose name pkg) {
        $content = $content + $"  ($alias.name) = inputs.($input_name).packages.\"${system}\".($alias.pkg);\n"
    }
    
    $content = $content + "}\n"
    
    $content | save -f $filename
    success $"Created ($filename)"
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
def patch-flake [input_block: string] {
    status "Patching flake.nix"
    
    let flake_content = open flake.nix
    
    # Find the inputs section and add the new input before the closing brace
    # This is a simple approach - insert before the line with "  };"
    let lines = $flake_content | lines
    
    mut new_lines = []
    mut inserted = false
    
    for line in $lines {
        # Look for the closing of inputs section (simple heuristic)
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
    success "flake.nix patched"
}

# Update pkgs/default.nix to use scanPaths for inputs
def ensure-inputs-scanning [] {
    let pkgs_default = open pkgs/default.nix
    
    # Check if it already uses scanPaths for inputs
    if ($pkgs_default | str contains "scanPaths") and ($pkgs_default | str contains "inputs") {
        status "pkgs/default.nix already configured for input scanning" "green"
        return
    }
    
    status "pkgs/default.nix needs manual update to include pkgs/inputs/ scanning"
    print $"(ansi yellow)Please ensure pkgs/default.nix uses lib.scanPaths ./inputs(ansi reset)"
}

# Run locker to update flake.lock
def update-lock [] {
    status "Updating flake.lock with locker"
    
    try {
        locker -y
        success "flake.lock updated"
    } catch {
        error "locker failed. You may need to run it manually."
        exit 1
    }
}

# Commit changes
def commit-changes [input_name: string, url: string] {
    status "Staging changes"
    
    git add flake.nix flake.lock $"pkgs/inputs/($input_name).nix"
    
    let commit_msg = $"add input: ($input_name) \(($url)\)"
    
    status "Committing with message: ($commit_msg)"
    
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

# Main entry point
def main [
    url: string  # Flake URL (e.g., github:owner/repo)
] {
    print $"(ansi cyan_bold)═══════════════════════════════════════════(ansi reset)"
    print $"(ansi cyan_bold)   gigpkgs add-input — Flake Onboarder   (ansi reset)"
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
    let updating = check-existing-input $name
    
    # Step 4: Extract available packages
    let packages = extract-packages $outputs
    
    # Build aliases (moved outside of if block to ensure proper scoping)
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
    if not $updating {
        create-branch $name
    }
    
    # Step 6: Generate files
    if not ($aliases | is-empty) {
        generate-input-file $name $aliases
    }
    
    # Step 7: Patch flake.nix
    let input_block = generate-flake-input $name $url
    patch-flake $input_block
    
    # Step 8: Ensure pkgs/default.nix scans inputs
    ensure-inputs-scanning
    
    # Step 9: Update lock
    update-lock
    
    # Step 10: Commit
    commit-changes $name $resolved_url
    
    print ""
    success $"Input ($name) successfully onboarded!"
    print $"Branch: (ansi cyan)add-input/($name)(ansi reset)"
    print ""
    print "Next steps:"
    print "  1. Review the changes"
    print "  2. Test the new packages"
    print "  3. Merge into main when ready"
}
