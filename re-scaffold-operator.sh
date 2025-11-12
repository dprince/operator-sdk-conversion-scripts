#!/bin/bash

set -e

# Re-scaffold operator project script
# Migrates existing operator-sdk v3 projects to v4 format
# Following Kubebuilder migration guide: https://book.kubebuilder.io/migration/migration_guide_gov3_to_gov4

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 <operator-directory>"
    echo "Example: $0 keystone-operator"
    echo ""
    echo "This script follows the Kubebuilder v3 to v4 migration guide:"
    echo "  1. Creates a new go/v4 project directory: <operator-directory>-v4"
    echo "  2. Initializes with operator-sdk init --plugins=go/v4"
    echo "  3. Scaffolds APIs and controllers from the PROJECT file"
    echo "  4. Migrates API definitions from api/ directory"
    echo "  5. Migrates api/go.mod (treats api/ as Go submodule)"
    echo "  6. Migrates controller code from controllers/ to internal/controller/"
    echo "  7. Migrates webhooks if present"
    echo "  7.5. Copies webhook files from api/v1beta1/ to internal/webhook/v1beta1/"
    echo "  8. Migrates custom code from pkg/ to internal/"
    echo "  9. Updates import paths throughout the codebase"
    echo "  9.5. Copies go.mod from original project"
    echo "  10. Migrates main.go with operator-sdk v1.38.0 updates"
    echo "  11. Syncs Go dependencies"
    echo "  12. Copies additional configuration files"
    echo "  13. Removes unnecessary directories and files (.github/workflows, .golangci.yml, .devcontainer)"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

OPERATOR_DIR="$1"
PROJECT_FILE="${OPERATOR_DIR}/PROJECT"

# Validate inputs
if [ ! -d "$OPERATOR_DIR" ]; then
    echo "Error: Directory '$OPERATOR_DIR' does not exist"
    exit 1
fi

if [ ! -f "$PROJECT_FILE" ]; then
    echo "Error: PROJECT file not found at '$PROJECT_FILE'"
    exit 1
fi

echo "========================================="
echo "Operator Migration: v3 to v4"
echo "Source: $OPERATOR_DIR"
echo "========================================="

# Parse PROJECT file to extract key information
parse_project_file() {
    local project_file="$1"

    # Extract basic project information
    PROJECT_NAME=$(grep "^projectName:" "$project_file" | cut -d':' -f2 | xargs)
    REPO=$(grep "^repo:" "$project_file" | cut -d':' -f2 | xargs)
    DOMAIN=$(grep "^domain:" "$project_file" | cut -d':' -f2 | xargs)
    MULTIGROUP=$(grep "^multigroup:" "$project_file" | cut -d':' -f2 | xargs)

    echo "Project Name: $PROJECT_NAME"
    echo "Repository: $REPO"
    echo "Domain: $DOMAIN"
    echo "Multigroup: ${MULTIGROUP:-false}"
}

# Extract resource information from PROJECT file
extract_resources() {
    local project_file="$1"

    # Create temporary file to store resource information
    RESOURCES_FILE=$(mktemp)

    # Parse resources section using awk
    awk '
    /^resources:/ { in_resources=1; next }
    /^[a-zA-Z]/ && in_resources { in_resources=0 }
    in_resources && /^- / {
        # Output previous resource if we have one
        if (resource_start && group != "" && kind != "" && version != "") {
            printf "%s|%s|%s|%s|%s|%s\n", group, kind, version, domain, webhooks_defaulting, webhooks_validation
        }
        # Start new resource
        resource_start=1
        group=""
        kind=""
        version=""
        domain=""
        webhooks_defaulting=""
        webhooks_validation=""
    }
    in_resources && resource_start && /^  group:/ {
        gsub(/^  group: */, "")
        group=$0
    }
    in_resources && resource_start && /^  kind:/ {
        gsub(/^  kind: */, "")
        kind=$0
    }
    in_resources && resource_start && /^  version:/ {
        gsub(/^  version: */, "")
        version=$0
    }
    in_resources && resource_start && /^  domain:/ {
        gsub(/^  domain: */, "")
        domain=$0
    }
    in_resources && resource_start && /^    defaulting:/ {
        gsub(/^    defaulting: */, "")
        webhooks_defaulting=$0
    }
    in_resources && resource_start && /^    validation:/ {
        gsub(/^    validation: */, "")
        webhooks_validation=$0
    }
    END {
        # Output the last resource
        if (resource_start && group != "" && kind != "" && version != "") {
            printf "%s|%s|%s|%s|%s|%s\n", group, kind, version, domain, webhooks_defaulting, webhooks_validation
        }
    }
    ' "$project_file" > "$RESOURCES_FILE"

    echo "Extracted resources:"
    cat "$RESOURCES_FILE"
    echo ""
}

# Step 1: Initialize new go/v4 project
init_operator() {
    local converted_dir="$1"
    local repo="$2"
    local domain="$3"
    local project_name="$4"
    local multigroup="$5"

    echo ""
    echo "Step 1: Initializing new go/v4 project in: $converted_dir"
    echo "========================================================"

    # Create the new directory
    mkdir -p "$converted_dir"

    # Store current directory and change to converted directory
    local original_dir=$(pwd)
    cd "$converted_dir"

    # Initialize go module first (required before operator-sdk init)
    echo "Initializing Go module..."
    go mod init "$repo"

    # Initialize the operator project with go/v4 plugin
    echo "Running operator-sdk init with go/v4 plugin..."
    operator-sdk init \
        --domain="$domain" \
        --project-name="$project_name" \
        --plugins=go/v4

    # Enable multigroup if it was enabled in the original project
    if [ "$multigroup" = "true" ]; then
        echo "Enabling multigroup layout..."
        operator-sdk edit --multigroup=true
    fi

    # Return to original directory
    cd "$original_dir"

    echo "✓ Operator initialized successfully with go/v4 plugin"
}

# Step 9.5: Copy go.mod from original project
copy_go_mod() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 9.5: Copying go.mod from original project"
    echo "========================================================"

    # Get module names
    local old_module=$(grep "^module " "$source_dir/go.mod" 2>/dev/null | cut -d' ' -f2)
    local new_module=$(grep "^module " "$converted_dir/go.mod" | cut -d' ' -f2)

    echo "Old module: $old_module"
    echo "New module: $new_module"

    # Copy main go.mod and update module name
    echo ""
    echo "Copying main go.mod (go.sum will be regenerated)..."
    if [ "$old_module" = "$new_module" ]; then
        # Module name is the same, just copy
        cp "$source_dir/go.mod" "$converted_dir/go.mod"
    else
        # Update the module name
        sed "s|^module .*|module $new_module|" "$source_dir/go.mod" > "$converted_dir/go.mod"

        # Update any replace directives that reference the old module
        sed -i "s|$old_module|$new_module|g" "$converted_dir/go.mod"
    fi

    echo ""
    echo "✓ Main go.mod copied successfully (go.sum will be regenerated by go mod tidy)"
}

# Step 2: Scaffold APIs and controllers for each resource
generate_apis() {
    local resources_file="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 2: Scaffolding APIs and Controllers"
    echo "========================================================"

    # Store current directory and change to converted directory
    local original_dir=$(pwd)
    cd "$converted_dir"

    while IFS='|' read -r group kind version domain webhooks_defaulting webhooks_validation; do
        if [ -n "$group" ] && [ -n "$kind" ] && [ -n "$version" ]; then
            echo ""
            echo "Scaffolding API: $group/$version Kind=$kind"

            # Scaffold API and controller (this creates the basic structure)
            create_cmd="operator-sdk create api --group=$group --version=$version --kind=$kind --resource --controller"

            echo "  Running: $create_cmd"
            $create_cmd

            echo "  ✓ API and controller scaffolded for $kind"
        fi
    done < "$resources_file"

    # Return to original directory
    cd "$original_dir"

    echo ""
    echo "✓ All APIs and controllers scaffolded successfully"
}

# Step 3: Scaffold webhooks for resources that have them
scaffold_webhooks() {
    local resources_file="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 3: Scaffolding Webhooks"
    echo "========================================================"

    # Store current directory and change to converted directory
    local original_dir=$(pwd)
    cd "$converted_dir"

    local has_webhooks=false

    while IFS='|' read -r group kind version domain webhooks_defaulting webhooks_validation; do
        if [ -n "$group" ] && [ -n "$kind" ] && [ -n "$version" ]; then
            # Generate webhooks if they were present in the original
            if [ "$webhooks_defaulting" = "true" ] || [ "$webhooks_validation" = "true" ]; then
                has_webhooks=true
                echo ""
                echo "Scaffolding webhook for: $group/$version Kind=$kind"

                webhook_cmd="operator-sdk create webhook --group=$group --version=$version --kind=$kind"

                if [ "$webhooks_defaulting" = "true" ]; then
                    webhook_cmd="$webhook_cmd --defaulting"
                fi

                if [ "$webhooks_validation" = "true" ]; then
                    webhook_cmd="$webhook_cmd --programmatic-validation"
                fi

                echo "  Running: $webhook_cmd"
                $webhook_cmd

                echo "  ✓ Webhook scaffolded for $kind"
            fi
        fi
    done < "$resources_file"

    # Return to original directory
    cd "$original_dir"

    if [ "$has_webhooks" = "true" ]; then
        echo ""
        echo "✓ All webhooks scaffolded successfully"
    else
        echo ""
        echo "No webhooks found in original project"
    fi
}

# Step 4: Migrate API definitions
migrate_api_definitions() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 4: Migrating API Definitions"
    echo "========================================================"

    if [ ! -d "$source_dir/api" ]; then
        echo "No api/ directory found in source project"
        return
    fi

    # Find all *_types.go files in the source
    find "$source_dir/api" -name "*_types.go" -type f | while read -r source_api_file; do
        # Get the relative path from api/ directory
        local rel_path=$(echo "$source_api_file" | sed "s|$source_dir/api/||")
        local target_api_file="$converted_dir/api/$rel_path"

        if [ -f "$target_api_file" ]; then
            echo ""
            echo "Migrating API types: $rel_path"

            # Backup the scaffolded file
            cp "$target_api_file" "$target_api_file.scaffold"

            # Simply copy the original API file - no need to merge
            cp "$source_api_file" "$target_api_file"

            echo "  ✓ Migrated API types for $(basename $rel_path .go)"
        else
            echo "  Warning: Scaffolded API file not found: $target_api_file"
            echo "  Copying original API file directly"
            local target_dir_path=$(dirname "$target_api_file")
            mkdir -p "$target_dir_path"
            cp "$source_api_file" "$target_api_file"
        fi
    done

    # Copy other non-types API files
    find "$source_dir/api" -name "*.go" -not -name "*_types.go" -not -name "zz_generated*" -not -name "*_webhook.go" -type f 2>/dev/null | while read -r api_file; do
        local rel_path=$(echo "$api_file" | sed "s|$source_dir/api/||")
        local target_file="$converted_dir/api/$rel_path"
        local target_dir_path=$(dirname "$target_file")

        mkdir -p "$target_dir_path"

        echo "  Copying additional API file: $rel_path"
        cp "$api_file" "$target_file"
    done

    echo ""
    echo "✓ API definitions migrated successfully"
}

# Step 5: Migrate api/go.mod (api as Go submodule)
migrate_api_gomod() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 5: Setting up api/ as Go Submodule"
    echo "========================================================"

    if [ ! -d "$converted_dir/api" ]; then
        echo "No api/ directory found in converted project"
        return
    fi

    # Get the module names
    local old_main_module=$(grep "^module " "$source_dir/go.mod" 2>/dev/null | cut -d' ' -f2)
    local new_main_module=$(grep "^module " "$converted_dir/go.mod" | cut -d' ' -f2)
    local new_api_module="${new_main_module}/api"

    echo "Main module: $new_main_module"
    echo "API module: $new_api_module"

    if [ -f "$source_dir/api/go.mod" ]; then
        echo ""
        echo "Copying api/go.mod from source project..."

        local old_api_module=$(grep "^module " "$source_dir/api/go.mod" | cut -d' ' -f2)
        echo "  Old API module: $old_api_module"
        echo "  New API module: $new_api_module"

        # Copy and update the api/go.mod
        sed "s|^module .*|module $new_api_module|" "$source_dir/api/go.mod" > "$converted_dir/api/go.mod"

        # Also update any replace directives that reference the old module
        if [ -n "$old_main_module" ] && [ "$old_main_module" != "$new_main_module" ]; then
            sed -i "s|$old_main_module|$new_main_module|g" "$converted_dir/api/go.mod"
        fi

        echo "  ✓ api/go.mod copied (go.sum will be regenerated)"
    else
        echo ""
        echo "No api/go.mod found in source, creating new one..."

        # Get Go version from main go.mod
        local go_version=$(grep "^go " "$converted_dir/go.mod" | cut -d' ' -f2)

        echo "  Creating api/go.mod with Go version: $go_version"

        # Create basic api/go.mod with common dependencies
        cat > "$converted_dir/api/go.mod" << EOF
module ${new_api_module}

go ${go_version}

require (
	k8s.io/apimachinery v0.31.0
	sigs.k8s.io/controller-runtime v0.19.0
)
EOF
    fi

    # Add replace directive to main go.mod if not already present
    echo ""
    echo "  Adding api module replace directive to main go.mod..."
    if ! grep -q "^replace ${new_api_module}" "$converted_dir/go.mod"; then
        echo "" >> "$converted_dir/go.mod"
        echo "replace ${new_api_module} => ./api" >> "$converted_dir/go.mod"
    fi

    echo ""
    echo "✓ api/ directory configured as Go submodule"
    echo "  Module: $new_api_module"
}

# Step 6: Migrate controller logic
migrate_controllers() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 6: Migrating Controller Logic"
    echo "========================================================"

    if [ ! -d "$source_dir/controllers" ]; then
        echo "No controllers/ directory found in source project"
        return
    fi

    # Find all *_controller.go files
    find "$source_dir/controllers" -name "*_controller.go" -type f | while read -r source_controller; do
        local controller_name=$(basename "$source_controller")
        # In v4, controllers are in internal/controller/
        local target_controller="$converted_dir/internal/controller/$controller_name"

        if [ -f "$target_controller" ]; then
            echo ""
            echo "Migrating controller: $controller_name"

            # Backup scaffolded controller
            cp "$target_controller" "$target_controller.scaffold"

            # Simply copy the entire source controller - we don't need to merge with scaffolded version
            # The scaffolded controller is just a template, we want the original logic
            cp "$source_controller" "$target_controller"

            # Update the package name to 'controller' (v4 uses package controller, not controllers)
            sed -i 's/^package controllers$/package controller/' "$target_controller"

            echo "  ✓ Migrated controller logic for $(basename $controller_name .go)"
        else
            echo "  Warning: Scaffolded controller not found: $target_controller"
            echo "  Copying controller directly..."
            mkdir -p "$converted_dir/internal/controller"
            cp "$source_controller" "$target_controller"
        fi
    done

    echo ""
    echo "✓ Controller logic migrated successfully"
}

# Step 7: Migrate webhooks
migrate_webhooks() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 7: Migrating Webhook Definitions"
    echo "========================================================"

    # Find webhook files in source
    local webhook_files=$(find "$source_dir/api" -name "*_webhook.go" -type f 2>/dev/null || true)

    if [ -z "$webhook_files" ]; then
        echo "No webhook files found in source project"
        return
    fi

    echo "$webhook_files" | while read -r source_webhook; do
        [ -z "$source_webhook" ] && continue

        local rel_path=$(echo "$source_webhook" | sed "s|$source_dir/api/||")
        local target_webhook="$converted_dir/api/$rel_path"

        echo ""
        echo "Migrating webhook: $rel_path"

        if [ -f "$target_webhook" ]; then
            # Backup scaffolded webhook
            cp "$target_webhook" "$target_webhook.scaffold"

            # Simply copy the original webhook file
            cp "$source_webhook" "$target_webhook"

            echo "  ✓ Migrated webhook definition"
        else
            echo "  Warning: Scaffolded webhook not found, copying directly"
            local target_dir_path=$(dirname "$target_webhook")
            mkdir -p "$target_dir_path"
            cp "$source_webhook" "$target_webhook"
        fi
    done

    echo ""
    echo "✓ Webhook definitions migrated successfully"
}

# Step 7.5: Copy webhook files from api/v1beta1 to internal/webhook/v1beta1
copy_webhooks_to_internal() {
    local converted_dir="$1"

    echo ""
    echo "Step 7.5: Copying webhook files to internal/webhook/v1beta1"
    echo "========================================================"

    if [ ! -d "$converted_dir/api/v1beta1" ]; then
        echo "No api/v1beta1/ directory found in converted project"
        return
    fi

    # Find all webhook files in api/v1beta1
    local webhook_files=$(find "$converted_dir/api/v1beta1" -type f -name "*webhook*.go" 2>/dev/null || true)

    if [ -z "$webhook_files" ]; then
        echo "No webhook files found in api/v1beta1/"
        return
    fi

    # Create internal/webhook/v1beta1 directory if it doesn't exist
    if [ ! -d "$converted_dir/internal/webhook/v1beta1" ]; then
        echo "Creating internal/webhook/v1beta1/ directory..."
        mkdir -p "$converted_dir/internal/webhook/v1beta1"
    fi

    # Copy each webhook file
    echo "$webhook_files" | while read -r file; do
        if [ -n "$file" ]; then
            local filename=$(basename "$file")
            echo "  ✓ Copying $filename to internal/webhook/v1beta1/"
            cp "$file" "$converted_dir/internal/webhook/v1beta1/$filename"
        fi
    done

    echo ""
    echo "✓ Webhook files copied to internal/webhook/v1beta1/ successfully"
}

# Step 8: Migrate pkg/ to internal/
migrate_pkg_to_internal() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 8: Migrating pkg/ to internal/"
    echo "========================================================"

    if [ ! -d "$source_dir/pkg" ]; then
        echo "No pkg/ directory found in source project"
        return
    fi

    echo "Copying pkg/ contents to internal/..."
    mkdir -p "$converted_dir/internal"

    # Copy all pkg contents to internal, preserving structure
    cp -r "$source_dir/pkg"/* "$converted_dir/internal/" 2>/dev/null || true

    # List what was migrated
    echo ""
    echo "Migrated packages:"
    find "$converted_dir/internal" -maxdepth 1 -type d ! -path "$converted_dir/internal" ! -path "*/controller" | sed "s|$converted_dir/internal/||" | while read -r pkg; do
        [ -n "$pkg" ] && echo "  - $pkg"
    done

    echo ""
    echo "✓ pkg/ migrated to internal/ successfully"
}

# Step 9: Update import paths
update_import_paths() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 9: Updating Import Paths"
    echo "========================================================"

    # Get old and new module names
    local old_module=$(grep "^module " "$source_dir/go.mod" 2>/dev/null | cut -d' ' -f2)
    local new_module=$(grep "^module " "$converted_dir/go.mod" | cut -d' ' -f2)

    if [ -z "$old_module" ]; then
        echo "Warning: Could not determine old module name"
        return
    fi

    echo "Old module: $old_module"
    echo "New module: $new_module"
    echo ""
    echo "Updating import paths in all Go files..."

    # Find all Go files and update import paths
    find "$converted_dir" -name "*.go" -type f ! -name "zz_generated*" | while read -r go_file; do
        local modified=false

        # Update pkg/ to internal/ imports
        if grep -q "$old_module/pkg/" "$go_file" 2>/dev/null; then
            sed -i "s|\"$old_module/pkg/|\"$new_module/internal/|g" "$go_file"
            modified=true
        fi

        # Update controllers to internal/controller
        if grep -q "$old_module/controllers" "$go_file" 2>/dev/null; then
            sed -i "s|\"$old_module/controllers|\"$new_module/internal/controller|g" "$go_file"
            modified=true
        fi

        # Update module name for API imports
        if grep -q "\"$old_module/api/" "$go_file" 2>/dev/null; then
            sed -i "s|\"$old_module/api/|\"$new_module/api/|g" "$go_file"
            modified=true
        fi

        # Update any other module references
        if grep -q "\"$old_module\"" "$go_file" 2>/dev/null; then
            sed -i "s|\"$old_module\"|\"$new_module\"|g" "$go_file"
            modified=true
        fi

        if [ "$modified" = "true" ]; then
            echo "  Updated: $(echo "$go_file" | sed "s|$converted_dir/||")"
        fi
    done

    # Update go.mod to remove old controller references
    echo ""
    echo "Cleaning up go.mod..."

    if [ -f "$converted_dir/go.mod" ]; then
        # Remove any replace directives for old paths
        if grep -q "^replace.*$old_module/controllers" "$converted_dir/go.mod" 2>/dev/null; then
            echo "  Removing old controller replace directive"
            sed -i "/^replace.*$old_module\/controllers/d" "$converted_dir/go.mod"
        fi

        if grep -q "^replace.*$old_module/pkg" "$converted_dir/go.mod" 2>/dev/null; then
            echo "  Removing old pkg replace directive"
            sed -i "/^replace.*$old_module\/pkg/d" "$converted_dir/go.mod"
        fi

        # Update module references in replace directives if module name changed
        if [ "$old_module" != "$new_module" ]; then
            if grep -q "$old_module" "$converted_dir/go.mod" 2>/dev/null; then
                echo "  Updating module references in go.mod"
                sed -i "s|$old_module|$new_module|g" "$converted_dir/go.mod"
            fi
        fi
    fi

    echo ""
    echo "✓ Import paths updated successfully"
}

# Step 10: Migrate and update main.go
migrate_main_go() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 10: Migrating main.go"
    echo "========================================================"

    local source_main="$source_dir/main.go"
    local target_main="$converted_dir/cmd/main.go"

    if [ ! -f "$source_main" ]; then
        echo "No main.go found in source project"
        return
    fi

    if [ ! -f "$target_main" ]; then
        echo "Warning: cmd/main.go not found in converted project"
        return
    fi

    # Backup the scaffolded cmd/main.go
    cp "$target_main" "$target_main.scaffold"

    echo "Extracting components from original main.go..."

    # Create temporary files for extracted content
    local temp_imports=$(mktemp)
    local temp_init_body=$(mktemp)
    local temp_leader_id=$(mktemp)
    local temp_cfg_kclient=$(mktemp)

    # Extract custom imports (excluding standard library and already present ones)
    echo "  - Extracting custom imports..."

    # First, get existing imports from target cmd/main.go
    local temp_target_imports=$(mktemp)
    awk '
    /^import \(/ { in_import=1; next }
    in_import && /^\)/ { in_import=0; next }
    in_import {
        # Skip comments and empty lines
        if ($0 ~ /^[[:space:]]*\/\// || $0 ~ /^[[:space:]]*$/) next
        # Normalize and store
        gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        print $0
    }
    ' "$target_main" > "$temp_target_imports"

    # Now extract imports from source, filtering out duplicates
    awk -v target_imports="$temp_target_imports" '
    BEGIN {
        # Load target imports into an array
        while ((getline line < target_imports) > 0) {
            existing[line] = 1
        }
        close(target_imports)
    }
    /^import \(/ { in_import=1; next }
    in_import && /^\)/ { in_import=0; next }
    in_import {
        # Skip comments and empty lines
        if ($0 ~ /^[[:space:]]*\/\// || $0 ~ /^[[:space:]]*$/) next

        # Normalize the import line
        line = $0
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)

        # Skip if already exists in target
        if (line in existing) next

        # Skip imports containing "controllers" as they will be migrated to internal/controller
        if (line ~ /controllers/) next

        # Print the import line
        print $0
    }
    ' "$source_main" > "$temp_imports"

    rm -f "$temp_target_imports"

    # Extract init() function body (contents between braces)
    echo "  - Extracting init() function contents..."
    awk '
    /^func init\(\) \{/ {
        # Found init function with opening brace on same line
        in_init=1
        brace_count=1
        next
    }
    /^func init\(\)$/ {
        # Found init function, brace on next line
        in_init=1
        brace_count=0
        next
    }
    in_init {
        if ($0 ~ /\{/) brace_count++
        if ($0 ~ /\}/) {
            brace_count--
            if (brace_count == 0) {
                in_init=0
                next
            }
        }
        if (in_init) print $0
    }
    ' "$source_main" > "$temp_init_body"

    # Extract LeaderElectionID value
    echo "  - Extracting LeaderElectionID..."
    grep "LeaderElectionID:" "$source_main" | sed 's/.*LeaderElectionID:[[:space:]]*"\([^"]*\)".*/\1/' > "$temp_leader_id"

    # Extract cfg and kclient creation code
    echo "  - Extracting cfg and kclient creation code..."
    awk '
    /cfg, err := config\.GetConfig\(\)/ { capturing=1 }
    capturing {
        print $0
        if ($0 ~ /kclient, err := kubernetes\.NewForConfig\(cfg\)/) {
            # Continue until we find the closing brace of the error check
            getline; print $0  # if err != nil {
            getline; print $0  # setupLog.Error...
            getline; print $0  # os.Exit(1)
            getline; print $0  # }
            exit
        }
    }
    ' "$source_main" > "$temp_cfg_kclient"

    # Now modify the target main.go

    # 1. Add custom imports after existing imports, before the closing paren
    if [ -s "$temp_imports" ]; then
        echo "  - Adding custom imports to cmd/main.go..."
        # Find the last import line before the closing ), insert our imports there
        awk -v imports="$(cat $temp_imports)" '
        /^import \(/ { in_import=1; print; next }
        in_import && /^\)/ {
            # Print our custom imports before the closing paren
            print imports
            print
            in_import=0
            next
        }
        { print }
        ' "$target_main" > "$target_main.tmp"
        mv "$target_main.tmp" "$target_main"
    fi

    # 2. Replace init() function body
    if [ -s "$temp_init_body" ]; then
        echo "  - Replacing init() function contents..."
        awk -v new_body="$(cat $temp_init_body)" '
        /^func init\(\) \{/ {
            # Opening brace is on the same line
            print "func init() {"
            print new_body
            # Skip until we find the closing brace
            brace_count=1  # Already have one opening brace
            in_init=1
            next
        }
        /^func init\(\)$/ {
            # Opening brace is on the next line
            print "func init() {"
            print new_body
            # Skip until we find the closing brace
            brace_count=0  # Will increment when we see the brace
            in_init=1
            next
        }
        in_init {
            if ($0 ~ /{/) brace_count++
            if ($0 ~ /}/) {
                brace_count--
                if (brace_count == 0) {
                    print "}"
                    in_init=0
                    next
                }
            }
            next
        }
        { print }
        ' "$target_main" > "$target_main.tmp"
        mv "$target_main.tmp" "$target_main"
    fi

    # 3. Update LeaderElectionID
    if [ -s "$temp_leader_id" ]; then
        local leader_id=$(cat "$temp_leader_id")
        echo "  - Setting LeaderElectionID to: $leader_id..."
        sed -i "s/LeaderElectionID:[[:space:]]*\"[^\"]*\"/LeaderElectionID:       \"$leader_id\"/" "$target_main"
    fi

    # 4. Insert cfg and kclient creation code after mgr creation
    if [ -s "$temp_cfg_kclient" ]; then
        echo "  - Adding cfg and kclient creation code..."
        awk -v cfg_code="$(cat $temp_cfg_kclient)" '
        /mgr, err := ctrl\.NewManager/ {
            # We found the start of NewManager call
            # Need to print lines until we find the closing of the if statement
            in_mgr_block=1
            brace_count=0
            paren_count=0
            print
            next
        }
        in_mgr_block {
            # Track braces for the if block
            if ($0 ~ /\{/) brace_count++
            if ($0 ~ /\}/) brace_count--

            # Track parentheses for the NewManager call
            if ($0 ~ /\(/) paren_count++
            if ($0 ~ /\)/) paren_count--

            print

            # When we close the if block (after error handling)
            if (brace_count < 0 || ($0 ~ /^\t\}$/ && paren_count == 0)) {
                # Insert blank line and cfg/kclient code
                print ""
                print cfg_code
                in_mgr_block=0
            }
            next
        }
        { print }
        ' "$target_main" > "$target_main.tmp"
        mv "$target_main.tmp" "$target_main"
    fi

    # 5. Update Reconciler constructors to include Client, Scheme, and Kclient
    echo "  - Updating Reconciler constructor arguments..."

    # First, read the original main.go to extract SetupWithManager arguments for each reconciler
    local temp_reconciler_patterns=$(mktemp)
    awk '
    /if err = \(&controllers\.[A-Za-z]*Reconciler\{/ {
        # Extract reconciler type name
        match($0, /controllers\.([A-Za-z]*Reconciler)/, arr)
        reconciler_type = arr[1]
        in_reconciler = 1
        next
    }
    in_reconciler && /\}\)\.SetupWithManager/ {
        # Extract the SetupWithManager arguments
        # Use a more robust approach to handle nested parentheses like context.Background()
        match($0, /SetupWithManager\(/, arr)
        start_pos = RSTART + RLENGTH
        paren_count = 1
        setup_args = ""
        rest_line = substr($0, start_pos)

        for (i = 1; i <= length(rest_line); i++) {
            char = substr(rest_line, i, 1)
            if (char == "(") paren_count++
            else if (char == ")") {
                paren_count--
                if (paren_count == 0) break
            }
            if (paren_count > 0) setup_args = setup_args char
        }

        print reconciler_type "|" setup_args
        in_reconciler = 0
    }
    ' "$source_main" > "$temp_reconciler_patterns"

    # Now update the target main.go with the proper initialization
    # We need to preserve the SetupWithManager arguments from the original
    awk -v patterns_file="$temp_reconciler_patterns" '
    BEGIN {
        # Load the reconciler patterns into an array
        while ((getline line < patterns_file) > 0) {
            split(line, parts, "|")
            setup_args[parts[1]] = parts[2]
        }
        close(patterns_file)
        in_reconciler=0
        reconciler_name=""
    }

    # Match the pattern: if err := (&controller.XxxReconciler{ or if err = (&controller.XxxReconciler{
    /if err :?= \(&controller\.[A-Za-z]*Reconciler\{/ {
        # Extract the reconciler name
        match($0, /controller\.([A-Za-z]*Reconciler)/, arr)
        reconciler_name = arr[1]
        in_reconciler=1

        # Determine if using := or =
        if ($0 ~ /if err :=/) {
            err_op = ":="
        } else {
            err_op = "="
        }

        # Use original SetupWithManager args if available, otherwise default to mgr
        if (reconciler_name in setup_args) {
            saved_setup_args = setup_args[reconciler_name]
        } else {
            saved_setup_args = "mgr"
        }

        print "\tif err " err_op " (&controller." reconciler_name "{"
        print "\t\tClient:  mgr.GetClient(),"
        print "\t\tScheme:  mgr.GetScheme(),"
        print "\t\tKclient: kclient,"
        next
    }

    # Skip the closing brace and SetupWithManager line if we are in reconciler
    in_reconciler && /\}\)\.SetupWithManager/ {
        print "\t}).SetupWithManager(" saved_setup_args "); err != nil {"
        in_reconciler=0
        next
    }

    # Skip any lines between the opening and closing of reconciler initialization
    in_reconciler {
        next
    }

    # Print all other lines
    { print }
    ' "$target_main" > "$target_main.tmp"
    mv "$target_main.tmp" "$target_main"

    rm -f "$temp_reconciler_patterns"

    # Clean up temp files
    rm -f "$temp_imports" "$temp_init_body" "$temp_leader_id" "$temp_cfg_kclient"

    echo ""
    echo "✓ main.go migrated successfully"
    echo "  Original main.go components have been integrated into cmd/main.go"
    echo "  Backup available at: cmd/main.go.scaffold"
}

# Step 11: Sync go.mod dependencies
sync_go_dependencies() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 11: Syncing Go Dependencies"
    echo "========================================================"

    # Get old and new module names for cleanup
    local old_module=$(grep "^module " "$source_dir/go.mod" 2>/dev/null | cut -d' ' -f2)
    local new_module=$(grep "^module " "$converted_dir/go.mod" | cut -d' ' -f2)

    # Clean up go.mod before running go mod tidy
    echo "Cleaning up go.mod before syncing..."

    if [ -f "$converted_dir/go.mod" ]; then
        # Remove any require statements for old controller or pkg paths
        if grep -q "$old_module/controllers" "$converted_dir/go.mod" 2>/dev/null; then
            echo "  Removing old controllers require statements"
            sed -i "/$old_module\/controllers/d" "$converted_dir/go.mod"
        fi

        if grep -q "$old_module/pkg" "$converted_dir/go.mod" 2>/dev/null; then
            echo "  Removing old pkg require statements"
            sed -i "/$old_module\/pkg/d" "$converted_dir/go.mod"
        fi

        # Also check for any stray old module references
        if [ -n "$old_module" ] && [ "$old_module" != "$new_module" ]; then
            # Remove any require lines with old module (except for api submodule if it exists)
            sed -i "/require.*$old_module[^\/]/d" "$converted_dir/go.mod"
        fi
    fi

    # Store current directory
    local original_dir=$(pwd)

    # Run go mod tidy in api directory first (if it exists)
    if [ -d "$converted_dir/api" ] && [ -f "$converted_dir/api/go.mod" ]; then
        echo ""
        echo "Running go mod tidy in api/ directory..."
        cd "$converted_dir/api"
        go mod tidy
        cd "$original_dir"
    fi

    # Run go mod tidy in main directory
    cd "$converted_dir"
    echo ""
    echo "Running go mod tidy in main directory..."
    go mod tidy

    cd "$original_dir"

    echo ""
    echo "✓ Go dependencies synced successfully"
}

# Step 12: Copy additional configuration files
copy_config_files() {
    local source_dir="$1"
    local converted_dir="$2"

    echo ""
    echo "Step 12: Copying Additional Configuration Files"
    echo "========================================================"

    # Copy common files
    for file in .gitignore README.md LICENSE Dockerfile .dockerignore; do
        if [ -f "$source_dir/$file" ]; then
            echo "  Copying $file"
            cp "$source_dir/$file" "$converted_dir/"
        fi
    done

    # Copy custom directories (templates, scripts, etc.)
    for dir in templates scripts hack; do
        if [ -d "$source_dir/$dir" ]; then
            echo "  Copying $dir/ directory"
            cp -r "$source_dir/$dir" "$converted_dir/"
        fi
    done

    # Copy config/manifests/bases/ directory for OLM bundle configuration
    if [ -d "$source_dir/config/manifests/bases" ]; then
        echo "  Copying config/manifests/bases/ directory"
        mkdir -p "$converted_dir/config/manifests"
        cp -r "$source_dir/config/manifests/bases" "$converted_dir/config/manifests/"
    fi

    echo ""
    echo "✓ Additional configuration files copied"
}

# Step 13: Remove unnecessary directories and files
cleanup_unnecessary_files() {
    local converted_dir="$1"

    echo ""
    echo "Step 13: Removing Unnecessary Directories and Files"
    echo "========================================================"

    # Remove .github/workflows directory
    if [ -d "$converted_dir/.github/workflows" ]; then
        echo "  Removing .github/workflows/ directory"
        rm -rf "$converted_dir/.github/workflows"
    fi

    # Remove .golangci.yml file
    if [ -f "$converted_dir/.golangci.yml" ]; then
        echo "  Removing .golangci.yml file"
        rm -f "$converted_dir/.golangci.yml"
    fi

    # Remove .devcontainer directory
    if [ -d "$converted_dir/.devcontainer" ]; then
        echo "  Removing .devcontainer/ directory"
        rm -rf "$converted_dir/.devcontainer"
    fi

    echo ""
    echo "✓ Unnecessary files and directories removed"
}

# Main execution
main() {
    # Parse the PROJECT file
    parse_project_file "$PROJECT_FILE"

    if [ -z "$PROJECT_NAME" ] || [ -z "$REPO" ] || [ -z "$DOMAIN" ]; then
        echo "Error: Failed to parse required fields from PROJECT file"
        exit 1
    fi

    # Extract resources
    extract_resources "$PROJECT_FILE"

    # Set up converted directory with v4 suffix
    CONVERTED_DIR="${OPERATOR_DIR}-v4"

    # Remove existing converted directory if it exists
    if [ -d "$CONVERTED_DIR" ]; then
        echo ""
        echo "Warning: Directory '$CONVERTED_DIR' already exists"
        read -p "Remove and continue? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo "Removing existing directory: $CONVERTED_DIR"
            rm -rf "$CONVERTED_DIR"
        else
            echo "Migration cancelled"
            exit 1
        fi
    fi

    # Step 1: Initialize the new go/v4 operator
    init_operator "$CONVERTED_DIR" "$REPO" "$DOMAIN" "$PROJECT_NAME" "${MULTIGROUP:-false}"

    # Step 2: Scaffold APIs and controllers
    generate_apis "$RESOURCES_FILE" "$CONVERTED_DIR"

    # Step 3: Scaffold webhooks (if any)
    scaffold_webhooks "$RESOURCES_FILE" "$CONVERTED_DIR"

    # Step 4: Migrate API definitions from old project
    migrate_api_definitions "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 5: Migrate api/go.mod (api as Go submodule)
    migrate_api_gomod "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 6: Migrate controller logic from old project
    migrate_controllers "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 7: Migrate webhook implementations
    migrate_webhooks "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 7.5: Copy webhook files to internal/v1beta1
    #copy_webhooks_to_internal "$CONVERTED_DIR"

    # Step 8: Migrate pkg/ directory to internal/
    migrate_pkg_to_internal "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 9: Update all import paths
    update_import_paths "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 9.5: Copy go.mod from original project
    copy_go_mod "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 10: Migrate main.go
    migrate_main_go "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 11: Sync Go dependencies
    sync_go_dependencies "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 12: Copy additional configuration files
    copy_config_files "$OPERATOR_DIR" "$CONVERTED_DIR"

    # Step 13: Remove unnecessary directories and files
    cleanup_unnecessary_files "$CONVERTED_DIR"

    # Clean up temporary files
    rm -f "$RESOURCES_FILE"

    # Verify no old paths remain
    echo ""
    echo "Verifying migration..."
    local old_module=$(grep "^module " "$OPERATOR_DIR/go.mod" 2>/dev/null | cut -d' ' -f2)

    if grep -q "$old_module/controllers" "$CONVERTED_DIR/cmd/main.go" 2>/dev/null; then
        echo "⚠ WARNING: Old controller path still found in cmd/main.go"
    fi

    if grep -q "$old_module/controllers" "$CONVERTED_DIR/go.mod" 2>/dev/null; then
        echo "⚠ WARNING: Old controller path still found in go.mod"
    fi

    echo ""
    echo "========================================="
    echo "Migration Completed Successfully!"
    echo "========================================="
    echo ""
    echo "New go/v4 operator created at: $CONVERTED_DIR"
    echo ""
    echo "Next Steps:"
    echo "---------------------------------------"
    echo "1. Review the migrated code in $CONVERTED_DIR"
    echo ""
    echo "2. Check scaffolded backups (.scaffold files) if you need to see what changed:"
    echo "   find $CONVERTED_DIR -name '*.scaffold'"
    echo ""
    echo "3. Review cmd/main.go changes:"
    echo "   - Original main.go copied from root to cmd/main.go"
    echo "   - Applied operator-sdk v1.38.0 updates (metrics configuration)"
    echo "   - Compare with backup: cmd/main.go.scaffold"
    echo ""
    echo "4. Review and update the Makefile for any custom targets:"
    echo "   - Standard targets are regenerated with go/v4"
    echo "   - Custom targets from old Makefile may need manual migration"
    echo ""
    echo "5. Test the build:"
    echo "   cd $CONVERTED_DIR"
    echo "   make manifests generate"
    echo "   make build"
    echo ""
    echo "6. Run tests:"
    echo "   make test"
    echo ""
    echo "7. Review PROJECT file changes and update if needed"
    echo ""
    echo "8. Update webhook imports in internal/webhook/v1beta1/ if needed"
    echo ""
    echo "9. Consider updating to Kustomize v5 in Makefile (see migration guide)"
    echo ""
    echo "Documentation:"
    echo "  - Kubebuilder v3 to v4 migration: https://book.kubebuilder.io/migration/migration_guide_gov3_to_gov4"
    echo "  - Operator SDK v1.38.0 upgrade: https://sdk.operatorframework.io/docs/upgrading-sdk-version/v1.38.0/"
    echo "========================================="
}

# Execute main function
main
