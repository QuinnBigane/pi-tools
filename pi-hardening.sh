#!/usr/bin/env bash
set -euo pipefail

###############################################
#  PI HARDENING SCRIPT (INTERACTIVE WIFI)     #
# --------------------------------------------#
#  This script:                               #
#     • Prompts for SSID & password           #
#     • Creates /boot/wpa_supplicant.conf     #
#     • Forces Pi to read WiFi from /boot     #
#     • Hardens ext4 journaling               #
#     • Enables hardware watchdog             #
#     • Enables watchdog service              #
#     • Enables SSH                           #
#                                             #
#  WHEN TO RUN:                               #
#     • After flashing OS                     #
#     • After major OS upgrade                #
#     • (Not needed every boot)               #
###############################################

echo "=========================================="
echo " Raspberry Pi Hardening Script"
echo "=========================================="
echo ""
echo "This script will:"
echo "  ✓ Set WiFi credentials"
echo "  ✓ Move WiFi config to /boot"
echo "  ✓ Harden filesystem against corruption"
echo "  ✓ Enable hardware + software watchdog"
echo "  ✓ Enable SSH"
echo ""
read -rp "Press ENTER to continue..."

#############################################
# Prompt for WiFi credentials
#############################################
echo ""
echo "------------------------------------------"
echo "Enter WiFi Configuration"
echo "------------------------------------------"

read -rp "WiFi SSID: " WIFI_SSID

# Silent password prompt
read -rsp "WiFi Password: " WIFI_PASS
echo ""

# Sanity check
if [[ -z "$WIFI_SSID" || -z "$WIFI_PASS" ]]; then
    echo "[!] SSID or Password cannot be empty."
    exit 1
fi

#############################################
# Detect root filesystem
#############################################
echo "[*] Detecting root filesystem device..."
ROOTDEV=$(findmnt -no SOURCE /)
FSTYPE=$(lsblk -no FSTYPE "$ROOTDEV")
echo "    Root device: $ROOTDEV ($FSTYPE)"

#############################################
# Harden ext4 journal
#############################################
if [[ "$FSTYPE" == "ext4" ]]; then
    echo "[*] Enabling full ext4 journaling for safer writes..."
    sudo tune2fs -o journal_data "$ROOTDEV" || echo "    (tune2fs skipped: not supported)"

    echo "[*] Updating fstab to auto-recover on corruption..."
    sudo sed -i 's|\(\s/\s\+ext4\s\+defaults\)|\1,errors=remount-ro|' /etc/fstab || true
else
    echo "[!] Root FS is not ext4; skipping ext4 tuning."
fi

#############################################
# Force wpa_supplicant to use /boot
#############################################
echo "[*] Updating wpa_supplicant to read config from /boot..."
WPA_SERVICE=/lib/systemd/system/wpa_supplicant.service

if ! grep -q "/boot/wpa_supplicant.conf" "$WPA_SERVICE"; then
    sudo sed -i 's|/etc/wpa_supplicant/wpa_supplicant.conf|/boot/wpa_supplicant.conf|' "$WPA_SERVICE"
else
    echo "    Already configured."
fi

#############################################
# Create /boot/wpa_supplicant.conf
#############################################
echo "[*] Writing WiFi config to /boot/wpa_supplicant.conf..."

sudo tee /boot/wpa_supplicant.conf >/dev/null <<EOF
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1

network={
    ssid="$WIFI_SSID"
    psk="$WIFI_PASS"
    scan_ssid=1
}
EOF

echo "    WiFi config written."

#############################################
# Enable SSH
#############################################
echo "[*] Enabling SSH on boot..."
sudo touch /boot/ssh

#############################################
# Enable hardware watchdog
#############################################
echo "[*] Enabling hardware watchdog in /boot/config.txt..."

CONF=/boot/config.txt
if grep -q "^dtparam=watchdog=on" "$CONF"; then
    echo "    Hardware watchdog already enabled."
else
    echo "dtparam=watchdog=on" | sudo tee -a "$CONF" >/dev/null
    echo "    Added dtparam=watchdog=on to config.txt."
fi

echo "[*] Loading bcm2835_wdt watchdog module for this boot..."
if sudo modprobe bcm2835_wdt 2>/dev/null; then
    echo "    bcm2835_wdt module loaded."
else
    echo "    Warning: bcm2835_wdt module could not load (may require reboot)."
fi

echo "[*] Checking for /dev/watchdog..."
if ls /dev/watchdog* >/dev/null 2>&1; then
    ls -l /dev/watchdog*
else
    echo "    Warning: /dev/watchdog not present yet. A reboot may be required."
fi

#############################################
# Install & enable watchdog service
#############################################
echo "[*] Installing watchdog daemon..."
sudo apt-get update -y
sudo apt-get install -y watchdog

echo "[*] Enabling watchdog service..."
sudo systemctl enable watchdog

echo "[*] Starting watchdog service..."
sudo systemctl restart watchdog || echo "    (service will work after reboot if hardware was just enabled)"

#############################################
# Finished
#############################################
echo ""
echo "=========================================="
echo " Hardening complete!"
echo "=========================================="
echo "A reboot is recommended."
echo ""
