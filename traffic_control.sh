#!/bin/bash

start_traffic() {
  echo "Starting realistic background traffic..."

  # 1. PC1: Dual-stack Web browsing (2-6 Mbit/s combined) + ~2 DNS queries/s
  docker exec -d clab-projet9-pc1 bash -c 'cat << "EOS" > /tmp/bg_traffic.sh
#!/bin/bash
(while true; do
  curl -s --max-time 5 -o /dev/null http://10.10.3.10/index.html
  sleep $((1 + RANDOM % 5))
  curl -s --max-time 5 -o /dev/null http://[2001:db8:10:3::10]/index.html
  sleep $((1 + RANDOM % 5))
done) &
(while true; do
  dig @10.10.3.53 intranet.entreprise.local A +short > /dev/null 2>&1
  sleep 0.5
done) &
wait
EOS
chmod +x /tmp/bg_traffic.sh && /tmp/bg_traffic.sh'

  # 2. PC2: Web browsing + ~2 DNS queries/s + 10 Mbit/s iperf3 transfer (60s every 5 min)
  docker exec -d clab-projet9-pc2 bash -c 'cat << "EOS" > /tmp/bg_traffic.sh
#!/bin/bash
(while true; do
  curl -s --max-time 5 -o /dev/null http://10.10.3.10/index.html
  sleep $((1 + RANDOM % 5))
done) &
(while true; do
  dig @2001:db8:10:3::53 srv-web.entreprise.local AAAA +short > /dev/null 2>&1
  sleep 0.5
done) &
(while true; do
  iperf3 -c 10.10.3.10 -b 10M -t 60 > /dev/null 2>&1
  sleep 240
done) &
wait
EOS
chmod +x /tmp/bg_traffic.sh && /tmp/bg_traffic.sh'

  # 3. ATTACKER: Normal external visitor (1 lightweight HTTP request every 2s, < 1 Mbit/s)
  docker exec -d clab-projet9-attacker bash -c 'cat << "EOS" > /tmp/bg_traffic.sh
#!/bin/bash
while true; do
  curl -s --max-time 5 -o /dev/null http://10.10.3.10/
  sleep 2
done
EOS
chmod +x /tmp/bg_traffic.sh && /tmp/bg_traffic.sh'

  echo "All background traffic generators started."
}

stop_traffic() {
  echo "Stopping background traffic..."
  for node in clab-projet9-pc1 clab-projet9-pc2 clab-projet9-attacker; do
    docker exec $node pkill -f bg_traffic.sh 2>/dev/null || true
    docker exec $node pkill -f iperf3 2>/dev/null || true
  done
  echo "Background traffic stopped."
}

status_traffic() {
  for node in clab-projet9-pc1 clab-projet9-pc2 clab-projet9-attacker; do
    echo "=== $node ==="
    docker exec $node pgrep -af "bg_traffic|curl|dig|iperf3" || echo "No active generators"
  done
}

case "$1" in
  start) start_traffic ;;
  stop) stop_traffic ;;
  status) status_traffic ;;
  *) echo "Usage: $0 {start|stop|status}" ;;
esac
