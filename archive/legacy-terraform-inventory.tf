resource "local_file" "ansible_inventory" {
  content = <<EOF
[masters]
%{ for ip in azurerm_linux_virtual_machine.master_vm[*].private_ip_address ~}
${ip}
%{ endfor ~}

[workers]
%{ for ip in azurerm_linux_virtual_machine.worker_vm[*].private_ip_address ~}
${ip}
%{ endfor ~}

[okd:children]
masters
workers

[okd:vars]
ansible_user=core
ansible_ssh_private_key_file=~/.ssh/id_rsa
EOF
  filename = "${path.module}/../ansible/inventory/hosts.ini"
}
