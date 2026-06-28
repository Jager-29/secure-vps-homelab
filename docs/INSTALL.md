# Install guide

Every command assumes a non-root user with sudo. Replace all placeholders
before running anything. Keep a second SSH session open whenever you change SSH
or firewall rules, and know where your provider's console (KVM) is in case you
lock yourself out.

## 1. SSH hardening and firewall

Generate a key on your client if you do not have one, then copy the public key
to the server. On the server, edit `/etc/ssh/sshd_config`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

Test the config before restarting:

```bash
sudo sshd -t
sudo systemctl restart ssh
```

Open a new SSH session on the new port before closing the current one.

Firewall with UFW. Deny inbound by default, allow only what you need:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp
sudo ufw enable
```

Ports 80 and 443 are added later, when the reverse proxy is in place.

## 2. DNS

Point your domain at the VPS. Create two A records:

```
@   A   YOUR_VPS_PUBLIC_IP
*   A   YOUR_VPS_PUBLIC_IP
```

The wildcard record means every subdomain resolves to the VPS, so new services
need no DNS change. Remove any default parking records the registrar created,
otherwise you get inconsistent resolution. Verify propagation:

```bash
dig @8.8.8.8 YOUR_DOMAIN +short
dig @8.8.8.8 anything.YOUR_DOMAIN +short
```

Both must return YOUR_VPS_PUBLIC_IP.

## 3. Mesh VPN

Install Tailscale and bring it up:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

In the Tailscale admin console, enable MagicDNS and HTTPS Certificates. Rename
the machine to something readable. Note the machine's tailnet name, it is used
for admin access later as `YOUR_MACHINE.YOUR_TAILNET_NAME.ts.net`.

Allow SSH over the VPN interface so you keep a private path in:

```bash
sudo ufw allow in on tailscale0 to any port 2222 proto tcp
```

## 4. Docker and container manager

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

Log out and back in for the group to take effect, then confirm:

```bash
docker run --rm hello-world
```

Create the shared network used by proxied services:

```bash
docker network create proxy
```

Deploy the container manager bound to the VPN interface only:

```bash
docker volume create portainer_data
docker run -d \
  --name portainer \
  --restart=always \
  -p YOUR_TAILSCALE_IP:9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
docker network connect proxy portainer
```

Create the admin account quickly. The initial setup window closes a few minutes
after start. If it closes, restart the container and read the new token from the
logs.

## 5. Reverse proxy and wildcard certificate

Deploy the proxy with the compose file in `compose/npm.yml`. It publishes 80 and
443 publicly and the admin UI (81) on the VPN interface only. After it is up,
open the public web ports:

```bash
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

Issue the wildcard certificate from the proxy UI using a DNS-01 challenge. For
OVH, create API credentials with GET, PUT, POST and DELETE rights on
`/domain/zone/*`, then provide them in the certificate dialog. Request both
`YOUR_DOMAIN` and `*.YOUR_DOMAIN`. Set the propagation wait to 120 seconds.

The certificate is issued by proving control of the DNS zone, so nothing extra
is exposed on the server. The wildcard covers every subdomain at once.

## 6. IPS

The IPS agent reads the proxy logs and bans hostile IPs. The firewall bouncer
that enforces bans is not available as a Docker image and must be installed
natively.

Create the acquisition config so the agent knows which logs to read. See
`configs/acquis.yaml`. Deploy the agent with `compose/crowdsec.yml`, then check
it loaded its collections:

```bash
docker exec crowdsec cscli collections list
```

Install the native firewall bouncer:

```bash
curl -s https://install.crowdsec.net | sudo sh
sudo apt install crowdsec-firewall-bouncer-nftables -y
```

Generate a key from the agent and put it in the bouncer config at
`/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml`, pointing the bouncer at
the agent's local API:

```bash
docker exec crowdsec cscli bouncers add firewall-bouncer
```

```
api_url: http://127.0.0.1:8080/
api_key: CHANGE_ME
```

Restart and verify:

```bash
sudo systemctl restart crowdsec-firewall-bouncer
docker exec crowdsec cscli bouncers list
```

Enroll the engine in the console if you want the central dashboard. Once
enrolled, the community blocklists pull in tens of thousands of known-bad IPs
that the bouncer blocks immediately.

## 7. SIEM

Set the kernel map count the indexer needs, permanently:

```bash
sudo sysctl -w vm.max_map_count=262144
echo "vm.max_map_count=262144" | sudo tee -a /etc/sysctl.conf
```

Clone the official deployment at a pinned version and generate certificates:

```bash
git clone https://github.com/wazuh/wazuh-docker.git -b vX.Y.Z
cd wazuh-docker/single-node/
docker compose -f generate-indexer-certs.yml run --rm generator
```

Before starting, edit the compose file. The dashboard defaults to port 443,
which collides with the reverse proxy, so bind it to the VPN interface on a free
port. Also bind the indexer API to localhost so it is never public:

```
wazuh.dashboard ports:  YOUR_TAILSCALE_IP:8443:5601
wazuh.indexer   ports:  127.0.0.1:9200:9200
```

Start the stack and watch memory while the indexer comes up:

```bash
docker compose up -d
watch -n 3 free -h
```

The indexer takes about a minute and logs connection errors until it is ready.
Add swap if your VPS has none, as a safety margin.

### Agents

On the VPS host, install the agent for the host architecture, pointing it at the
manager on localhost since both are on the same machine:

```bash
sudo WAZUH_MANAGER='127.0.0.1' WAZUH_AGENT_NAME='vps-host' dpkg -i ./wazuh-agent_X.Y.Z_amd64.deb
sudo systemctl enable --now wazuh-agent
```

To monitor a second machine over the VPN, open the agent ports on the VPN
interface only:

```bash
sudo ufw allow in on tailscale0 to any port 1514 proto tcp
sudo ufw allow in on tailscale0 to any port 1515 proto tcp
```

Then install the agent on the remote machine with the correct architecture
package, pointing it at the VPS tailnet IP:

```bash
sudo WAZUH_MANAGER='YOUR_TAILSCALE_IP' WAZUH_AGENT_NAME='remote-host' dpkg -i ./wazuh-agent_X.Y.Z_arm64.deb
sudo systemctl enable --now wazuh-agent
```

Match the package architecture to the machine. A home device may be arm64 while
the VPS is amd64.

### Changing the SIEM admin password

The admin user is reserved and cannot be changed from the dashboard. Use an
alphanumeric password with no special characters, generate its hash, place it in
the indexer's internal users file, apply with the security admin tool, then set
the same value in the compose file for the manager and the dashboard so all
three components agree. Restart the manager and dashboard and confirm with
`filebeat test output`. The reasons this is fragile are in
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## 8. Admin access over the VPN with valid TLS

Rebind each admin service to localhost, then expose it through the VPN with a
valid certificate. For the container manager:

```bash
docker rm -f portainer
docker run -d \
  --name portainer \
  --restart=always \
  -p 127.0.0.1:9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
docker network connect proxy portainer

sudo tailscale serve --bg --https=9443 https+insecure://localhost:9443
```

Use `http://` instead of `https+insecure://` for services that speak plain HTTP
internally, such as the proxy admin UI. Confirm the mapping:

```bash
sudo tailscale serve status
```

Admin URLs become `https://YOUR_MACHINE.YOUR_TAILNET_NAME.ts.net:PORT` with a
valid certificate and no public exposure.

## 9. Kernel hardening

Apply the sysctl settings in `configs/99-cis-hardening.conf`:

```bash
sudo cp configs/99-cis-hardening.conf /etc/sysctl.d/
sudo sysctl --system
```

Do not disable IP forwarding on a host running Docker or VPN subnet routing, it
breaks container and VPN networking. Those two lines are left commented in the
file for that reason. After applying, confirm containers, the VPN and SSH still
work.

## 10. Backups

Install the backup script and schedule it:

```bash
mkdir -p ~/scripts ~/backups
cp scripts/backup-vps.sh ~/scripts/
chmod +x ~/scripts/backup-vps.sh
crontab -e
```

Add a daily job:

```
0 3 * * * /home/YOUR_USER/scripts/backup-vps.sh >> /home/YOUR_USER/backups/backup.log 2>&1
```

The script auto-discovers named Docker volumes and also archives host-side
config that lives outside volumes. It excludes large transient volumes so
backups stay small. Storing backups on the same disk does not protect against
loss of the VPS. Off-site sync is on the roadmap.
