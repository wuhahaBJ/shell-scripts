#!/bin/bash

# chmod +x your-script.sh

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================"
echo "   AI Coding Assistants Updater"
echo "========================================"
echo ""

commands=(
    "brew upgrade claude-code|Claude Code (Homebrew)"
    "npm i -g @openai/codex@latest|OpenAI Codex (npm)"
    "npm update -g @google/gemini-cli|Google Gemini CLI (npm)"
    "opencode upgrade|OpenCode CLI"
)

total=${#commands[@]}
success=0
failed=0

for i in "${!commands[@]}"; do
    IFS='|' read -r cmd name <<< "${commands[$i]}"
    
    echo -e "${YELLOW}[$((i+1))/$total] Updating: $name${NC}"
    echo "exec: $cmd"
    echo "----------------------------------------"
    
    if eval "$cmd"; then
        echo -e "${GREEN}✓ $name Update Success ${NC}"
        ((success++))
    else
        echo -e "${RED}✗ $name Update Failed (Error Code : $?)${NC}"
        ((failed++))
    fi
    
    echo ""
done

echo "========================================"
echo "           Upgrade Summary"
echo "========================================"
echo -e "Total: $total | ${GREEN}Success: $success${NC} | ${RED}Failed: $failed${NC}"
echo ""

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}All tools upgraded successfully!${NC}"
    exit 0
else
    echo -e "${YELLOW}Some tools failed to upgrade. Please check the error messages above.${NC}"
    exit 1
fi