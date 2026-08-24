
vrrp_script chk_ingress {
    script "/bin/sh -c 'test -f /etc/keepalived-okd/state/ingress-healthy'"
    interval 2
    timeout 2
    rise 2
    fall 2
    weight __INGRESS_WEIGHT__
}

vrrp_instance INGRESS {
    state BACKUP
    interface __VRRP_INTERFACE__
    ! A distinct virtual_router_id keeps this a separate VRRP group, so the
    ! ingress VIP can sit on a different node than the API VIP.
    virtual_router_id __VRRP_ID_INGRESS__
    priority __INGRESS_BASE__
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass __AUTH_PASS__
    }

    virtual_ipaddress {
        __INGRESS_VIP__/__PREFIX_LEN__
    }

    track_script {
        chk_ingress
    }
}
