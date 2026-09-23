# Devices for the multi-device splits lanes, sourced by them.
#
#   SPLITS_PLATFORM=ios       (default) the simulators splits-e2e, -b, -c, -d,
#                             or the udids in SPLITS_UDID_A .. SPLITS_UDID_D
#   SPLITS_PLATFORM=android   emulators already attached, then the AVDs in
#                             SPLITS_AVDS booted headless, one per device.
#                             An AVD runs once at a time, so N devices need N
#                             distinct AVDs.
#
# Every device starts from nothing. On iOS a wallet survives a reinstall: the
# keychain is not part of the app bundle, so a device that ran before boots
# straight to /unlock and the create-wallet flow never sees its first screen.
# Terminating, uninstalling and resetting the keychain is what clears it. On
# Android the keystore entries belong to the app's uid and go with the
# uninstall.
#
# The app reaches the relay, the coordinator and regtest lightwalletd at
# 127.0.0.1. A simulator shares the host's loopback; an emulator does not, so
# each of those ports is forwarded with `adb reverse`.

APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.keplr.vizor}"
splits_platform="${SPLITS_PLATFORM:-ios}"
android_sdk="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
adb="$android_sdk/platform-tools/adb"
declare -a SPLITS_DEVICES=()
declare -a splits_started_emulators=()
declare -a splits_emulator_pids=()

named_simulator() {
  xcrun simctl list devices available |
    sed -n "s/.*$1 (\([0-9A-F-]\{36\}\)).*/\1/p" | head -1
}

attached_emulators() {
  "$adb" devices | awk '/^emulator-[0-9]+\tdevice$/ {print $1}'
}

# Fills SPLITS_DEVICES with $1 device ids, booting emulators where needed.
splits_select_devices() {
  local count="$1" i
  case "$splits_platform" in
    ios)
      local -a names=(splits-e2e splits-e2e-b splits-e2e-c splits-e2e-d)
      local -a given=("${SPLITS_UDID_A:-}" "${SPLITS_UDID_B:-}" \
        "${SPLITS_UDID_C:-}" "${SPLITS_UDID_D:-}")
      for ((i = 0; i < count; i++)); do
        local udid="${given[$i]:-$(named_simulator "${names[$i]}")}"
        if [ -z "$udid" ]; then
          echo "need $count simulators: ${names[*]:0:$count}" >&2
          echo "  xcrun simctl create splits-e2e <devicetype> <runtime>" >&2
          return 2
        fi
        SPLITS_DEVICES+=("$udid")
      done
      ;;
    android)
      local serial
      while read -r serial; do
        [ -n "$serial" ] && [ "${#SPLITS_DEVICES[@]}" -lt "$count" ] &&
          SPLITS_DEVICES+=("$serial")
      done < <(attached_emulators)
      local -a avds=(${SPLITS_AVDS:-Pixel_10_API_36 vizor_api36 Pixel_6_API_33_NoPlay Pixel_6_API_31})
      # An AVD already running is attached above, under its own serial, and
      # cannot be started a second time.
      local running=" " port=5580 avd
      for serial in $(attached_emulators); do
        # A serial that is shutting down answers nothing; that is not fatal.
        running+="$("$adb" -s "$serial" emu avd name 2>/dev/null | head -1 | tr -d '\r' || true) "
      done
      for avd in "${avds[@]}"; do
        [ "${#SPLITS_DEVICES[@]}" -ge "$count" ] && break
        case "$running" in *" $avd "*) continue ;; esac
        while "$adb" devices | grep -q "^emulator-$port"; do port=$((port + 2)); done
        "$android_sdk/emulator/emulator" -avd "$avd" -port "$port" \
          -no-window -no-audio -no-snapshot-save \
          >"${TMPDIR:-/tmp}/splits-emulator-$port.log" 2>&1 &
        splits_emulator_pids+=("emulator-$port:$!")
        splits_started_emulators+=("emulator-$port")
        SPLITS_DEVICES+=("emulator-$port")
        port=$((port + 2))
      done
      if [ "${#SPLITS_DEVICES[@]}" -lt "$count" ]; then
        echo "need $count emulators; set SPLITS_AVDS to $count distinct AVDs" >&2
        return 2
      fi
      for serial in "${SPLITS_DEVICES[@]}"; do
        for _ in $(seq 240); do
          [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ] && break
          local pid="" entry
          for entry in "${splits_emulator_pids[@]:-}"; do
            [ "${entry%%:*}" = "$serial" ] && pid="${entry#*:}"
          done
          if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            echo "emulator $serial exited while booting:" >&2
            tail -20 "${TMPDIR:-/tmp}/splits-emulator-${serial#emulator-}.log" >&2
            return 1
          fi
          sleep 1
        done
        if [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != 1 ]; then
          echo "emulator $serial did not finish booting" >&2
          return 1
        fi
      done
      ;;
    *)
      echo "SPLITS_PLATFORM is ios or android, not $splits_platform" >&2
      return 2
      ;;
  esac
}

# Boots and wipes device $1, and forwards the loopback ports that follow it.
splits_prepare_device() {
  local id="$1" port
  shift
  case "$splits_platform" in
    ios)
      xcrun simctl boot "$id" 2>/dev/null || true
      xcrun simctl terminate "$id" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
      xcrun simctl uninstall "$id" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
      xcrun simctl keychain "$id" reset >/dev/null 2>&1 || true
      ;;
    android)
      "$adb" -s "$id" uninstall "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
      for port in "$@"; do
        "$adb" -s "$id" reverse "tcp:$port" "tcp:$port" >/dev/null
      done
      ;;
  esac
}

# Shuts down the emulators splits_select_devices started, and no others.
#
# `emu kill` returns before the emulator exits, and an AVD stays locked until
# it has. The next lane starting the same AVD would otherwise die at launch,
# so this waits for each serial to leave `adb devices`.
splits_release_devices() {
  local serial
  for serial in "${splits_started_emulators[@]:-}"; do
    [ -n "$serial" ] && "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  done
  for serial in "${splits_started_emulators[@]:-}"; do
    [ -n "$serial" ] || continue
    for _ in $(seq 60); do
      "$adb" devices | grep -q "^$serial[[:space:]]" || break
      sleep 1
    done
  done
  return 0
}
