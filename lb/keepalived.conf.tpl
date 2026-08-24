! keepalived configuration for the OKD API and ingress VIPs.
!
! Rendered by scripts/03-render-lb-manifests.sh — do not edit in place.
!
! Priority scheme. Every instance starts from a low base and is raised by its
! track_script, so an unhealthy holder always loses to a healthy candidate:
!
!   healthy master    __MASTER_BASE__ + __MASTER_WEIGHT__ = 150
!   healthy bootstrap  __BOOTSTRAP_BASE__ + __BOOTSTRAP_WEIGHT__ =  90
!   unhealthy master                      =  50
!   unhealthy bootstrap                   =  40
!
! That ordering is what makes the bootstrap handover work without any manual
! step: while the masters have no API yet, bootstrap outranks them and serves
! api-int:22623 so they can fetch their ignition. The moment a master's own
! apiserver answers /readyz it outranks bootstrap and takes the VIP, and when
! bootstrap is destroyed nothing has to change.

global_defs {
    enable_script_security
    script_user root
}

vrrp_script chk_api {
    ! `test -f` only — the probing happens on the host, see vip-healthcheck.sh
    script "/bin/sh -c 'test -f /etc/keepalived-okd/state/api-healthy'"
    interval 2
    timeout 2
    rise 2
    fall 2
    weight __API_WEIGHT__
}

vrrp_instance API {
    ! BACKUP everywhere with no preempt delay: whoever is healthiest wins the
    ! election rather than whoever booted first.
    state BACKUP
    interface __VRRP_INTERFACE__
    virtual_router_id __VRRP_ID_API__
    priority __API_BASE__
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass __AUTH_PASS__
    }

    virtual_ipaddress {
        __API_VIP__/__PREFIX_LEN__
    }

    track_script {
        chk_api
    }
}
__INGRESS_BLOCK__
