TOP_DIR=$(cd $(dirname "$0") && pwd)
source $TOP_DIR/stackrc
source $TOP_DIR/functions
DEST=${DEST:-/opt/stack}
source $TOP_DIR/openrc

NOVA_DIR=$DEST/nova
if [ -d $NOVA_DIR/bin ] ; then
    NOVA_BIN_DIR=$NOVA_DIR/bin
else
    NOVA_BIN_DIR=/usr/local/bin
fi
MYSQL_USER=${MYSQL_USER:-root}
BM_PXE_INTERFACE=${BM_PXE_INTERFACE:-eth1}

apt_get install dnsmasq syslinux ipmitool qemu-kvm open-iscsi

apt_get install busybox tgt

BMIB_REPO=https://github.com/NTTdocomo-openstack/baremetal-initrd-builder.git
BMIB_DIR=$DEST/barematal-initrd-builder
BMIB_BRANCH=master
git_clone $BMIB_REPO $BMIB_DIR $BMIB_BRANCH

KERNEL_VER=`uname -r`
KERNEL_=/boot/vmlinuz-$KERNEL_VER
KERNEL=/tmp/deploy-kernel
sudo cp "$KERNEL_" "$KERNEL"
sudo chmod a+r "$KERNEL"
RAMDISK=/tmp/deploy-ramdisk.img

if [ ! -f "$RAMDISK" ]; then
(
	cd "$BMIB_DIR"
        ./baremetal-mkinitrd.sh "$RAMDISK" "$KERNEL_VER"
)
fi

GLANCE_HOSTPORT=${GLANCE_HOSTPORT:-$GLANCE_HOST:9292}

TOKEN=$(keystone  token-get | grep ' id ' | get_field 2)
KERNEL_ID=$(glance --os-auth-token $TOKEN --os-image-url http://$GLANCE_HOSTPORT image-create --name "baremetal-deployment-kernel" --public --container-format aki --disk-format aki < "$KERNEL" | grep ' id ' | get_field 2)
echo "$KERNEL_ID"

RAMDISK_ID=$(glance --os-auth-token $TOKEN --os-image-url http://$GLANCE_HOSTPORT image-create --name "baremetal-deployment-ramdisk" --public --container-format ari --disk-format ari < "$RAMDISK" | grep ' id ' | get_field 2)
echo "$RAMDISK_ID"

TFTPROOT=$DEST/tftproot

if [ -d "$TFTPROOT" ]; then
    rm -r "$TFTPROOT"
fi
mkdir "$TFTPROOT"
cp /usr/lib/syslinux/pxelinux.0 "$TFTPROOT"
mkdir $TFTPROOT/pxelinux.cfg

DNSMASQ_PID=/dnsmasq.pid
if [ -f "$DNSMASQ_PID" ]; then
    sudo kill `cat "$DNSMASQ_PID"`
    sudo rm "$DNSMASQ_PID"
fi
sudo /etc/init.d/dnsmasq stop
sudo sudo update-rc.d dnsmasq disable
sudo dnsmasq --conf-file= --port=0 --enable-tftp --tftp-root=$TFTPROOT --dhcp-boot=pxelinux.0 --bind-interfaces --pid-file=$DNSMASQ_PID --interface=$BM_PXE_INTERFACE --dhcp-range=192.168.175.100,192.168.175.254


mkdir -p $NOVA_DIR/baremetal/console
mkdir -p $NOVA_DIR/baremetal/dnsmasq

inicomment /etc/nova/nova.conf DEFAULT firewall_driver

function is() {
    iniset /etc/nova/nova.conf DEFAULT "$1" "$2"
}

is baremetal_sql_connection mysql://$MYSQL_USER:$MYSQL_PASSWORD@127.0.0.1/nova_bm
is compute_driver nova.virt.baremetal.driver.BareMetalDriver
is baremetal_driver nova.virt.baremetal.pxe.PXE
is power_manager nova.virt.baremetal.ipmi.Ipmi
is instance_type_extra_specs cpu_arch:x86_64
is baremetal_tftp_root $TFTPROOT
#is baremetal_term /usr/local/bin/shellinaboxd
is baremetal_deploy_kernel $KERNEL_ID
is baremetal_deploy_ramdisk $RAMDISK_ID
is scheduler_host_manager nova.scheduler.baremetal_host_manager.BaremetalHostManager

mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'DROP DATABASE IF EXISTS nova_bm;'
mysql -u$MYSQL_USER -p$MYSQL_PASSWORD -e 'CREATE DATABASE nova_bm CHARACTER SET latin1;'

$NOVA_BIN_DIR/nova-bm-manage db sync

# Please change parameters according to your bare-metal machine
node_id=$( $NOVA_BIN_DIR/nova-bm-manage node create --host `hostname` --cpus 2 --memory_mb=8192 --local_gb=250 --pm_address=172.16.212.6 --pm_user=test --pm_password=password --terminal_port=0 --prov_mac_address=3c:4a:92:72:38:23 )

# Please change parameters according to your bare-metal machine
$NOVA_BIN_DIR/nova-bm-manage interface create --node_id=$node_id --mac_address=12:34:56:78:90:ab --datapath_id=0x0 --port_no=0


NL=`echo -ne '\015'`

echo "restarting nova-scheduler"
screen -S stack -p n-sch -X kill
screen -S stack -X screen -t n-sch
sleep 1.5
screen -S stack -p n-sch -X stuff "cd $NOVA_DIR && $NOVA_BIN_DIR/nova-scheduler $NL"

echo "restarting nova-compute"
screen -S stack -p n-cpu -X kill
screen -S stack -X screen -t n-cpu
sleep 1.5
screen -S stack -p n-cpu -X stuff "cd $NOVA_DIR && sg libvirtd $NOVA_BIN_DIR/nova-compute $NL"

echo "starting bm_deploy_server"
screen -S stack -p n-bmd -X kill
screen -S stack -X screen -t n-bmd
sleep 1.5
screen -S stack -p n-bmd -X stuff "cd $NOVA_DIR && $NOVA_BIN_DIR/bm_deploy_server $NL"
