#!/bin/bash

# Real Device Testing Script for Phase 2B.1
# This script automates APK building, deployment, and log collection

set -e

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="$PROJECT_ROOT/testing_logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
TEST_SESSION_DIR="$TEST_DIR/$TIMESTAMP"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Phase 2B.1 Real Device Testing Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Functions
check_environment() {
    echo -e "${YELLOW}Checking environment...${NC}"

    # Check Flutter
    if ! command -v flutter &> /dev/null; then
        echo -e "${RED}❌ Flutter not found in PATH${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Flutter found${NC}"

    # Check ADB
    if ! command -v adb &> /dev/null; then
        echo -e "${RED}❌ ADB not found in PATH${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ ADB found${NC}"

    # Check connected devices
    DEVICE_COUNT=$(adb devices | grep -c "device$" || true)
    if [ "$DEVICE_COUNT" -eq 0 ]; then
        echo -e "${RED}❌ No devices connected${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ Found $DEVICE_COUNT device(s)${NC}"
    echo ""

    # List devices
    echo -e "${BLUE}Connected devices:${NC}"
    adb devices | grep "device$" | awk '{print "  - " $1}'
    echo ""
}

build_apk() {
    echo -e "${YELLOW}Building APK for testing...${NC}"
    cd "$PROJECT_ROOT"

    # Clean
    echo "  Cleaning build artifacts..."
    flutter clean > /dev/null 2>&1

    # Build
    echo "  Building APK (this may take 3-5 minutes)..."
    flutter build apk --release

    if [ -f "build/app/outputs/flutter-app.apk" ]; then
        SIZE=$(du -h "build/app/outputs/flutter-app.apk" | cut -f1)
        echo -e "${GREEN}✅ APK built successfully (${SIZE})${NC}"
    else
        echo -e "${RED}❌ APK build failed${NC}"
        exit 1
    fi
    echo ""
}

deploy_apk() {
    echo -e "${YELLOW}Deploying APK to devices...${NC}"

    while IFS= read -r device; do
        if [[ $device == *"device"* ]]; then
            DEVICE_ID=$(echo $device | awk '{print $1}')
            echo "  Installing on $DEVICE_ID..."
            adb -s "$DEVICE_ID" install -r "$PROJECT_ROOT/build/app/outputs/flutter-app.apk" > /dev/null 2>&1
            echo -e "${GREEN}  ✅ Installed on $DEVICE_ID${NC}"
        fi
    done < <(adb devices)
    echo ""
}

start_logging() {
    echo -e "${YELLOW}Starting log collection...${NC}"

    mkdir -p "$TEST_SESSION_DIR"

    while IFS= read -r device; do
        if [[ $device == *"device"* ]]; then
            DEVICE_ID=$(echo $device | awk '{print $1}')
            SAFE_ID=$(echo "$DEVICE_ID" | sed 's/:/_/g')
            LOG_FILE="$TEST_SESSION_DIR/device_${SAFE_ID}.log"

            echo "  Clearing logcat buffer on $DEVICE_ID..."
            adb -s "$DEVICE_ID" logcat -c 2>/dev/null || true

            echo "  Starting log collection for $DEVICE_ID..."
            adb -s "$DEVICE_ID" logcat -s "flutter" > "$LOG_FILE" &
            echo -e "${GREEN}  ✅ Logging to ${LOG_FILE}${NC}"
        fi
    done < <(adb devices)
    echo ""
}

stop_logging() {
    echo -e "${YELLOW}Stopping log collection...${NC}"
    pkill -f "adb.*logcat" || true
    echo -e "${GREEN}✅ Log collection stopped${NC}"
    echo ""
}

show_menu() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Test Scenarios${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1. Scenario 1: Direct Message (2-3 devices)"
    echo "2. Scenario 2: Offline Queue (2-3 devices)"
    echo "3. Scenario 3: Routing Service (2-3 devices)"
    echo "4. Scenario 4: Topology Changes (3 devices)"
    echo "5. View real-time logs"
    echo "6. Analyze logs after testing"
    echo "7. Exit"
    echo ""
}

view_logs() {
    echo -e "${YELLOW}Real-time log viewing${NC}"
    echo "Select device to monitor (press Ctrl+C to stop):"
    echo ""

    DEVICE_NUM=1
    while IFS= read -r device; do
        if [[ $device == *"device"* ]]; then
            DEVICE_ID=$(echo $device | awk '{print $1}')
            echo "$DEVICE_NUM. $DEVICE_ID"
            ((DEVICE_NUM++))
        fi
    done < <(adb devices)

    read -p "Enter selection: " SELECTED

    DEVICE_NUM=1
    while IFS= read -r device; do
        if [[ $device == *"device"* ]]; then
            if [ "$DEVICE_NUM" = "$SELECTED" ]; then
                DEVICE_ID=$(echo $device | awk '{print $1}')
                echo -e "${YELLOW}Monitoring ${DEVICE_ID} (Ctrl+C to stop)${NC}"
                adb -s "$DEVICE_ID" logcat -s "flutter"
                break
            fi
            ((DEVICE_NUM++))
        fi
    done < <(adb devices)
}

analyze_logs() {
    echo -e "${YELLOW}Log Analysis${NC}"
    echo ""

    if [ ! -d "$TEST_SESSION_DIR" ]; then
        echo -e "${RED}No test session logs found. Run tests first.${NC}"
        return
    fi

    echo -e "${BLUE}Success Patterns:${NC}"
    echo ""

    echo "✅ Messages sent:"
    grep -h "✅.*Message.*sent\|📡 Message sent" "$TEST_SESSION_DIR"/*.log 2>/dev/null | wc -l || echo "0"

    echo "✅ Messages received:"
    grep -h "✅.*Message.*received\|📡 Message received" "$TEST_SESSION_DIR"/*.log 2>/dev/null | wc -l || echo "0"

    echo "✅ Queue operations:"
    grep -h "OfflineMessageQueue.*enqueue\|✅.*Queue.*sync" "$TEST_SESSION_DIR"/*.log 2>/dev/null | wc -l || echo "0"

    echo "✅ Routing service calls:"
    grep -h "MeshRoutingService" "$TEST_SESSION_DIR"/*.log 2>/dev/null | wc -l || echo "0"

    echo ""
    echo -e "${BLUE}Error Summary:${NC}"

    ERROR_COUNT=$(grep -h "ERROR\|Exception\|Failed\|Crash" "$TEST_SESSION_DIR"/*.log 2>/dev/null | wc -l || echo "0")
    if [ "$ERROR_COUNT" -eq 0 ]; then
        echo -e "${GREEN}✅ No errors found${NC}"
    else
        echo -e "${RED}❌ Found $ERROR_COUNT error(s):${NC}"
        grep -h "ERROR\|Exception\|Failed\|Crash" "$TEST_SESSION_DIR"/*.log 2>/dev/null | head -5
    fi

    echo ""
    echo -e "${BLUE}Log Files Location:${NC}"
    echo "  $TEST_SESSION_DIR"
    echo ""
}

show_scenario_instructions() {
    SCENARIO=$1

    case $SCENARIO in
        1)
            echo -e "${BLUE}========================================${NC}"
            echo -e "${BLUE}Scenario 1: Direct Message${NC}"
            echo -e "${BLUE}========================================${NC}"
            echo ""
            echo "Steps:"
            echo "1. Device A: Open chat with Device B"
            echo "2. Device A: Send message 'Direct message test #1'"
            echo "3. Device B: Receive message (should appear in <2 seconds)"
            echo "4. Device B: Send reply 'Message received'"
            echo "5. Device A: Receive reply"
            echo ""
            echo "Success Criteria:"
            echo "✅ Messages delivered in <2 seconds"
            echo "✅ No delays or errors"
            echo "✅ No duplicate messages"
            echo ""
            read -p "Press Enter when scenario is complete..."
            ;;
        2)
            echo -e "${BLUE}========================================${NC}"
            echo -e "${BLUE}Scenario 2: Offline Queue${NC}"
            echo -e "${BLUE}========================================${NC}"
            echo ""
            echo "Steps:"
            echo "1. Device A: Open chat with Device B"
            echo "2. Device A: Turn OFF Bluetooth on Device B (or force-kill app)"
            echo "3. Device A: Send 3 messages (should show as pending)"
            echo "4. Wait 30 seconds"
            echo "5. Device B: Turn ON Bluetooth (or restart app)"
            echo "6. Device B: Verify all 3 messages received"
            echo "7. Device A: Verify all 3 messages show as delivered"
            echo ""
            echo "Success Criteria:"
            echo "✅ Messages queue when offline"
            echo "✅ All messages delivered when back online"
            echo "✅ No duplicate messages"
            echo "✅ No message loss"
            echo ""
            read -p "Press Enter when scenario is complete..."
            ;;
        3)
            echo -e "${BLUE}========================================${NC}"
            echo -e "${BLUE}Scenario 3: Routing Service${NC}"
            echo -e "${BLUE}========================================${NC}"
            echo ""
            echo "Steps (3 devices recommended):"
            echo "1. Device A: Send message to Device C (routed via B)"
            echo "2. Observe message passes through Device B"
            echo "3. Device B: Briefly turn OFF Bluetooth"
            echo "4. Wait 5 seconds"
            echo "5. Device B: Turn ON Bluetooth"
            echo "6. Device A: Send another message to Device C"
            echo "7. Observe routing adapts to topology change"
            echo ""
            echo "Success Criteria:"
            echo "✅ MeshRoutingService.determineOptimalRoute() called (in logs)"
            echo "✅ Routing adapts to topology changes"
            echo "✅ Messages still reach destination"
            echo ""
            read -p "Press Enter when scenario is complete..."
            ;;
        4)
            echo -e "${BLUE}========================================${NC}"
            echo -e "${BLUE}Scenario 4: Topology Changes${NC}"
            echo -e "${BLUE}========================================${NC}"
            echo ""
            echo "Steps (3 devices required):"
            echo "1. Arrange devices: A — B — C (line topology)"
            echo "2. Device A: Send message to C (via B)"
            echo "3. Device B: Force-kill app"
            echo "4. Wait 10 seconds"
            echo "5. Device A: Send another message to C (should fail or queue)"
            echo "6. Device B: Restart app"
            echo "7. Wait 15 seconds for reconnection"
            echo "8. Device A: Send final message to C (should work again)"
            echo ""
            echo "Success Criteria:"
            echo "✅ Routing works with B connected"
            echo "✅ Routing detects B offline"
            echo "✅ Routing recovers when B reconnects"
            echo "✅ Topology recovery time <5 seconds"
            echo ""
            read -p "Press Enter when scenario is complete..."
            ;;
    esac
}

# Main script
main() {
    check_environment

    echo -e "${YELLOW}Setup Options:${NC}"
    echo "1. Build and deploy APK to all devices"
    echo "2. Start log collection only"
    echo "3. Skip setup (assume APK already installed)"
    echo ""
    read -p "Select option (1-3): " SETUP_CHOICE

    case $SETUP_CHOICE in
        1)
            build_apk
            deploy_apk
            start_logging
            ;;
        2)
            start_logging
            ;;
        3)
            start_logging
            ;;
    esac

    while true; do
        show_menu
        read -p "Select scenario (1-7): " CHOICE

        case $CHOICE in
            1|2|3|4)
                show_scenario_instructions $CHOICE
                ;;
            5)
                view_logs
                ;;
            6)
                analyze_logs
                ;;
            7)
                echo ""
                stop_logging
                echo -e "${GREEN}Testing complete!${NC}"
                echo -e "${BLUE}Test session logs saved to: $TEST_SESSION_DIR${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid selection${NC}"
                ;;
        esac
    done
}

# Run main script
main
