#!/bin/bash
set -xe

### --- STOP KUBELET WHILE CONFIGURING --- ###
sudo systemctl stop kubelet || true

### --- IMDSv2 TOKEN --- ###
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" -s)

INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

PROVIDER_ID="aws:///$AZ/$INSTANCE_ID"
echo "ProviderID = $PROVIDER_ID"

### --- CREATE DROP-IN FOR KUBELET FLAGS --- ###
sudo mkdir -p /etc/systemd/system/kubelet.service.d

cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cloud-provider=external --provider-id=$PROVIDER_ID"
EOF

# sudo systemctl daemon-reload
# sudo systemctl restart kubelet


 ## --- WAIT FOR CONTROL PLANE API SERVER --- ###
 until nc -z -w5 "${controlplane_private_ip}" 6443; do
  echo "Waiting for Kubernetes API on ${controlplane_private_ip}:6443..."
  sleep 5
 done


 ### --- FETCH JOIN COMMAND FROM SECRETS MANAGER --- ###
 echo "Waiting for join command from Secrets Manager..."

 while true; do
   JOIN_CMD=$(aws secretsmanager get-secret-value \
     --region "${region}" \
     --secret-id "${cluster_name}/comando-unir" \
     --query SecretString \
     --output text 2>/dev/null)

   if [[ "$JOIN_CMD" != "waiting-for-controlplane" && "$JOIN_CMD" != "" ]]; then
     echo "Join command retrieved!"
     break
   fi

   echo "Still waiting for join command..."
   sleep 5
 done


# ### --- PARSE TOKEN AND CA HASH --- ###
 TOKEN_VALUE=$(echo "$JOIN_CMD" | sed -n 's/.*--token \([^ ]*\).*/\1/p')
 CA_HASH=$(echo "$JOIN_CMD" | sed -n 's/.*--discovery-token-ca-cert-hash \([^ ]*\).*/\1/p')

 echo "TOKEN_VALUE = $TOKEN_VALUE"
 echo "CA_HASH     = $CA_HASH"


 ### --- CREATE kubeadm JOIN CONFIG --- ###
 cat <<EOF | sudo tee /tmp/kubeadm-join.yaml
 apiVersion: kubeadm.k8s.io/v1beta4
 kind: JoinConfiguration
 discovery:
   bootstrapToken:
     token: "$TOKEN_VALUE"
     apiServerEndpoint: "${controlplane_private_ip}:6443"
     caCertHashes:
     - "$CA_HASH"
 nodeRegistration:
   criSocket: "unix:///var/run/containerd/containerd.sock"
   kubeletExtraArgs:
   - name: cloud-provider
     value: external
   - name: provider-id
     value: "$PROVIDER_ID"
EOF


### --- EXECUTE JOIN --- ###
sudo kubeadm join --config /tmp/kubeadm-join.yaml

### --- RESTART KUBELET --- ###
sudo systemctl restart kubelet

echo "✅ Worker joined the cluster successfully with provider-id $PROVIDER_ID"
