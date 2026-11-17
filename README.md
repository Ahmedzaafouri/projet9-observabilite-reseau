# Projet n°9 — Observabilité et Détection d'Anomalies Réseau (INSAT RT3)

Migration d'une supervision SNMP par sondage (5 min) vers une télémétrie de flux (sFlow/IPFIX) et métriques haute fréquence (Prometheus / Grafana / Alertmanager).

---

## 1. Architecture Réseau (Topologie Containerlab)

L'infrastructure repose sur un cœur triangulaire de **3 routeurs FRRouting** (`R-CORE`, `R-LAN`, `R-DMZ`) reliés par des liens limités à **100 Mbit/s** (`tc`), deux commutateurs virtuels (`SW-LAN`, `SW-DMZ` via Linux bridges), cinq hôtes finaux, ainsi qu'un **réseau d'administration hors-bande (`clab-mgmt`)** isolant le trafic de supervision.

                            [ ATTACKER ] (netshoot)
                             eth1: .66 / ::66
                                    |
                          EXT: 203.0.113.0/24
                               2001:db8:10:9::/64
                                    |
                             eth3: .1 / ::1
                             +------------+
                             |   R-CORE   | (mgmt: 172.20.20.11)
                             +------------+
                            /              \
           eth1: .1 / ::1  /                \  eth2: .1 / ::1
                          /                  \
       L12: 10.0.12.0/30 /                    \ L13: 10.0.13.0/30
       2001:db8:0:12::/64                      2001:db8:0:13::/64
           (100 Mbit/s) /                      \ (100 Mbit/s)
                       /                        \
        eth1: .2 / ::2/                          \eth1: .2 / ::2
        +------------+    L23: 10.0.23.0/30       +------------+
        |   R-LAN    |----------------------------|   R-DMZ    |
        +------------+     2001:db8:0:23::/64     +------------+
       (172.20.20.12)  eth2:.1/::1    eth2:.2/::2  (172.20.20.13)
              |             (100 Mbit/s)                 |
        eth3: .1 / ::1                             eth3: .1 / ::1
              |                                          |
        +------------+                             +------------+
        |   SW-LAN   | (Linux Bridge)              |   SW-DMZ   | (Linux Bridge)
        +------------+                             +------------+
           /      \                                   /      \
          /        \                                 /        \
    [ PC1 ]        [ PC2 ]                    [ SRV-WEB ]    [ SRV-DNS ]
    .11 / ::11     .12 / ::12                 .10 / ::10     .53 / ::53
    LAN: 10.10.1.0/24                         DMZ: 10.10.3.0/24
         2001:db8:10:1::/64                        2001:db8:10:3::/64

    ========================================================================
    Réseau de Gestion Hors-Bande : clab-mgmt (172.20.20.0/24 sur eth0)
      - Routeurs : .11 (R-CORE), .12 (R-LAN), .13 (R-DMZ)
      - Hôtes    : .21 (PC1), .22 (PC2), .30 (SRV-WEB), .53 (SRV-DNS), .66 (ATTACKER)
      - Stack Supervision : .101 à .107 (Prometheus, Grafana, GoFlow2, etc.)
    ========================================================================

---

## 2. Plan d'Adressage Double Pile (IPv4 / IPv6)

Le routage dynamique entre tous les sous-réseaux est assuré par **OSPFv2 (IPv4)** et **OSPFv3 (IPv6)** dans l'aire unique `0.0.0.0`. Le trafic LAN vers DMZ emprunte le lien direct **L23** (`R-LAN` vers `R-DMZ`).

| Sous-réseau / Lien | Préfixe IPv4 | Préfixe IPv6 | Équipement | Interface | Adresse IPv4 | Adresse IPv6 | Passerelle par défaut |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **LAN (Employés)** | `10.10.1.0/24` | `2001:db8:10:1::/64` | `R-LAN` | `eth3` | `10.10.1.1/24` | `2001:db8:10:1::1/64` | — (OSPFv2/v3) |
| | | | `PC1` | `eth1` | `10.10.1.11/24` | `2001:db8:10:1::11/64` | `10.10.1.1` / `2001:db8:10:1::1` |
| | | | `PC2` | `eth1` | `10.10.1.12/24` | `2001:db8:10:1::12/64` | `10.10.1.1` / `2001:db8:10:1::1` |
| **DMZ (Serveurs)** | `10.10.3.0/24` | `2001:db8:10:3::/64` | `R-DMZ` | `eth3` | `10.10.3.1/24` | `2001:db8:10:3::1/64` | — (OSPFv2/v3) |
| | | | `SRV-WEB` | `eth1` | `10.10.3.10/24` | `2001:db8:10:3::10/64` | `10.10.3.1` / `2001:db8:10:3::1` |
| | | | `SRV-DNS` | `eth1` | `10.10.3.53/24` | `2001:db8:10:3::53/64` | `10.10.3.1` / `2001:db8:10:3::1` |
| **Externe (EXT)** | `203.0.113.0/24` | `2001:db8:10:9::/64` | `R-CORE` | `eth3` | `203.0.113.1/24` | `2001:db8:10:9::1/64` | — (OSPFv2/v3) |
| | | | `ATTACKER` | `eth1` | `203.0.113.66/24` | `2001:db8:10:9::66/64` | `203.0.113.1` / `2001:db8:10:9::1` |
| **Lien L12** | `10.0.12.0/30` | `2001:db8:0:12::/64` | `R-CORE` | `eth1` | `10.0.12.1/30` | `2001:db8:0:12::1/64` | — (OSPFv2/v3) |
| | | | `R-LAN` | `eth1` | `10.0.12.2/30` | `2001:db8:0:12::2/64` | — (OSPFv2/v3) |
| **Lien L13** | `10.0.13.0/30` | `2001:db8:0:13::/64` | `R-CORE` | `eth2` | `10.0.13.1/30` | `2001:db8:0:13::1/64` | — (OSPFv2/v3) |
| | | | `R-DMZ` | `eth1` | `10.0.13.2/30` | `2001:db8:0:13::2/64` | — (OSPFv2/v3) |
| **Lien L23** | `10.0.23.0/30` | `2001:db8:0:23::/64` | `R-LAN` | `eth2` | `10.0.23.1/30` | `2001:db8:0:23::1/64` | — (OSPFv2/v3) |
| | | | `R-DMZ` | `eth2` | `10.0.23.2/30` | `2001:db8:0:23::2/64` | — (OSPFv2/v3) |
| **Gestion (Mgmt)** | `172.20.20.0/24` | — | Tous les nœuds | `eth0` | `.11`–`.66` / `.101`–`.107` | — | `172.20.20.1` |

---

## 3. Scénario de Trafic de Fond Réaliste

Le trafic de fond est calibré pour occuper **~20 % de la capacité des liens** (100 Mbit/s), établissant une ligne de base réaliste sans générer de fausses alertes avant l'injection d'incidents :

| Flux | Source vers Destination | Protocole / Port | Outil & Cadence | Débit / Volume cible |
| :--- | :--- | :--- | :--- | :--- |
| **Navigation Web** | `PC1, PC2` -> `SRV-WEB` | HTTP (TCP 80, IPv4 & IPv6) | `curl` en boucle (pause aléatoire 1–5 s) | **2 à 6 Mbit/s** |
| **Requêtes DNS** | `PC1, PC2` -> `SRV-DNS` | DNS (UDP 53, IPv4 & IPv6) | `dig` en boucle (~2 req/s par PC) | **~4 requêtes/s** |
| **Transfert de fichiers** | `PC2` -> `SRV-WEB` | TCP (5201) | `iperf3` pendant 60 s toutes les 5 min | **10 Mbit/s** |
| **Visiteurs externes** | `ATTACKER` -> `SRV-WEB` | HTTP (TCP 80) | `curl` toutes les 2 s | **< 1 Mbit/s** |

---

## 4. Guide de Déploiement Rapide (Pour l'Équipe)

    # 1. Cloner le dépôt
    git clone https://github.com//projet9-observabilite-reseau.git
    cd projet9-observabilite-reseau

    # 2. Créer les bridges Linux et déployer la topologie Containerlab
    ./setup_bridges.sh
    sudo containerlab deploy -t projet9.clab.yml

    # 3. Démarrer les services (Web, DNS) et le trafic de fond
    ./init_services.sh

    # 4. Contrôler le trafic de fond à tout moment
    ./traffic_control.sh status   # Vérifier les processus actifs
    ./traffic_control.sh stop     # Arrêter le trafic de fond
    ./traffic_control.sh start    # Relancer le trafic de fond

    # 5. Détruire le laboratoire en fin de session
    sudo containerlab destroy -t projet9.clab.yml --cleanup
