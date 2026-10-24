#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/.build/logging-checks"
swiftc "$PROJECT_DIR/Sources/WindowOffset/EventLog.swift" "$PROJECT_DIR/Checks/LoggingChecks.swift" -o "$PROJECT_DIR/.build/logging-checks/LoggingChecks"
"$PROJECT_DIR/.build/logging-checks/LoggingChecks"
