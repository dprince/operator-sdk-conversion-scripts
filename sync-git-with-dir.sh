#!/bin/bash

# Script to sync a git repository with another directory
# Usage: sync-git-with-dir.sh <git-repo-path> <source-dir-path>

set -e

# Check arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <git-repo-path> <source-dir-path>"
    echo "  git-repo-path: Path to the git repository to sync"
    echo "  source-dir-path: Path to the directory to sync from"
    exit 1
fi

GIT_REPO="$1"
SOURCE_DIR="$2"

# Validate directories exist
if [ ! -d "$GIT_REPO" ]; then
    echo "Error: Git repository directory does not exist: $GIT_REPO"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

# Validate git repository
if [ ! -d "$GIT_REPO/.git" ]; then
    echo "Error: Not a git repository: $GIT_REPO"
    exit 1
fi

# Convert to absolute paths
GIT_REPO=$(cd "$GIT_REPO" && pwd)
SOURCE_DIR=$(cd "$SOURCE_DIR" && pwd)

# Extract operator name from git repository path
# e.g., /path/to/glance-operator -> glance
REPO_NAME=$(basename "$GIT_REPO")
OPERATOR_NAME="${REPO_NAME%-operator}"

echo "Syncing git repository: $GIT_REPO"
echo "From source directory: $SOURCE_DIR"
echo "Operator name: $OPERATOR_NAME"
echo ""

# Change to git repository
cd "$GIT_REPO"

# Handle migration of tests directory to test
if [ -d "tests" ] && [ ! -d "test" ]; then
    echo "Migrating tests directory to test..."
    git mv tests test
    echo ""
fi

# Handle migration of controllers directory to internal/controller
if [ -d "controllers" ]; then
    echo "Migrating controllers directory to internal/controller..."

    # Create internal/controller directory if it doesn't exist
    mkdir -p "internal/controller"

    # Move each file from controllers to internal/controller using git mv
    git ls-files controllers/ 2>/dev/null | while IFS= read -r file; do
        # Get the filename without the controllers/ prefix
        filename="${file#controllers/}"
        target="internal/controller/$filename"

        # Create subdirectories if needed
        target_dir=$(dirname "$target")
        mkdir -p "$target_dir"

        echo "  Moving: $file -> $target"
        git mv "$file" "$target"
    done

    # Remove the now-empty controllers directory if it exists
    if [ -d "controllers" ] && [ -z "$(ls -A controllers 2>/dev/null)" ]; then
        rmdir controllers
        echo "  Removed empty controllers directory"
    fi

    echo ""
fi

# Handle migration of pkg/${OPERATOR_NAME} directory to internal/${OPERATOR_NAME}
if [ -d "pkg/${OPERATOR_NAME}" ]; then
    echo "Migrating pkg/${OPERATOR_NAME} directory to internal/${OPERATOR_NAME}..."

    # Create internal/${OPERATOR_NAME} directory if it doesn't exist
    mkdir -p "internal/${OPERATOR_NAME}"

    # Move each file from pkg/${OPERATOR_NAME} to internal/${OPERATOR_NAME} using git mv
    git ls-files "pkg/${OPERATOR_NAME}/" 2>/dev/null | while IFS= read -r file; do
        # Get the filename without the pkg/${OPERATOR_NAME}/ prefix
        filename="${file#pkg/${OPERATOR_NAME}/}"
        target="internal/${OPERATOR_NAME}/$filename"

        # Create subdirectories if needed
        target_dir=$(dirname "$target")
        mkdir -p "$target_dir"

        echo "  Moving: $file -> $target"
        git mv "$file" "$target"
    done

    # Remove the now-empty pkg/${OPERATOR_NAME} directory if it exists
    if [ -d "pkg/${OPERATOR_NAME}" ] && [ -z "$(ls -A "pkg/${OPERATOR_NAME}" 2>/dev/null)" ]; then
        rmdir "pkg/${OPERATOR_NAME}"
        echo "  Removed empty pkg/${OPERATOR_NAME} directory"
    fi

    # Remove pkg directory if it's now empty
    if [ -d "pkg" ] && [ -z "$(ls -A pkg 2>/dev/null)" ]; then
        rmdir pkg
        echo "  Removed empty pkg directory"
    fi

    echo ""
fi

# Handle migration of api/v1beta1/*webhook* files to internal/webhook/v1beta1
#echo "Migrating webhook files from api/v1beta1/ to internal/webhook/v1beta1/..."

# Create internal/webhook/v1beta1 directory if it doesn't exist
#mkdir -p "internal/webhook/v1beta1"

# Move webhook files from api/v1beta1 to internal/webhook/v1beta1 using git mv
#git ls-files 'api/v1beta1/*webhook*' 2>/dev/null | while IFS= read -r file; do
    ## Get the filename without the api/v1beta1/ prefix
    #filename=$(basename "$file")
    #target="internal/webhook/v1beta1/$filename"
#
    #echo "  Moving: $file -> $target"
    #git mv "$file" "$target"
#done

echo ""

# Get list of tracked files in git (excluding .git directory)
echo "Finding files to remove..."
git ls-files | while IFS= read -r file; do
    # Skip certain top-level files that should be preserved
    case "$file" in
        *.scaffold)
            echo "  Skipping scaffold file: $file"
            continue
            ;;
        OWNERS|OWNERS_ALIASES|LICENSE.txt|kuttl-test.json|renovate.json|Makefile)
            echo "  Skipping protected top-level file: $file"
            continue
            ;;
        zuul.d/*)
            echo "  Skipping zuul.d directory file: $file"
            continue
            ;;
        .github/*)
            echo "  Skipping .github directory file: $file"
            continue
            ;;
        config/samples/*)
            echo "  Skipping config/samples directory file: $file"
            continue
            ;;
        test/*)
            echo "  Skipping test directory file: $file"
            continue
            ;;
        internal/*)
            echo "  Skipping internal directory file: $file"
            continue
            ;;
        .*)
            # Skip files starting with '.' in top-level directory only
            if [[ "$file" != */* ]]; then
                echo "  Skipping hidden top-level file: $file"
                continue
            fi
            ;;
    esac

    # Check if file exists in source directory
    if [ ! -e "$SOURCE_DIR/$file" ]; then
        echo "  Removing: $file"
        git rm -q "$file"
    fi
done

# Copy all files from source directory to git repository
echo ""
echo "Copying files from source directory..."
rsync -av --exclude='.git' --exclude='*.scaffold' --exclude='.golangci.yml' --exclude='test' --exclude='config/samples' --exclude='Makefile' "$SOURCE_DIR/" "$GIT_REPO/"

# Add any new files to git
echo ""
echo "Adding new/modified files to git..."
git add -A

echo ""
echo "Sync complete!"
echo ""
echo "Summary of changes:"
git status --short
