#!/bin/bash

# chmod +x your-script.sh

set -o pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BREW_UPDATE_TIMEOUT_SECS=${BREW_UPDATE_TIMEOUT_SECS:-600}

run_with_progress_timeout() {
    local timeout_secs=$1
    shift
    local elapsed=0
    local bar_width=24

    echo ""
    "$@" &
    local command_pid=$!

    while kill -0 "$command_pid" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$timeout_secs" ]; then
            kill "$command_pid" >/dev/null 2>&1
            wait "$command_pid" 2>/dev/null
            printf "\r%*s\r" 80 ""
            return 124
        fi

        local filled=$((elapsed * bar_width / timeout_secs))
        local empty=$((bar_width - filled))
        local bar=""

        for ((i = 0; i < filled; i++)); do
            bar="${bar}#"
        done

        for ((i = 0; i < empty; i++)); do
            bar="${bar}-"
        done

        printf "\rUpdating Homebrew metadata [%s] %ds/%ds" "$bar" "$elapsed" "$timeout_secs"
        sleep 1
        ((elapsed++))
    done

    wait "$command_pid"
    local command_exit_code=$?

    printf "\r%*s\r" 80 ""

    return "$command_exit_code"
}

echo "========================================"
echo "   AI Coding Assistants Updater"
echo "========================================"
echo ""

echo -e "${YELLOW}[0/4] Updating: Homebrew metadata${NC}"
echo "exec: brew update (timeout: ${BREW_UPDATE_TIMEOUT_SECS}s)"
echo "----------------------------------------"

run_with_progress_timeout "$BREW_UPDATE_TIMEOUT_SECS" brew update
brew_update_exit_code=$?
if [ $brew_update_exit_code -eq 0 ]; then
    echo -e "${GREEN}✓ Homebrew metadata Update Success ${NC}"
elif [ $brew_update_exit_code -eq 124 ] || [ $brew_update_exit_code -eq 143 ]; then
    echo -e "${RED}✗ Homebrew update timed out after ${BREW_UPDATE_TIMEOUT_SECS}s, continuing upgrades...${NC}"
else
    echo -e "${RED}✗ Homebrew update failed (Error Code: $brew_update_exit_code), continuing upgrades...${NC}"
fi

echo ""

commands=(
    "HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade claude-code|Claude Code (Homebrew)"
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
