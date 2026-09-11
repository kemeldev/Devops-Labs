# Lab 01 — Multi-VM Static Web Apps Behind a Reverse Proxy / Load Balancer

## Objective

Learn core Linux web-serving and traffic-routing concepts across three distros by:

1. Building and serving a React/Vite app on Fedora with Apache (httpd).
2. Building and serving a different React/Vite app on Ubuntu with nginx.
3. Placing a reverse proxy / load balancer on RHEL in front of both apps, testing two routing variants: round-robin and path-based.

Non-production, non-sensitive environment — built with real-world good practice anyway (least-privilege firewall rules, correct SELinux contexts, static-build deployment) so the habits carry into future labs.

**Long-term direction (not part of this lab):** containerize these apps, then move them to Kubernetes, then eventually to a cloud environment. This lab is deliberately the simplest possible foundation for that path — bare-metal VMs, no containers, no orchestration yet.

---

## Environment

| Role                         | Hostname                        | IP                | OS            | Web software           |
| ---------------------------- | ------------------------------- | ----------------- | ------------- | ---------------------- |
| App 1 — Network topology viz | `fedora.ssa.veeam.local`        | `172.31.17.243`   | Fedora        | Apache (httpd)         |
| App 2 — Kubernetes 3D viz    | `ubuntuserver1.ssa.veeam.local` | `172.31.17.182`   | Ubuntu Server | nginx                  |
| Reverse proxy / LB           | `redhat1.ssa.veeam.local`       | `172.31.18.26`    | RHEL          | nginx or HAProxy (TBD) |
| Control point                | Windows workstation             | `172.24.209.0/24` | Windows       | SSH client only        |

**Network:** `172.31.16.0/22` (mask `255.255.252.0`), gateway `172.31.16.1`, broadcast `172.31.19.255`, ~1022 usable hosts.

All three VMs share this subnet.

Login user on all Linux hosts: `kemel`.

Scope of "reachable from anywhere": reachable from anywhere on this `/22` subnet — not the public internet.

Firewall rules will explicitly allow only `172.31.16.0/22` on the HTTP port, on all three hosts, rather than opening to `0.0.0.0/0`.

---

## Decisions locked in for this lab

* **Static builds only.** Each app is built with `npm run build` and the resulting `dist/` is served by Apache/nginx as static files. The Vite dev/preview servers are never run persistently or exposed to the network — they're dev-only tools.
* **Node.js version matched per app, not assumed from distro defaults.** k8s-3d-viz (React 19, Vite 8) needs a fairly current Node. Before installing, check each `package.json` for an `engines` field and confirm the distro-default nodejs package satisfies it; if not, use NodeSource's repo (Fedora/Ubuntu) or an AppStream module (RHEL) to get a current LTS Node instead of forcing the default package.
* **Firewall scoped to the subnet, not "any source"** — using firewalld rich rules (Fedora, RHEL) and ufw rules (Ubuntu) restricted to `172.31.16.0/22`.
* **SELinux/AppArmor handled explicitly, not disabled.** Fedora and RHEL enforce SELinux by default (we'll set `httpd_sys_content_t` on served files, and the `httpd_can_network_connect` boolean where the RHEL proxy needs to reach the two backends). Ubuntu uses AppArmor instead — different tooling, same principle, and a deliberate point of comparison across the three hosts.
* **TLS deferred.** Out of scope for this lab; planned as a follow-up once the basic routing works.
* **Traffic-splitting:** test both variants (see Step 3 below), since they represent genuinely different real-world use cases and it's cheap to compare them in a lab.

---

## Architecture (target state)

---

## Planned Steps

### Step 1 — Fedora (`172.31.17.243`), Apache

* Check `package.json` engines / toolchain requirements; install a matching Node.js + npm, plus httpd.
* Clone `kemeldev/cloud-network-topology`, `npm install`, `npm run build` → static `dist/`.
* Deploy `dist/` to Apache's document root (or a dedicated vhost).
* Set SELinux context `httpd_sys_content_t` on the deployed files.
* Open port 80 in firewalld, scoped to `172.31.16.0/22`.
* Verify the app loads from another host on the subnet.

### Step 2 — Ubuntu (`172.31.17.182`), nginx

* Check Node/toolchain requirements; install matching Node.js + npm, plus nginx.
* Clone `kemeldev/k8s-3d-viz`, `npm install`, `npm run build` → static `dist/`.
* Deploy to a dedicated nginx server block (not the default site).
* Open port 80 in ufw, scoped to `172.31.16.0/22`.
* Verify from another host on the subnet.

### Step 3 — RHEL (`172.31.18.26`), reverse proxy / load balancer — two variants

#### Variant A: Round-robin load balancing

* Single URL (the RHEL proxy's address) load-balances requests across both backends.
* Refreshing the page will alternate between App 1 and App 2 — expected and useful for observing LB behavior, not a bug.
* Good fit for nginx `upstream {}` block with round-robin (default) or HAProxy `balance roundrobin`.

#### Variant B: Path-based routing

* Same proxy, but `/topology` (or `/`) routes to the Fedora backend and `/k8s` routes to the Ubuntu backend, based on request path.
* More representative of real-world reverse-proxy use (one entry point, multiple distinct services).
* Good fit for nginx location blocks or HAProxy ACL-based backend selection.
* Both variants: configure SELinux boolean `httpd_can_network_connect` (if using nginx built against the httpd SELinux policy) or the HAProxy equivalent, and open port 80 in firewalld scoped to `172.31.16.0/22`.
* Verify both variants from a client hitting only the proxy's IP; can be built as two separate config files/vhosts on the same RHEL host and switched between, so both are kept for reference.

---

## Natural next-lab ideas (for later, not now)

* Add TLS termination at the reverse proxy.
* Add a health-check/failover scenario (stop one backend, watch the proxy react) on top of the path-based variant.
* Add HAProxy's stats page or nginx's stub_status for observability.
* Containerize each app (Podman/Docker) — first milestone toward the longer-term goal.
* Move to Kubernetes — once containerized, replace the manual reverse proxy with an Ingress controller.
* Move to a cloud environment — final stage of the roadmap, once the Kubernetes version is solid.
* Automate the bare-metal version with Ansible, as a parallel/alternate path to containerization.

---

# LAB EXECUTION

## Step 1 — Fedora (`172.31.17.243`), Apache — ✅ Complete

* Installed git and httpd via dnf. Node.js was installed separately using a different method than originally drafted.
* Cloned `kemeldev/cloud-network-topology` into `/home/kemel/`.
* Ran `npm install` and `npm run build`, producing a static `dist/`.
* Deployed the contents of `dist/` to Apache's document root (`/var/www/html/`).

```bash
sudo mkdir -p /var/www/html 
sudo cp -r dist/* /var/www/html/
```

* Applied restorecon to ensure the deployed files carry the correct SELinux type (`httpd_sys_content_t`).

```bash
sudo restorecon -Rv /var/www/html
```

* Enabled and started httpd.

```bash
sudo systemctl enable --now httpd 
sudo systemctl status httpd --no-pager
```

* Opened TCP/80 in firewalld via rich rules scoped to two sources: the VM subnet (`172.31.16.0/22`) and the workstation's network (`172.24.209.0/24`) — needed because the workstation sits on a separate subnet from the VMs.

```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.31.16.0/22" port protocol="tcp" port="80" accept' 
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.24.209.0/24" port protocol="tcp" port="80" accept' 
sudo firewall-cmd --reload 
sudo firewall-cmd --list-rich-rules
```

* Verified: reachable with 200 OK from the Windows workstation and from other Linux hosts on the VM subnet.

---

## Step 2 — Ubuntu (`172.31.17.182`), nginx — ✅ Complete

* Installed git and nginx via apt. Node.js was installed separately using a different method than originally drafted.
* Cloned `kemeldev/k8s-3d-viz` into `/home/kemel/`.
* Ran `npm install` and `npm run build`, producing a static `dist/`.
* Deployed the contents of `dist/` to a dedicated directory (`/var/www/k8s-3d-viz/`), owned by `www-data`.

```bash
sudo mkdir -p /var/www/k8s-3d-viz 
sudo cp -r dist/* /var/www/k8s-3d-viz/ 
sudo chown -R www-data:www-data /var/www/k8s-3d-viz
```

### Explanation

> chown changes ownership of files — chown -R user:group path recursively sets who owns everything under that path.
>
> Here's why it matters: when you ran sudo cp, the copied files became owned by root (because you ran the command with sudo). But nginx itself doesn't run as root during normal operation — on Debian/Ubuntu it runs as a low-privilege system user called www-data, specifically for security (so if nginx or an app it serves gets compromised, the attacker doesn't get root).
>
> So without this chown, you'd have:
>
> * Files owned by root
> * nginx worker process running as www-data
> * www-data may not have permission to read those files, depending on the permission bits
>
> Running chown -R www-data:www-data fixes that by making www-data (both the user and group) the owner of every file in that directory, guaranteeing nginx can actually read these files.
>
> This is the direct nginx/Debian equivalent of what restorecon did in the earlier Fedora/Apache example — except that was fixing an SELinux label problem, and this is fixing a plain Unix ownership problem. Different mechanism, same underlying goal: "make sure the web server is allowed to read these files."

* Created a dedicated nginx server block for the app (rather than using the default site), including `try_files $uri $uri/ /index.html;` to support client-side routing in the SPA. Disabled the stock default site to avoid conflicts.

```bash
sudo nano /etc/nginx/sites-available/k8s-3d-viz
```

```nginx
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

* Enabled and reloaded nginx.

```bash
sudo ln -s /etc/nginx/sites-available/k8s-3d-viz /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx
```

* Opened TCP/80 in ufw, scoped to the same two sources as Step 1 (`172.31.16.0/22` and `172.24.209.0/24`).

```bash
sudo ufw allow from 172.31.16.0/22 to any port 80 proto tcp 
sudo ufw allow from 172.24.209.0/24 to any port 80 proto tcp 
sudo ufw status verbose
```

* Verified: reachable with 200 OK and rendering correctly from the Windows workstation.

---

## Step 3 — RHEL (`172.31.18.26`), reverse proxy — ✅ Complete (both variants)

### Variant A: Round-robin (port 80)

* Installed nginx via the RHEL AppStream module (`dnf module install nginx:1.24`).

```bash
sudo dnf module list nginx
sudo dnf module install -y nginx:1.24
nginx -v
```

* Configured an upstream block (`app_backends`) listing both backends (Fedora `172.31.17.243:80`, Ubuntu `172.31.17.182:80`) and a `server {}` block on port 80 proxying `/` to it — nginx's default load-balancing algorithm (round-robin) required no extra directive.

```bash
sudo nano /etc/nginx/conf.d/lb.conf
```

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

* Set SELinux boolean `httpd_can_network_connect=1` so nginx is permitted to make outbound connections to the two backend hosts.

```bash
sudo setsebool -P httpd_can_network_connect 1

sudo systemctl enable --now nginx 
sudo systemctl status nginx --no-pager
```

* Opened TCP/80 in firewalld, scoped to `172.31.16.0/22` and `172.24.209.0/24`.
* Verified: repeated requests to `http://172.31.18.26/` alternate between App 1 and App 2, confirming round-robin behavior.

### Variant B: Path-based routing (port 8080)

* Both SPAs needed to be rebuilt with a non-root base path, since Vite emits absolute root-relative asset paths (`/assets/...`) by default, which breaks once an app is served under a subpath:

  * Fedora: rebuilt with `--base=/topology/` into a separate `dist-topology/`, deployed to `/var/www/html/topology/` alongside (not replacing) the existing root deployment used by Variant A.
  * Ubuntu: rebuilt with `--base=/k8s/` into a separate `dist-k8s/`, deployed to `/var/www/k8s-3d-viz-path/`, exposed via a new `location /k8s/ { alias ...; }` block added to the existing nginx site.

* On RHEL, added a second `server {}` block listening on port 8080 in the same nginx instance (alongside the port-80 round-robin config, both live simultaneously, no conflict):

  * `/` → a plain text landing message.
  * `/topology/` → proxied to the Fedora backend.
  * `/k8s/` → proxied to the Ubuntu backend.

```bash
sudo nano /etc/nginx/conf.d/path.conf
```

```nginx
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

* Reused the `httpd_can_network_connect` SELinux boolean already set for Variant A (same nginx process/type).
* Opened TCP/8080 in firewalld, scoped to the same two networks.
* Verified: `http://172.31.18.26:8080/topology/` and `http://172.31.18.26:8080/k8s/` each load the correct app with assets resolving correctly; round-robin on port 80 continued working unaffected.

**Outcome:** both traffic-splitting strategies run concurrently on the same RHEL proxy host, on separate ports, allowing direct side-by-side comparison — round-robin visibly alternates apps per request on one URL, while path-based routing gives each app a stable, predictable URL. This closes out Lab 01.

```bash
curl http://172.31.18.26:8080/
curl -I http://172.31.18.26:8080/topology/
curl -I http://172.31.18.26:8080/k8s/
```

---

# Step 4 — Implementation of TLS

Implementing it on your RHEL proxy

I'll add HTTPS listeners alongside your existing HTTP ones, keeping the same port pairing convention: 443 for round-robin, 8443 for path-based.

### 1. Generate a self-signed certificate

```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 365 \
  -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/lab.key \
  -out /etc/nginx/ssl/lab.crt \
  -subj "/CN=172.31.18.26" \
  -addext "subjectAltName=IP:172.31.18.26"
```

The subjectAltName matters — modern browsers ignore the old CN-only matching and require a SAN entry matching the address you connect to.

```bash
sudo chmod 600 /etc/nginx/ssl/lab.key
sudo restorecon -Rv /etc/nginx/ssl
```

### 2. Add an HTTPS server block for round-robin (443)

Edit `/etc/nginx/conf.d/lb.conf` and add this alongside the existing port-80 block (keep the `upstream app_backends {}` block as-is, both blocks reference it):

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

### 3. Add an HTTPS server block for path-based (8443)

Edit `/etc/nginx/conf.d/path.conf` and add:

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

### 4. Test config and reload

```bash
sudo nginx -t
sudo systemctl reload nginx
```

### 5. Firewall — open 443 and 8443

```bash
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.31.16.0/22" port protocol="tcp" port="443" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.24.209.0/24" port protocol="tcp" port="443" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.31.16.0/22" port protocol="tcp" port="8443" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="172.24.209.0/24" port protocol="tcp" port="8443" accept'
sudo firewall-cmd --reload
```

### 6. Verify

```bash
curl -k -I https://172.31.18.26/
curl -k -I https://172.31.18.26:8443/topology/
curl -k -I https://172.31.18.26:8443/k8s/
```

---

# DOCUMENTED FACES ISSUES

## Troubleshooting: Apache Reachable Locally But Not From Other Hosts

### Issue

After deploying a static build to Apache's document root (`/var/www/html`) and starting httpd, the site was reachable via curl from the server itself, but any other machine on the network (same subnet or a different one) got:

```text
curl: (7) Failed to connect to 172.31.17.243 port 80 after 0 ms: Couldn't connect to server
```

This error happens at the TCP handshake level — it means the connection is being blocked before HTTP even comes into play.

That immediately points to either:

* Apache not listening on the network interface (only on localhost), or
* A firewall blocking the port

It's not an SELinux or Apache-config issue — those would produce a 403/permission error, not a failed connection.

---

## Diagnostic Steps

### 1. Confirm Apache is listening on all interfaces, not just localhost

```bash
sudo ss -tlnp | grep :80
```

Result showed `*:80`, meaning Apache was listening correctly on all interfaces. This ruled out Apache config as the cause.

### 2. Check which firewalld zone is actually active on the network interface

```bash
sudo firewall-cmd --get-active-zones
```

This returned nothing — the key finding. It meant `ens192` wasn't actually bound to any firewalld zone at runtime, even though firewall rules had been added to the public zone.

Rules in a zone only apply to interfaces assigned to that zone.

### 3. Confirmed the firewall rules themselves were correctly configured

```bash
sudo firewall-cmd --list-all --zone=public
```

The rich rules allowing TCP port 80 from the two expected subnets were present and correctly formatted.

### 4. Confirmed source IP was within the allowed range

```bash
ip addr show
```

Verified `172.31.17.243/22` fell inside the `172.31.16.0/22` range already permitted by the rich rule — so the rule's source range wasn't the problem.

### 5. Isolated firewalld as the cause by temporarily stopping it

```bash
sudo systemctl stop firewalld
```

Connection succeeded from other hosts, confirming firewalld — specifically, the missing zone binding — was blocking traffic.

(Restarted firewalld immediately after, since disabling it is not a real fix.)

---

## Root Cause

The `ens192` interface was never explicitly assigned to a firewalld zone.

Without an active zone binding, firewalld didn't apply the public zone's rules to traffic on that interface, so incoming connections were dropped by default.

---

## Fix

Explicitly bind the interface to the public zone:

```bash
sudo firewall-cmd --zone=public --change-interface=ens192 --permanent
sudo firewall-cmd --reload
sudo firewall-cmd --get-active-zones
```

Confirmed fixed once this returned:

```text
public
  interfaces: ens192
```

Then verified from a remote host:

```bash
curl -I http://172.31.17.243/
```

— which succeeded.

---

## Alternative fix

(if using NetworkManager-managed connections): the zone can also be set on the connection profile itself, which is the more "native" way NetworkManager expects zones to be assigned:

```bash
sudo nmcli connection modify ens192 connection.zone public
sudo nmcli connection up ens192
```

Either approach works; they both result in the interface being tied to the zone whose rules you want enforced.

**Note:** changing the zone on an active interface can briefly interrupt existing connections (including SSH) for a moment — worth expecting if doing this over a remote session.

---

## Understanding firewalld Zones (the part that was confusing)

Firewalld doesn't apply rules directly to the machine as a whole — it applies them per network interface, based on which zone that interface is assigned to.

A zone is just a named bucket of rules (allowed services, ports, rich rules, trust level, etc.).

### Key ideas

* A zone is a set of trust rules, not a global setting. `public` is a built-in zone meant for interfaces exposed to untrusted/external networks — by default it's fairly locked down (only a few services like SSH allowed).
* Rules only take effect on interfaces assigned to that zone. You can add all the rich rules you want to `public`, but if no interface is actually in the public zone, those rules are inert — this was exactly the bug here.
* `firewall-cmd --get-active-zones` shows the real, current binding — it lists each zone that has at least one interface actively assigned to it, and which interface(s). If your interface doesn't show up under any zone, its traffic isn't being governed by the zone's rules the way you'd expect.
* Zone assignment can happen in two places, and they can get out of sync:

  * Directly in firewalld (`firewall-cmd --zone=X --change-interface=...`)
  * In NetworkManager's connection profile (`nmcli connection modify ... connection.zone=...`)
* On Fedora (NetworkManager-managed systems), NetworkManager is usually the source of truth for zone assignment, and it hands that off to firewalld. If a connection profile has no zone set, firewalld may not bind it to anything active, even if the interface is up and working fine at the network level.
* **Practical takeaway:** whenever a firewall rule "should" be working but isn't, check `--get-active-zones` first, before questioning the rule syntax — a rule in the wrong (or no) zone is a very common and easy-to-miss cause.
