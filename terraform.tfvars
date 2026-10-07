clusters = [
  {
    name                       = "cluster1"
    private_subnet_cidr_block  = "10.0.2.0/24"
    controlplane_private_ip    = "10.0.2.10"
    instance_type              = "c7i-flex.large"
    worker_min                 = 2
    worker_max                 = 4
    worker_desired             = 2
    pod_cidr                   = "10.244.0.0/16"
    service_cidr               = "10.96.0.0/16"
    network                    = "network1"

    enable_aws_ccm             = true
  }
]
