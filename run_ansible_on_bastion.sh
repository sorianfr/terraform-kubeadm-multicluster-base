#!/bin/bash
set -euo pipefail

BASTION_HOST="$1"
SSH_KEY="./k8s-key.pem"

echo "🔧 Running Ansible playbooks from Bastion..."

ssh -o StrictHostKeyChecking=no -i "$SSH_KEY" ubuntu@"$BASTION_HOST" <<'EOF'
set -euo pipefail

# The directory where ansible files live on the bastion
ANSIBLE_DIR="/home/ubuntu/ansible"
INVENTORY="inventory/hosts.yml"

test -d "$ANSIBLE_DIR"

cd $ANSIBLE_DIR

ansible-playbook -i inventory/hosts.yml playbooks/1_fetch_kubeconfigs.yml
ansible-playbook -i inventory/hosts.yml playbooks/2_normalize_kubeconfigs.yml
ansible-playbook -i inventory/hosts.yml playbooks/3_merge_kubeconfigs.yml
ansible-playbook -i inventory/hosts.yml playbooks/4_untaint_nodes.yml
ansible-playbook -i inventory/hosts.yml playbooks/5_install_calico.yml
ansible-playbook -i inventory/hosts.yml playbooks/6_install_helm.yml
ansible-playbook -i inventory/hosts.yml playbooks/7_install_aws_ccm.yml
#ansible-playbook -i inventory/hosts.yml playbooks/8_install_certs.yml

# Install EBS CSI so StorageClass/PVC provisioning is ready
ansible-playbook -i "$INVENTORY" playbooks/14_install_ebs_csi_driver.yml
EOF

echo "✅ Finished running Ansible playbooks on Bastion."
