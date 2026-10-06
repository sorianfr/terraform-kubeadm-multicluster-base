# terraform-kubeadm-multicluster

This Terraform project provisions multiple self-managed Kubernetes clusters on AWS using kubeadm and Auto Scaling Groups (ASGs).
Each cluster has:
- 1 control-plane node
- Worker Auto Scaling Group
- Pod CIDR and Service CIDR configurable per cluster
- Permanent kubeadm join command stored securely in AWS Secrets Manager
- Optional AWS Cloud Controller Manager (CCM) configuration that enables the external AWS cloud provider integration when `enable_aws_ccm = true`

See `terraform.tfvars` for cluster definitions.


#PACKER
packer init .
packer build ami.pkr.hcl

#copia key a .ssh para poder hacer remote connect
cp ./k8s-key.pem /mnt/c/Users/soria/.ssh/k8s-key.pem


#ANSIBLE
ansible-playbook -i inventory/hosts.yml playbooks/1_fetch_kubeconfigs.yml
ansible-playbook -i inventory/hosts.yml playbooks/2_normalize_kubeconfigs.yml
ansible-playbook -i inventory/hosts.yml playbooks/3_merge_kubeconfigs.yml 
ansible-playbook -i inventory/hosts.yml playbooks/4_untaint_nodes.yml
ansible-playbook -i inventory/hosts.yml playbooks/5_install_calico.yml
ansible-playbook -i inventory/hosts.yml playbooks/6_install_helm.yml 
ansible-playbook -i inventory/hosts.yml playbooks/7_install_aws_ccm.yml
ansible-playbook -i inventory/hosts.yml playbooks/8_install_certs.yml
ansible-playbook -i inventory/hosts.yml playbooks/14_install_ebs_csi_driver.yml

# BEFORE terraform destroy: uninstall Istio (removes AWS LBs that block VPC delete)
./uninstall_istio.sh
# or: ./uninstall_istio.sh $(terraform output -raw bastion_public_dns)
# or on bastion: ./uninstall_istio.sh --local



kubectl config get-contexts

To deploy the AWS CCM on clusters that enable it, run `ansible-playbook playbooks/7_install_aws_ccm.yml` from the bastion or your local machine after provisioning. The playbook installs the controller only on clusters with `enable_aws_ccm` enabled.

kubectl -n kube-system logs deployment/aws-cloud-controller-manager

kubectl get nodes -o custom-columns=NAME:.metadata.name,PROVIDERID:.spec.providerID,STATUS:.status.conditions[-1].type --context cluster2


aws ssm describe-instance-information --query "InstanceInformationList[*].InstanceId"
[
    "i-07c575731f6c8e91d",
    "i-078aea95349b80ff4"
]
aws ssm start-session --target i-027dec4bd373d07ac --region us-east-1



curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o session-manager-plugin.deb
sudo apt-get update
sudo apt-get install -y ./session-manager-plugin.deb



Untaint nodes

kubectl --context cluster1 taint nodes --all node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-
kubectl --context cluster2 taint nodes --all node.cloudprovider.kubernetes.io/uninitialized:NoSchedule-

kubectl get pods -A
NAMESPACE     NAME                                       READY   STATUS    RESTARTS   AGE
kube-system   calico-kube-controllers-798f56bb9d-p4lch   1/1     Running   0          4m27s
kube-system   calico-node-5htxg                          1/1     Running   0          4m27s
kube-system   calico-node-s592v                          1/1     Running   0          4m27s
kube-system   coredns-7c65d6cfc9-c9kn8                   1/1     Running   0          5m41s
kube-system   coredns-7c65d6cfc9-fk6cm                   1/1     Running   0          5m41s
kube-system   etcd-ip-10-0-2-10                          1/1     Running   0          5m48s
kube-system   kube-apiserver-ip-10-0-2-10                1/1     Running   0          5m48s
kube-system   kube-controller-manager-ip-10-0-2-10       1/1     Running   0          5m48s
kube-system   kube-proxy-kfrgk                           1/1     Running   0          5m40s
kube-system   kube-proxy-w59r8                           1/1     Running   0          5m42s
kube-system   kube-scheduler-ip-10-0-2-10                1/1     Running   0          5m49s



helm repo add aws-cloud-controller-manager https://kubernetes.github.io/cloud-provider-aws
helm repo update
helm search repo aws-cloud-controller-manager

helm upgrade --install aws-ccm \
  aws-cloud-controller-manager/aws-cloud-controller-manager \
  --namespace kube-system \
  --set args[0]="--v=2" \
  --set args[1]="--cloud-provider=aws" \
  --set args[2]="--cluster-name=cluster1" \
  --set args[3]="--configure-cloud-routes=false" \
  --kubeconfig ~/ansible/kubeconfigs/cluster1-kubeconfig.yaml



kubectl --kubeconfig ~/ansible/kubeconfigs/cluster1-kubeconfig.yaml \
  -n kube-system get daemonset aws-cloud-controller-manager

NAME                           DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR                            AGE
aws-cloud-controller-manager   1         1         1       1            1           node-role.kubernetes.io/control-plane=   3m10s



kubectl get nodes -o wide
NAME            STATUS   ROLES           AGE   VERSION    INTERNAL-IP   EXTERNAL-IP   OS-IMAGE             KERNEL-VERSION   CONTAINER-RUNTIME
ip-10-0-2-10    Ready    control-plane   21m   v1.31.13   10.0.2.10     <none>        Ubuntu 22.04.5 LTS   6.8.0-1040-aws   containerd://1.7.28
ip-10-0-2-210   Ready    <none>          21m   v1.31.13   10.0.2.210    <none>        Ubuntu 22.04.5 LTS   6.8.0-1040-aws   containerd://1.7.28







kubectl --context cluster1 -n default describe svc nginx-lb-test
Name:                     nginx-lb-test
Namespace:                default
Labels:                   <none>
Annotations:              <none>
Selector:                 app=nginx-test
Type:                     LoadBalancer
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.107.165.65
IPs:                      10.107.165.65
Port:                     <unset>  80/TCP
TargetPort:               80/TCP
NodePort:                 <unset>  32145/TCP
Endpoints:                10.244.133.65:80
Session Affinity:         None
External Traffic Policy:  Cluster
Internal Traffic Policy:  Cluster
Events:
  Type     Reason                  Age                 From                Message
  ----     ------                  ----                ----                -------
  Warning  SyncLoadBalancerFailed  111s                service-controller  Error syncing load balancer: failed to ensure load balancer: operation error Elastic Load Balancing: CreateLoadBalancer, https response error StatusCode: 403, RequestID: 87ba07e5-acf8-4d38-a2b6-cad6fc8500de, api error AccessDenied: User: arn:aws:sts::856898221308:assumed-role/cluster1-cp-role/i-0ace386a51c7c9b8c is not authorized to perform: iam:CreateServiceLinkedRole on resource: arn:aws:iam::856898221308:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing because no identity-based policy allows the iam:CreateServiceLinkedRole action
  Warning  SyncLoadBalancerFailed  105s                service-controller  Error syncing load balancer: failed to ensure load balancer: operation error Elastic Load Balancing: CreateLoadBalancer, https response error StatusCode: 403, RequestID: 4afb10b6-7f5e-4b2b-9082-1c3a5641ff76, api error AccessDenied: User: arn:aws:sts::856898221308:assumed-role/cluster1-cp-role/i-0ace386a51c7c9b8c is not authorized to perform: iam:CreateServiceLinkedRole on resource: arn:aws:iam::856898221308:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing because no identity-based policy allows the iam:CreateServiceLinkedRole action
  Warning  SyncLoadBalancerFailed  95s                 service-controller  Error syncing load balancer: failed to ensure load balancer: operation error Elastic Load Balancing: CreateLoadBalancer, https response error StatusCode: 403, RequestID: d495edb9-17c2-4342-97d1-62b41e57b855, api error AccessDenied: User: arn:aws:sts::856898221308:assumed-role/cluster1-cp-role/i-0ace386a51c7c9b8c is not authorized to perform: iam:CreateServiceLinkedRole on resource: arn:aws:iam::856898221308:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing because no identity-based policy allows the iam:CreateServiceLinkedRole action
  Warning  SyncLoadBalancerFailed  75s                 service-controller  Error syncing load balancer: failed to ensure load balancer: operation error Elastic Load Balancing: CreateLoadBalancer, https response error StatusCode: 403, RequestID: 04c7ad45-6129-4e14-8b4f-b45b68f6c036, api error AccessDenied: User: arn:aws:sts::856898221308:assumed-role/cluster1-cp-role/i-0ace386a51c7c9b8c is not authorized to perform: iam:CreateServiceLinkedRole on resource: arn:aws:iam::856898221308:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing because no identity-based policy allows the iam:CreateServiceLinkedRole action
  Normal   EnsuringLoadBalancer    35s (x5 over 116s)  service-controller  Ensuring load balancer
  Warning  SyncLoadBalancerFailed  34s                 service-controller  Error syncing load balancer: failed to ensure load balancer: operation error Elastic Load Balancing: CreateLoadBalancer, https response error StatusCode: 403, RequestID: c6e2aa49-ff4a-43a7-ba23-4d3f94be1a33, api error AccessDenied: User: arn:aws:sts::856898221308:assumed-role/cluster1-cp-role/i-0ace386a51c7c9b8c is not authorized to perform: iam:CreateServiceLinkedRole on resource: arn:aws:iam::856898221308:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing because no identity-based policy allows the iam:CreateServiceLinkedRole action

