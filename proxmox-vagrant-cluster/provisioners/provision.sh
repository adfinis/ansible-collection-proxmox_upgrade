#!/bin/bash
set -eux

node_id=$1; shift
ip=$1; shift
cluster_network_first_node_ip=$1; shift
cluster_network=$1; shift
cluster_ip=$1; shift
storage_ip=$1; shift
gateway_ip=$1; shift
storage_mtu=$1; shift
fqdn=$(hostname --fqdn)
domain=$(hostname --domain)
dn=$(hostname)

# configure apt for non-interactive mode.
export DEBIAN_FRONTEND=noninteractive

# update the package cache.
apt-get update

# configure the network.
ifdown vmbr0
cat >/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
    # vagrant network.

auto eth1
iface eth1 inet manual
    # service network.

auto eth2
iface eth2 inet static
    # corosync network.
    address $cluster_ip
    netmask 255.255.255.0

auto eth3
iface eth3 inet static
    # storage network.
    address $storage_ip
    netmask 255.255.255.0
    mtu $storage_mtu

auto vmbr0
iface vmbr0 inet static
    # service network.
    address $ip
    netmask 255.255.255.0
    bridge_ports eth1
    bridge_stp off
    bridge_fd 0
EOF
cat >>/etc/dhcp/dhclient.conf <<EOF
# make sure resolv.conf will always have our gateway dns server.
supersede domain-name-servers $gateway_ip;
EOF
cat >/etc/resolv.conf <<EOF
nameserver $gateway_ip
EOF
cat >/etc/hosts <<EOF
127.0.0.1 localhost.localdomain localhost
$ip $fqdn $dn pvelocalhost
EOF
sed 's,\\,\\\\,g' >/etc/issue <<'EOF'

     _ __  _ __ _____  ___ __ ___   _____  __ __   _____
    | '_ \| '__/ _ \ \/ / '_ ` _ \ / _ \ \/ / \ \ / / _ \
    | |_) | | | (_) >  <| | | | | | (_) >  <   \ V /  __/
    | .__/|_|  \___/_/\_\_| |_| |_|\___/_/\_\   \_/ \___|
    | |
    |_|

EOF
cat >>/etc/issue <<EOF
    https://$ip:8006/
    https://$fqdn:8006/

EOF
ifup eth1
ifup eth2
ifup eth3
ifup vmbr0
iptables-save # show current rules.
killall agetty | true # force them to re-display the issue file.

# configure postfix to relay emails through our gateway.
echo "$domain" >/etc/mailname
postconf -e 'myorigin = /etc/mailname'
postconf -e 'mydestination = '
postconf -e "relayhost = $domain"
postconf -e 'inet_protocols = ipv4'
systemctl reload postfix
# send test email.
sendmail root <<EOF
Subject: Hello World from $(hostname --fqdn) at $(date --iso-8601=seconds)

Hello World!
EOF

# disable the "You do not have a valid subscription for this server. Please visit www.proxmox.com to get a list of available options."
# message that appears each time you logon the web-ui.
# NB this file is restored when you (re)install the pve-manager package.
echo 'Proxmox.Utils.checked_command = function(o) { o(); };' >>/usr/share/pve-manager/js/pvemanagerlib.js

# install vim.
apt-get install -y --no-install-recommends vim
cat >/etc/vim/vimrc.local <<'EOF'
syntax on
set background=dark
set esckeys
set ruler
set laststatus=2
set nobackup
EOF

# configure the shell.
cat >/etc/profile.d/login.sh <<'EOF'
[[ "$-" != *i* ]] && return
export EDITOR=vim
export PAGER=less
alias l='ls -lF --color'
alias ll='l -a'
alias h='history 25'
alias j='jobs -l'
EOF

cat >/etc/inputrc <<'EOF'
set input-meta on
set output-meta on
set show-all-if-ambiguous on
set completion-ignore-case on
"\e[A": history-search-backward
"\e[B": history-search-forward
"\eOD": backward-word
"\eOC": forward-word
EOF

# configure the motd.
# NB this was generated at http://patorjk.com/software/taag/#p=display&f=Big&t=proxmox%20ve.
#    it could also be generated with figlet.org.
cat >/etc/motd <<'EOF'

     _ __  _ __ _____  ___ __ ___   _____  __ __   _____
    | '_ \| '__/ _ \ \/ / '_ ` _ \ / _ \ \/ / \ \ / / _ \
    | |_) | | | (_) >  <| | | | | | (_) >  <   \ V /  __/
    | .__/|_|  \___/_/\_\_| |_| |_|\___/_/\_\   \_/ \___|
    | |
    |_|

EOF

# trust the example CA.
cp /vagrant/shared/example-ca/example-ca-crt.pem /usr/local/share/ca-certificates/example-ca.crt
update-ca-certificates

if [ "$cluster_ip" == "$cluster_network_first_node_ip" ]; then
    # configure the keyboard.
    echo 'keyboard: de-ch' >>/etc/pve/datacenter.cfg

    # list the gateway nfs shares.
    pvesm scan nfs "$gateway_ip"

    # add the iso-templates shared storage pool.
    # no idea why vers=4 does not work.
    pvesm add nfs iso-templates \
        --server "$gateway_ip" \
        --export /srv/nfs/iso-templates \
        --options vers=3 \
        --content iso,vztmpl

    # add the snippets shared storage pool.
    # no idea why vers=4 does not work.
    pvesm add nfs snippets \
        --server "$gateway_ip" \
        --export /srv/nfs/snippets \
        --options vers=3 \
        --content snippets
fi

# create the cluster or add the node to the cluster.
# see https://pve.proxmox.com/wiki/Cluster_Manager
# see https://pve.proxmox.com/pve-docs/pve-admin-guide.html#_cluster_network
if [ "$cluster_ip" == "$cluster_network_first_node_ip" ]; then
    pvecm create example -nodeid "$node_id" -link0 "$cluster_ip"
else
    apt-get install -y --no-install-recommends expect
    # add the node to the cluster by automatically entering the root password. e.g.:
    #   pve2: Please enter superuser (root) password for '10.0.2.201':
    #   pve2: Etablishing API connection with host '10.0.2.201'
    expect <<EOF
spawn pvecm add $cluster_network_first_node_ip -nodeid $node_id -link0 $cluster_ip
expect -re "Please enter superuser (root) password for .+:"; send "vagrant\\r"
expect eof
EOF
fi
sleep 3
pvecm status || true
pvecm nodes
