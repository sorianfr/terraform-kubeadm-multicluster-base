ISTIOCTL INSTALL FROM GUIDE
curl -L https://istio.io/downloadIstio | sh -
cd istio-1.28.0
export PATH=$PWD/bin:$PATH














istioctl install with cli
curl -sL https://istio.io/downloadIstioctl | ISTIO_VERSION=1.26.0 sh -
sudo install -m 755 ~/.istioctl/bin/istioctl /usr/local/bin/istioctl

Install Istio with the demo profile.


istioctl analyze

istioctl analyze
Info [IST0102] (Namespace default) The namespace is not enabled for Istio injection. Run 'kubectl label namespace default istio-injection=enabled' to enable it, or 'kubectl label namespace default istio-injection=disabled' to explicitly mark it as not needing injection.

kubectl get ns --show-labels

kubectl label namespace default istio-injection=enabled 












REMOVING LOADBALANCER AND ENIS

Why these ENIs exist

All your ENIs show:

Requester ID: amazon-elb
Description: ELB a2a7ccf0315224fb584e613e35f813eb
Requester-managed: True


That means they are owned by AWS Elastic Load Balancers created by Kubernetes for:

Istio IngressGateway

Istio Service Type = LoadBalancer

Annotations that provision an NLB or Classic ELB

AWS will not allow you to delete the ENIs manually because the ELB needs them.


STEP 1 — Delete those two load balancers

Select → Actions → Delete

AWS will automatically:

Detach ENIs

Delete ENIs

Release IPs

If the ENIs still won't delete

If AWS still blocks deletion after deleting the ELBs:

1. Open the ENI in the console
2. Click: Actions → Detach

(If detach is greyed out, the ELB still exists → go back and delete it).

3. After detaching, click: Actions → Delete

It will work once the load balancer is gone.