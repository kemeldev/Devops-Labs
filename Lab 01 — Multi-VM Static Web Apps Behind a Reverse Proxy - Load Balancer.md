# Lab 01 — Multi-VM Static Web Apps Behind a Reverse Proxy / Load Balancer

## Objective

Learn core Linux web-serving and traffic-routing concepts across three distros by:

1. Building and serving a React/Vite app on Fedora with Apache (httpd).
2. Building and serving a different React/Vite app on Ubuntu with nginx.
3. Placing a reverse proxy / load balancer on RHEL in front of both apps, testing two routing variants: round-robin and path-based.

> Non-production, non-sensitive environment — built with real-world good practice anyway (least-privilege firewall rules, correct SELinux contexts, static-build deployment) so the habits carry into [...]

## Long-term direction (not part of this lab)

Containerize these apps, then move them to Kubernetes, then eventually to a cloud environment. This lab is deliberately the simplest possible foundation for [...]

## Environment

| Role | Hostname | IP | OS | Web software |
|---|---:|---:|---|---|
| App 1 — Network topology viz | `fedora.ssa.veeam.local` | `172.31.17.243` | Fedora | Apache (httpd) |
| App 2 — Kubernetes 3D viz | `ubuntuserver1.ssa.veeam.local` | `172.31.17.182` | Ubuntu Server | nginx |
| Reverse proxy / LB | `redhat1.ssa.veeam.local` | `172.31.18.26` | RHEL | nginx or HAProxy (TBD) |
| Control point | Windows workstation | `172.24.209.0/24` | Windows | SSH client only |

Network: `172.31.16.0/22` (mask `255.255.252.0`), gateway `172.31.16.1`, broadcast `172.31.19.255`, ~1022 usable hosts. All three VMs share this subnet. Login user on all Linux hosts: `kemel`.

Scope of "reachable from anywhere": reachable from anywhere on this /22 subnet — not the public internet. Firewall rules will explicitly allow only `172.31.16.0/22` on the HTTP port, on all three host [...]

## Decisions locked in for this lab

- Static builds only. Each app is built with `npm run build` and the resulting `dist/` is served by Apache/nginx as static files. The Vite dev/preview servers are never run persistently or exposed to t[...]
- Node.js version matched per app, not assumed from distro defaults. `k8s-3d-viz` (React 19, Vite 8) needs a fairly current Node. Before installing, check each `package.json` for an `engines` field a[...]
- Firewall scoped to the subnet, not "any source" — using `firewalld` rich rules (Fedora, RHEL) and `ufw` rules (Ubuntu) restricted to `172.31.16.0/22`.
- SELinux/AppArmor handled explicitly, not disabled. Fedora and RHEL enforce SELinux by default (we'll set `httpd_sys_content_t` on served files, and the `httpd_can_network_connect` boolean where t[...]
- TLS deferred. Out of scope for this lab; planned as a follow-up once the basic routing works.
- Traffic-splitting: test both variants (see Step 3 below), since they represent genuinely different real-world use cases and it's cheap to compare them in a lab.

## Architecture (target state)

<img width="610" height="208" alt="image" src="https://github.com/user-attachments/assets/90a175e1-6d7c-410f-bc65-512e5a19ea0d" />


---

## Planned Steps

### Step 1 — Fedora (172.31.17.243), Apache

- Check `package.json` engines / toolchain requirements; install a matching Node.js + npm, plus `httpd`.
- Clone `kemeldev/cloud-network-topology`, `npm install`, `npm run build` → static `dist/`.
- Deploy `dist/` to Apache's document root (or a dedicated vhost).
- Set SELinux context `httpd_sys_content_t` on the deployed files.
- Open port 80 in `firewalld`, scoped to `172.31.16.0/22`.
- Verify the app loads from another host on the subnet.

Example commands used during the lab:

```bash
sudo mkdir -p /var/www/html
sudo cp -r dist/* /var/www/html/
sudo restorecon -Rv /var/www/html
sudo systemctl enable --now httpd
sudo systemctl status httpd --no-pager
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.31.16.0/22" port protocol="tcp" port="80" accept'
sudo firewall-cmd --reload
```

### Step 2 — Ubuntu (172.31.17.182), nginx

- Check Node/toolchain requirements; install matching Node.js + npm, plus `nginx`.
- Clone `kemeldev/k8s-3d-viz`, `npm install`, `npm run build` → static `dist/`.
- Deploy to a dedicated `nginx` server block (not the default site).
- Open port 80 in `ufw`, scoped to `172.31.16.0/22`.
- Verify from another host on the subnet.

Example deployment commands and server block:

```bash
sudo mkdir -p /var/www/k8s-3d-viz
sudo cp -r dist/* /var/www/k8s-3d-viz/
sudo chown -R www-data:www-data /var/www/k8s-3d-viz
```

```nginx
# /etc/nginx/sites-available/k8s-3d-viz
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/k8s-3d-viz;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

Enable the site and reload nginx:

```bash
sudo ln -s /etc/nginx/sites-available/k8s-3d-viz /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
sudo ufw allow from 172.31.16.0/22 to any port 80 proto tcp
```

Notes about ownership and permissions

> `chown` changes ownership of files — `chown -R user:group path` recursively sets who owns everything under that path.

Without the `chown`, copied files become owned by `root` (from `sudo cp`) while `nginx` worker processes run as `www-data`; making `www-data:www-data` the owner ensures nginx can read the files.

### Step 3 — RHEL (172.31.18.26), reverse proxy / load balancer — two variants

#### Variant A: Round-robin load balancing (port 80)

- Single URL (the RHEL proxy's address) load-balances requests across both backends.
- Refreshing the page will alternate between App 1 and App 2 — expected and useful for observing LB behavior.
- Good fit for `nginx` `upstream {}` block with round-robin (default) or HAProxy `balance roundrobin`.

Example `nginx` upstream and server block:

```nginx
upstream app_backends {
    server 172.31.17.243:80;   # Fedora - cloud-network-topology
    server 172.31.17.182:80;   # Ubuntu - k8s-3d-viz
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass http://app_backends;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Set SELinux boolean and start nginx:

```bash
sudo setsebool -P httpd_can_network_connect 1
sudo systemctl enable --now nginx
sudo systemctl status nginx --no-pager
```

#### Variant B: Path-based routing (port 8080)

- Serve each SPA under a path (`/topology/` and `/k8s/`). Both SPAs need a non-root base path when building with Vite (`--base=/topology/`, `--base=/k8s/`).
- Deploy the rebuilt `dist` directories into separate locations and proxy accordingly.

Example `nginx` server block on RHEL (port 8080):

```nginx
# /etc/nginx/conf.d/path.conf
server {
    listen 8080;
    listen [::]:8080;
    server_name _;

    location = / {
        add_header Content-Type text/plain;
        return 200 "Path-based routing demo.\nTry /topology/ or /k8s/\n";
    }

    location /topology/ {
        proxy_pass http://172.31.17.243:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /k8s/ {
        proxy_pass http://172.31.17.182:80;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Open firewall port 8080 and verify each path loads the correct app.

Example quick checks:

```bash
curl http://172.31.18.26:8080/
curl -I http://172.31.18.26:8080/topology/
curl -I http://172.31.18.26:8080/k8s/
```

### Step 4 — Implementation of TLS (optional / lab extension)

Plan: add HTTPS listeners alongside existing HTTP ones: 443 for round-robin and 8443 for path-based.

1) Generate a self-signed certificate:

```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/lab.key \
  -out /etc/nginx/ssl/lab.crt \
  -subj "/CN=172.31.18.26" \
  -addext "subjectAltName=IP:172.31.18.26"
sudo chmod 600 /etc/nginx/ssl/lab.key
sudo restorecon -Rv /etc/nginx/ssl
```

> The `subjectAltName` matters — modern clients ignore CN-only certificates and require a SAN matching the address you connect to.

2) HTTPS server block for round-robin (443):

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name _;
    ssl_certificate     /etc/nginx/ssl/lab.crt;
    ssl_certificate_key /etc/nginx/ssl/lab.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        proxy_pass http://app_backends;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

3) HTTPS server block for path-based (8443):

```nginx
server {
    listen 8443 ssl;
    listen [::]:8443 ssl;
    server_name _;
    ssl_certificate     /etc/nginx/ssl/lab.crt;
    ssl_certificate_key /etc/nginx/ssl/lab.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location = / {
        add_header Content-Type text/plain;
        return 200 "Path-based routing demo (TLS).\nTry /topology/ or /k8s/\n";
    }

    location /topology/ {
        proxy_pass http://172.31.17.243:80;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /k8s/ {
        proxy_pass http://172.31.17.182:80;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

4) Test and reload:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

5) Open firewall ports for `443` and `8443` (example `firewall-cmd` commands):

```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.31.16.0/22" port protocol="tcp" port="443" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.24.209.0/24" port protocol="tcp" port="443" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.31.16.0/22" port protocol="tcp" port="8443" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.24.209.0/24" port protocol="tcp" port="8443" accept'
sudo firewall-cmd --reload
```

6) Verify with `curl -k -I` against the HTTPS endpoints.

---

## Documented / Troubleshooting: Apache Reachable Locally But Not From Other Hosts

### Issue

After deploying a static build to Apache's document root (`/var/www/html`) and starting `httpd`, the site was reachable via `curl` from the server itself, but any other machine on the network (same subnet or [...]) could not connect:

```
curl: (7) Failed to connect to 172.31.17.243 port 80 after 0 ms: Couldn't connect to server
```

This indicates a TCP-level blockage: either Apache is listening only on `localhost`, or a firewall is blocking the port.

### Diagnostic steps and findings

1. Confirm Apache is listening on all interfaces:

```bash
sudo ss -tlnp | grep :80
```

Result showed `*:80`, so Apache was listening on all interfaces.

2. Check active firewalld zones:

```bash
sudo firewall-cmd --get-active-zones
```

This returned nothing — the interface `ens192` wasn't bound to a zone, so rules in the `public` zone weren't being applied to that interface.

3. Confirm firewalld rules were configured:

```bash
sudo firewall-cmd --list-all --zone=public
```

The rich rules allowing TCP port 80 from the two expected subnets were present and correctly formatted.

4. Confirm source IP was within the allowed range:

```bash
ip addr show
```

Verified `172.31.17.243/22` fell inside the `172.31.16.0/22` range.

5. Isolate firewalld by temporarily stopping it:

```bash
sudo systemctl stop firewalld
```

Connection succeeded from other hosts while firewalld was stopped, confirming firewalld (specifically the missing zone binding) was blocking traffic. Restart firewalld after this test.

### Root cause

The `ens192` interface was never explicitly assigned to a firewalld zone. Without an active zone binding, firewalld didn't apply the `public` zone's rules to traffic on that interface.

### Fix

Bind the interface to the `public` zone:

```bash
sudo firewall-cmd --zone=public --change-interface=ens192 --permanent
sudo firewall-cmd --reload
sudo firewall-cmd --get-active-zones
```

Expected output:

```
public
  interfaces: ens192
```

Alternative (NetworkManager-managed connections): set the zone on the connection profile:

```bash
sudo nmcli connection modify ens192 connection.zone public
sudo nmcli connection up ens192
```

Note: changing the zone on an active interface can briefly interrupt existing connections (including SSH).

### Understanding firewalld zones (summary)

- A zone is a set of trust rules applied per network interface.
- Rules only take effect on interfaces assigned to that zone.
- Use `firewall-cmd --get-active-zones` to confirm which interfaces are bound to which zones.
- Zone assignment can happen in firewalld or via NetworkManager's connection profile; keep them in sync.
- Practical takeaway: when a firewall rule "should" be working but isn't, check `--get-active-zones` first.

