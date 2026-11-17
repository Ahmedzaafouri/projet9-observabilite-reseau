#!/bin/bash
set -e

echo "1. Configuring SRV-WEB (HTTP port 80 + iperf3)..."
docker exec clab-projet9-srv-web dd if=/dev/urandom of=/tmp/index.html bs=1M count=1 2>/dev/null
docker exec -d clab-projet9-srv-web python3 -c '
import http.server, socketserver, socket
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw): super().__init__(*a, directory="/tmp", **kw)
    def address_string(self): return self.client_address[0]
    def log_message(self, *a): pass
class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    address_family = socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()
Server(("::", 80), Handler).serve_forever()
'
docker exec -d clab-projet9-srv-web iperf3 -s -D

echo "2. Configuring SRV-DNS (BIND9 entreprise.local)..."
docker exec -i clab-projet9-srv-dns sh -c '
cat << "EOC" > /etc/bind/named.conf.options
options {
    directory "/var/cache/bind";
    listen-on { any; };
    listen-on-v6 { any; };
    allow-query { any; };
    recursion no;
};
EOC
cat << "EOC" > /etc/bind/named.conf.local
zone "entreprise.local" {
    type master;
    file "/etc/bind/db.entreprise.local";
};
EOC
cat << "EOC" > /etc/bind/db.entreprise.local
\$TTL 60
@   IN  SOA ns1.entreprise.local. admin.entreprise.local. (
        2026111701 3600 900 604800 60 )
@           IN  NS      ns1.entreprise.local.
ns1         IN  A       10.10.3.53
ns1         IN  AAAA    2001:db8:10:3::53
srv-web     IN  A       10.10.3.10
srv-web     IN  AAAA    2001:db8:10:3::10
intranet    IN  A       10.10.3.10
intranet    IN  AAAA    2001:db8:10:3::10
EOC
printf "include \"/etc/bind/named.conf.options\";\ninclude \"/etc/bind/named.conf.local\";\n" > /etc/bind/named.conf
kill -HUP $(pidof named)
'

echo "3. Starting background traffic..."
~/Desktop/projet9/traffic_control.sh start
