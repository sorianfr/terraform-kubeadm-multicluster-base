#!/bin/bash
set -xe

# ============================================================
#  Prefer IPv4 (AWS NAT Gateway has no IPv6)
# ============================================================
echo "[INFO] Preferring IPv4 for outbound connections..."
if ! grep -q 'precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
  echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf
fi

# ============================================================
#  Wait until registry.k8s.io is reachable over IPv4
# ============================================================
echo "[INFO] Waiting for registry.k8s.io (IPv4)..."
for i in $(seq 1 30); do
  if curl -4 -sI --max-time 10 https://registry.k8s.io/v2/ >/dev/null 2>&1; then
    echo "[INFO] registry.k8s.io is reachable"
    break
  fi
  echo "[INFO] registry not ready yet (attempt $i/30), sleeping 10s..."
  sleep 10
done

# ============================================================
#  AWS CLOUD PROVIDER CONFIGURATION (if enabled)
# ============================================================
%{ if enable_aws_ccm }
echo "[INFO] Configuring AWS cloud provider metadata..."
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

PROVIDER_ID="aws:///$AZ/$INSTANCE_ID"
echo "ProviderID = $PROVIDER_ID"

sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cloud-provider=external --provider-id=$PROVIDER_ID"
EOF

sudo systemctl daemon-reload

echo "[INFO] Writing kubeadm configuration..."
cat <<EOF | sudo tee /tmp/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.31.14
networking:
  podSubnet: ${pod_cidr}
  serviceSubnet: ${service_cidr}
controllerManager:
  extraArgs:
  - name: cloud-provider
    value: external
  - name: configure-cloud-routes
    value: "false"
  - name: cluster-name
    value: ${cluster_name}
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${controlplane_private_ip}
nodeRegistration:
  kubeletExtraArgs:
  - name: cloud-provider
    value: external
  - name: provider-id
    value: $${PROVIDER_ID}
EOF

echo "[INFO] Pre-pulling Kubernetes images..."
sudo kubeadm config images pull --config /tmp/kubeadm-config.yaml

echo "[INFO] Initializing Kubernetes control plane..."
sudo kubeadm init --config /tmp/kubeadm-config.yaml

%{ else }

echo "[INFO] Pre-pulling Kubernetes images..."
sudo kubeadm config images pull --kubernetes-version v1.31.14

echo "[INFO] Initializing Kubernetes control plane (no external CCM)..."
sudo kubeadm init \
  --pod-network-cidr=${pod_cidr} \
  --service-cidr=${service_cidr} \
  --apiserver-advertise-address=${controlplane_private_ip} \
  --kubernetes-version v1.31.14

%{ endif }

# ============================================================
#  KUBECONFIG SETUP
# ============================================================
echo "[INFO] Setting up kubeconfig for ubuntu user..."
mkdir -p /home/ubuntu/.kube
sudo cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config

# ============================================================
#  SAVE JOIN COMMAND TO SECRETS MANAGER
# ============================================================
JOIN_CMD="$(kubeadm token create --ttl 0 --print-join-command || echo 'failed')"
JOIN_CMD="$JOIN_CMD --cri-socket unix:///var/run/containerd/containerd.sock"

echo "[INFO] Storing join command in AWS Secrets Manager..."
aws secretsmanager put-secret-value \
  --region "${region}" \
  --secret-id "${cluster_name}/comando-unir" \
  --secret-string "$JOIN_CMD" || true

echo "[INFO] User data completed successfully at $(date)" | sudo tee /var/log/user_data_done.log