#!/usr/bin/env bash
set -e

echo "=== Cloudflare Tunnel Setup Script ==="
echo "This will:"
echo "  - Install dependencies and cloudflared"
echo "  - Log you into Cloudflare (browser step)"
echo "  - Create a named tunnel"
echo "  - Create /etc/cloudflared/config.yml"
echo "  - Install and start the cloudflared service"
echo

# ----- INPUTS -----
read -rp "Enter a name for this tunnel (e.g. pimonitor-01 or pimonitor-02): " TUNNEL_NAME
read -rp "Enter the public hostname you want (e.g. pimonitor-01.quinnbigane.com): " PUBLIC_HOSTNAME
read -rp "Enter the local port your app runs on (e.g. 8000): " LOCAL_PORT

if [[ -z "$TUNNEL_NAME" || -z "$PUBLIC_HOSTNAME" || -z "$LOCAL_PORT" ]]; then
  echo "Error: All fields are required."
  exit 1
fi

echo
echo "Tunnel name:      $TUNNEL_NAME"
echo "Public hostname:  $PUBLIC_HOSTNAME"
echo "Local service:    http://localhost:${LOCAL_PORT}"
echo

read -rp "Press ENTER to continue, or Ctrl+C to cancel..."

# ----- INSTALL DEPENDENCIES & CLOUDFLARED -----
echo
echo "=== Installing dependencies and cloudflared ==="
sudo apt-get update
sudo apt-get install -y apt-transport-https lsb-release gnupg curl

if ! [ -f /usr/share/keyrings/cloudflare-main.gpg ]; then
  echo "Adding Cloudflare GPG key..."
  curl https://pkg.cloudflare.com/cloudflare-main.gpg \
    | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
fi

if ! [ -f /etc/apt/sources.list.d/cloudflared.list ]; then
  echo "Adding Cloudflare APT repo..."
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
fi

sudo apt-get update
sudo apt-get install -y cloudflared

echo
echo "cloudflared version:"
cloudflared --version || { echo "cloudflared not installed correctly"; exit 1; }

# ----- CLOUDFLARE LOGIN -----
echo
echo "=== Logging into Cloudflare ==="
echo "This will print a URL. Open it in your browser and log in to your Cloudflare account."
echo "When done, come back here."
echo
read -rp "Press ENTER to run 'cloudflared tunnel login'..."

cloudflared tunnel login

# ----- CREATE TUNNEL -----
echo
echo "=== Creating tunnel '${TUNNEL_NAME}' ==="
TUNNEL_OUTPUT=$(cloudflared tunnel create "${TUNNEL_NAME}" 2>&1)
echo "$TUNNEL_OUTPUT"

# Extract tunnel ID from output
TUNNEL_ID=$(echo "$TUNNEL_OUTPUT" | sed -n 's/.*Created tunnel .* with id \([0-9a-f-]\+\).*/\1/p')

if [[ -z "$TUNNEL_ID" ]]; then
  echo "Error: Could not parse tunnel ID from output."
  echo "Tunnel output was:"
  echo "$TUNNEL_OUTPUT"
  exit 1
fi

echo
echo "Detected tunnel ID: $TUNNEL_ID"

CREDENTIALS_FILE="$HOME/.cloudflared/${TUNNEL_ID}.json"
if ! [ -f "$CREDENTIALS_FILE" ]; then
  echo "Warning: Credentials file not found at $CREDENTIALS_FILE"
  echo "Check ~/.cloudflared/ to see where the JSON file was written, then update /etc/cloudflared/config.yml manually."
fi

# ----- CREATE CONFIG.YML -----
echo
echo "=== Writing /etc/cloudflared/config.yml ==="
sudo mkdir -p /etc/cloudflared

CONFIG_CONTENT="tunnel: ${TUNNEL_ID}
credentials-file: ${CREDENTIALS_FILE}

ingress:
  - hostname: ${PUBLIC_HOSTNAME}
    service: http://localhost:${LOCAL_PORT}
  - service: http_status:404
"

echo "$CONFIG_CONTENT" | sudo tee /etc/cloudflared/config.yml >/dev/null

echo
echo "Generated /etc/cloudflared/config.yml:"
echo "--------------------------------------"
echo "$CONFIG_CONTENT"
echo "--------------------------------------"

# ----- INSTALL & START SERVICE -----
echo
echo "=== Installing cloudflared as a systemd service ==="

sudo cloudflared service install || echo "Note: 'cloudflared service install' may already be configured; continuing."

sudo systemctl enable cloudflared
sudo systemctl restart cloudflared

echo
echo "cloudflared service status:"
systemctl --no-pager status cloudflared | sed -n '1,10p'

echo
echo "✅ Done!"
echo "If everything is green above, your tunnel should now be active."
echo "Cloudflare will usually auto-create the DNS record for ${PUBLIC_HOSTNAME} pointing at this tunnel."
echo
echo "You can now protect ${PUBLIC_HOSTNAME} via Cloudflare Zero Trust Access (Authentication rules)."
