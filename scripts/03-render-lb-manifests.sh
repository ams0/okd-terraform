#!/usr/bin/env bash
# Render the keepalived VIP layer and install it in two places.
#
# On `platform: none` OKD renders no on-prem networking stack, so nothing
# provides the API or ingress VIP. (The `baremetal` platform does, via
# keepalived/haproxy/coredns static pods, but it requires BMC hosts that
# Proxmox VMs do not have.) This script fills that gap.
#
# Deliberately keepalived-only — no haproxy, no nftables. OpenShift's own
# on-prem stack DNATs VIP:6443 to a separate haproxy port because it wants the
# API load balanced across masters; reproducing that means reimplementing
# baremetal-runtimecfg. kube-apiserver already binds 0.0.0.0:6443, so a VIP
# landing on a master is served directly. The trade-off is that one master
# handles all external API traffic at a time; failover still works, and for a
# compact cluster that is the right amount of machinery.
#
# Two install points, because they are reached differently:
#   masters   -> a MachineConfig in install/openshift/, baked into the rendered
#                master config that MCS serves on first boot
#   bootstrap -> patched directly into bootstrap.ign, which is a complete,
#                self-contained config delivered locally via fw_cfg (so unlike
#                master.ign it needs no network to apply)
#
# Must run after `create manifests` and before `create ignition-configs` for
# the master half; the bootstrap half runs after ignitions exist.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LB="$ROOT/lb"
INSTALL="$ROOT/install"
TFVARS="$ROOT/terraform/terraform.tfvars"

MODE="${1:-manifests}" # manifests | bootstrap

[[ -f "$TFVARS" ]] || { echo "FATAL: $TFVARS missing" >&2; exit 1; }

KEEPALIVED_IMAGE="${KEEPALIVED_IMAGE:-quay.io/openshift/origin-keepalived-ipfailover:4.22}"

python3 - "$LB" "$INSTALL" "$TFVARS" "$MODE" "$KEEPALIVED_IMAGE" <<'PY'
import base64, ipaddress, json, os, re, sys, urllib.parse

lb_dir, install_dir, tfvars_path, mode, image = sys.argv[1:6]
tfvars = open(tfvars_path).read()


def var(name, default=None):
    m = re.search(r'^\s*%s\s*=\s*"([^"]*)"' % re.escape(name), tfvars, re.M)
    if m:
        return m.group(1)
    m = re.search(r'^\s*%s\s*=\s*([0-9]+)\s*$' % re.escape(name), tfvars, re.M)
    if m:
        return m.group(1)
    if default is None:
        sys.exit("%s not found in %s" % (name, tfvars_path))
    return default


api_vip = var("api_vip")
ingress_vip = var("ingress_vip")
machine_cidr = var("machine_network_cidr")
iface = var("vrrp_interface", "ens18")
vrid_api = var("vrrp_router_id_api", "51")
vrid_ingress = var("vrrp_router_id_ingress", "52")
prefix_len = str(ipaddress.ip_network(machine_cidr).prefixlen)

# VRRP's auth_pass is truncated to 8 characters by the protocol. It is not a
# security control (VRRPv2 sends it in the clear) -- it only stops two
# unrelated keepalived groups on the same segment from interfering. Derived
# from the VIP so it is stable across re-renders without needing to be stored.
auth_pass = base64.b32encode(api_vip.encode()).decode()[:8]

PRIO = {
    # base, weight  -> healthy total
    "master":    ("50", "100"),   # 150
    "bootstrap": ("40", "50"),    #  90
}


def render_conf(role):
    base, weight = PRIO[role]
    conf = open(os.path.join(lb_dir, "keepalived.conf.tpl")).read()

    # Bootstrap never runs a router, so it must not contend for the ingress VIP.
    if role == "master":
        ingress = open(os.path.join(lb_dir, "ingress-instance.conf.tpl")).read()
        ingress = (ingress
                   .replace("__INGRESS_WEIGHT__", weight)
                   .replace("__INGRESS_BASE__", base)
                   .replace("__INGRESS_VIP__", ingress_vip)
                   .replace("__VRRP_ID_INGRESS__", vrid_ingress)
                   .replace("__VRRP_INTERFACE__", iface)
                   .replace("__AUTH_PASS__", auth_pass)
                   .replace("__PREFIX_LEN__", prefix_len))
    else:
        ingress = ""

    return (conf
            .replace("__INGRESS_BLOCK__", ingress)
            .replace("__API_WEIGHT__", weight)
            .replace("__API_BASE__", base)
            .replace("__API_VIP__", api_vip)
            .replace("__VRRP_ID_API__", vrid_api)
            .replace("__VRRP_INTERFACE__", iface)
            .replace("__AUTH_PASS__", auth_pass)
            .replace("__PREFIX_LEN__", prefix_len)
            .replace("__MASTER_BASE__", PRIO["master"][0])
            .replace("__MASTER_WEIGHT__", PRIO["master"][1])
            .replace("__BOOTSTRAP_BASE__", PRIO["bootstrap"][0])
            .replace("__BOOTSTRAP_WEIGHT__", PRIO["bootstrap"][1]))


def data_url(text):
    return "data:text/plain;charset=utf-8;base64," + base64.b64encode(text.encode()).decode()


HEALTHCHECK_UNIT = """[Unit]
Description=Publish OKD VIP health as flag files for keepalived
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=CHECK_INGRESS=%(check_ingress)s
ExecStart=/usr/local/bin/okd-vip-healthcheck.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""

# --net=host and --privileged are both required: keepalived manipulates
# addresses and sends VRRP multicast on the host interface. --pid=host is not,
# and is deliberately omitted.
KEEPALIVED_UNIT = """[Unit]
Description=keepalived for the OKD API%(and_ingress)s VIP
After=network-online.target okd-vip-healthcheck.service
Wants=network-online.target okd-vip-healthcheck.service

[Service]
Type=simple
ExecStartPre=-/usr/bin/podman rm -f okd-keepalived
ExecStart=/usr/bin/podman run --rm --name okd-keepalived \\
  --net=host --privileged \\
  -v /etc/keepalived:/etc/keepalived:z \\
  %(image)s \\
  /usr/sbin/keepalived -n -l -f /etc/keepalived/keepalived.conf
ExecStop=-/usr/bin/podman stop -t 10 okd-keepalived
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
"""


def files_and_units(role):
    check_ingress = "1" if role == "master" else "0"
    files = [
        {"path": "/etc/keepalived/keepalived.conf", "mode": 0o644,
         "contents": {"source": data_url(render_conf(role))}},
        {"path": "/usr/local/bin/okd-vip-healthcheck.sh", "mode": 0o755,
         "contents": {"source": data_url(open(os.path.join(lb_dir, "vip-healthcheck.sh")).read())}},
    ]
    units = [
        {"name": "okd-vip-healthcheck.service", "enabled": True,
         "contents": HEALTHCHECK_UNIT % {"check_ingress": check_ingress}},
        {"name": "okd-keepalived.service", "enabled": True,
         "contents": KEEPALIVED_UNIT % {
             "image": image,
             "and_ingress": " and ingress" if role == "master" else "",
         }},
    ]
    return files, units


if mode == "manifests":
    files, units = files_and_units("master")
    mc = {
        "apiVersion": "machineconfiguration.openshift.io/v1",
        "kind": "MachineConfig",
        "metadata": {
            "name": "99-master-okd-keepalived",
            "labels": {"machineconfiguration.openshift.io/role": "master"},
        },
        "spec": {
            "config": {
                "ignition": {"version": "3.2.0"},
                "storage": {"files": files},
                "systemd": {"units": units},
            }
        },
    }
    out = os.path.join(install_dir, "openshift", "99-master-okd-keepalived.yaml")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    # json is valid yaml, and emitting it avoids a pyyaml dependency
    with open(out, "w") as f:
        json.dump(mc, f, indent=2)
    print("wrote %s (api_vip=%s ingress_vip=%s iface=%s)" % (out, api_vip, ingress_vip, iface))

elif mode == "bootstrap":
    ign_path = os.path.join(install_dir, "bootstrap.ign")
    if not os.path.exists(ign_path):
        sys.exit("FATAL: %s not found -- run create ignition-configs first" % ign_path)
    ign = json.load(open(ign_path))
    files, units = files_and_units("bootstrap")

    storage = ign.setdefault("storage", {})
    existing = storage.setdefault("files", [])
    # Idempotent: drop any previous copy of our files before re-adding.
    ours = {f["path"] for f in files}
    storage["files"] = [f for f in existing if f.get("path") not in ours] + files

    systemd = ign.setdefault("systemd", {})
    existing_units = systemd.setdefault("units", [])
    our_units = {u["name"] for u in units}
    systemd["units"] = [u for u in existing_units if u.get("name") not in our_units] + units

    with open(ign_path, "w") as f:
        json.dump(ign, f)
    print("patched %s with keepalived (priority %s+%s, api VIP only)"
          % (ign_path, PRIO["bootstrap"][0], PRIO["bootstrap"][1]))

else:
    sys.exit("unknown mode %r (expected 'manifests' or 'bootstrap')" % mode)
PY
