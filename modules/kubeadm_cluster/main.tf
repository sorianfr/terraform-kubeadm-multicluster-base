# Kubeadm cluster module

# Obtener última AMI de Packer
data "aws_ami" "k8s_base" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "name"
    values = ["k8s-base-*"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Private Subnet
resource "aws_subnet" "k8s_private_subnet" {
  vpc_id                  = var.vpc_id
  cidr_block              = var.private_subnet_cidr_block
  map_public_ip_on_launch = false
  availability_zone       = var.availability_zone

  tags = {
    Name                                 = "${var.name}_private_subnet"
    "kubernetes.io/cluster/${var.name}" = "owned"
    "kubernetes.io/role/internal-elb"   = "1"
  }
}


# Associate Private Subnet with Private Route Table
resource "aws_route_table_association" "private_rta" {
  subnet_id      = aws_subnet.k8s_private_subnet.id
  route_table_id = var.private_route_table_id
}

locals {
  sg_name = "k8s_sg_${var.name}"

  aws_ccm_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      # --- EC2 required permissions ---
      {
        Effect = "Allow",
        Action = [
          "ec2:AllocateAddress",
          "ec2:AssociateAddress",
          "ec2:AssociateRouteTable",
          "ec2:AssociateSubnetCidrBlock",
          "ec2:AssociateVpcCidrBlock",
          "ec2:AttachInternetGateway",
          "ec2:AttachNetworkInterface",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateInternetGateway",
          "ec2:CreateNatGateway",
          "ec2:CreateRoute",
          "ec2:CreateRouteTable",
          "ec2:CreateSecurityGroup",
          "ec2:CreateSubnet",
          "ec2:CreateTags",
          "ec2:CreateVolume",
          "ec2:CreateVpcEndpoint",
          "ec2:DeleteRoute",
          "ec2:DeleteSecurityGroup",
          "ec2:DeleteTags",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeRegions",
          "ec2:DescribeRouteTables",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcEndpoints",
          "ec2:DescribeVpcEndpointServices",
          "ec2:DescribeInstanceAttribute",
          "ec2:DescribeNetworkInterfaceAttribute",
          "ec2:DisassociateAddress",
          "ec2:DetachNetworkInterface",
          "ec2:ModifyInstanceAttribute",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:UnassignPrivateIpAddresses"
        ],
        Resource = "*"
      },

      # --- AutoScaling (required for Cluster Autoscaler) ---
      {
        Effect = "Allow",
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeLaunchTemplates",
          "autoscaling:DescribeTags",

          # REQUIRED for Kubernetes Cluster Autoscaler
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "autoscaling:UpdateAutoScalingGroup",

          # RECOMMENDED
          "autoscaling:CompleteLifecycleAction",
          "autoscaling:PutLifecycleHook",
          "autoscaling:DescribeScalingActivities"
        ],
        Resource = "*"
      },


      # --- Elastic Load Balancing (ALB + CLB) ---
      {
        Effect = "Allow",
        Action = [
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
          "elasticloadbalancing:AttachLoadBalancerToSubnets",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateLoadBalancerListeners",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:Describe*",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:SetLoadBalancerPoliciesOfListener",
          "elasticloadbalancing:ConfigureHealthCheck"   # <-- ESTA ES LA QUE FALTABA

        ],
        Resource = "*"
      },
      # Allow creating the ELB service-linked role (one-time)
      {
        Effect   = "Allow"
        Action   = [
          "iam:CreateServiceLinkedRole",
          "iam:GetRole"              # (optional) CCM may check if it exists
        ]
        Resource = "arn:aws:iam::*:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Security Group
resource "aws_security_group" "k8s_sg" {
  name        = local.sg_name
  vpc_id = var.vpc_id


  #############################################################
  # 1. SSH
  #############################################################
  ingress {
    description = "SSH desde bastion"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    security_groups = [var.public_sg_id]
  }

  #############################################################
  # 2. Kubernetes API (master)
  #############################################################
  ingress {
    description = "Kubernetes API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    description = "Allow pod-to-node traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.pod_cidr] # your pod CIDR
}

  #############################################################
  # 3. TODO el tráfico nodo-a-nodo dentro del cluster
  #############################################################
  ingress {
    description = "Allow all cluster internal traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  #############################################################
  # 4. Kubelet
  #############################################################
  ingress {
    description = "Kubelet API"
    from_port   = 10250
    to_port     = 10250
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  #############################################################
  # 5. Calico BGP / VXLAN / IPIP
  #############################################################
  ingress {
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    description = "Calico BGP"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    description = "Calico VXLAN"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "4"
    description = "Calico IP-in-IP"
    cidr_blocks = [var.vpc_cidr_block]
  }

  #############################################################
  # 6. NodePort
  #############################################################
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    description = "NodePort range"
    cidr_blocks = [var.vpc_cidr_block]
  }

  #############################################################
  # 7. ETCD (solo CP)
  #############################################################
  ingress {
    description = "etcd"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    cidr_blocks = ["${var.controlplane_private_ip}/32"]
  }

  #############################################################
  # 8. Scheduler / Controller Manager
  #############################################################
  ingress {
    from_port   = 10257
    to_port     = 10257
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    from_port   = 10259
    to_port     = 10259
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  #############################################################
  # 9. === ISTIO SINGLE-CLUSTER PORTS ===
  #############################################################

  # istiod XDS (Envoy → Istiod)
  ingress {
    from_port   = 15010
    to_port     = 15010
    protocol    = "tcp"
    description = "istiod XDS (plaintext, inside cluster only)"
    cidr_blocks = [var.vpc_cidr_block]
  }

  # istiod XDS secure
  ingress {
    from_port   = 15012
    to_port     = 15012
    protocol    = "tcp"
    description = "istiod XDS mTLS"
    cidr_blocks = [var.vpc_cidr_block]
  }

  # istiod webhook injection
  ingress {
    from_port   = 15017
    to_port     = 15017
    protocol    = "tcp"
    description = "istiod webhook for sidecar injection"
    cidr_blocks = [var.vpc_cidr_block]
  }

  # Istio gateway status / health
  ingress {
    from_port   = 15021
    to_port     = 15021
    protocol    = "tcp"
    description = "Istio health checks"
    cidr_blocks = [var.vpc_cidr_block]
  }

  # East-West Gateway (if using gateway inside cluster)
  ingress {
    from_port   = 15443
    to_port     = 15443
    protocol    = "tcp"
    description = "Istio mTLS in-cluster"
    cidr_blocks = [var.vpc_cidr_block]
  }

  ingress {
    from_port   = 31400
    to_port     = 31400
    protocol    = "tcp"
    description = "Istio SNI routing in-cluster"
    cidr_blocks = [var.vpc_cidr_block]
  }

  #############################################################
  # 10. EGRESS
  #############################################################
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                 = "k8s_sg"
    "kubernetes.io/cluster/${var.name}" = "owned"
  }
}

resource "aws_security_group_rule" "ssh_within_group" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.k8s_sg.id
  source_security_group_id = aws_security_group.k8s_sg.id
  description              = "Allow SSH within the security group"
}





# Control-plane IAM role
resource "aws_iam_role" "cp_role" {
  name               = "${var.name}-cp-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "cp_profile" {
  name = "${var.name}-cp-profile"
  role = aws_iam_role.cp_role.name
}

resource "aws_iam_role_policy" "cp_secrets" {
  role = aws_iam_role.cp_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = [
        "secretsmanager:CreateSecret",
        "secretsmanager:PutSecretValue",
        "secretsmanager:UpdateSecret",
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
        "secretsmanager:ListSecrets"
      ],
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name}/comando-unir*"
    }]
  })
}

resource "aws_iam_role_policy" "cp_aws_ccm" {
  role   = aws_iam_role.cp_role.id
  policy = local.aws_ccm_policy
}

# Worker IAM role
resource "aws_iam_role" "worker_role" {
  name               = "${var.name}-worker-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_instance_profile" "worker_profile" {
  name = "${var.name}-worker-profile"
  role = aws_iam_role.worker_role.name
}

resource "aws_iam_role_policy" "worker_secrets" {
  role = aws_iam_role.worker_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      Resource = "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name}/comando-unir*"
    }]
  })
}

resource "aws_iam_role_policy" "worker_aws_ccm" {
  role   = aws_iam_role.worker_role.id
  policy = local.aws_ccm_policy
}

resource "aws_iam_policy" "ccm_policy" {
  name   = "${var.name}-aws-ccm-policy"
  policy = local.aws_ccm_policy
}

resource "aws_iam_role_policy_attachment" "worker_ccm_attach" {
  role       = aws_iam_role.worker_role.name
  policy_arn = aws_iam_policy.ccm_policy.arn
}

resource "aws_iam_role_policy_attachment" "cp_ccm_attach" {
  role       = aws_iam_role.cp_role.name
  policy_arn = aws_iam_policy.ccm_policy.arn
}

resource "aws_iam_role_policy_attachment" "worker_ebs_csi" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "cp_ebs_csi" {
  role       = aws_iam_role.cp_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}




# Attach the AmazonSSMManagedInstanceCore policy for SSM connectivity
resource "aws_iam_role_policy_attachment" "worker_ssm_core" {
  role       = aws_iam_role.worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_secretsmanager_secret" "join_command" {
  name        = "${var.name}/comando-unir"
  description = "Join command for Kubernetes workers in ${var.name}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "join_command_placeholder" {
  secret_id     = aws_secretsmanager_secret.join_command.id
  secret_string = "waiting-for-controlplane"
}



# Control plane instance
resource "aws_instance" "control_plane" {
  ami                    = data.aws_ami.k8s_base.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.k8s_private_subnet.id
  vpc_security_group_ids = [aws_security_group.k8s_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.cp_profile.name
  key_name               = var.key_name
  private_ip             = var.controlplane_private_ip

  # === NEW ROOT DISK CONFIG ===
  root_block_device {
    volume_size = 80
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/templates/control_plane_userdata.sh.tpl", {
    cluster_name            = var.name
    pod_cidr                = var.pod_cidr
    service_cidr            = var.service_cidr
    controlplane_private_ip = var.controlplane_private_ip
    region                  = var.region
    enable_aws_ccm          = var.enable_aws_ccm
  })

  source_dest_check = false # Disable Source/Destination Check

  tags = {
    Name                                 = "${var.name}-control-plane"
    "kubernetes.io/cluster/${var.name}" = "owned"
  }

}

output "control_plane_userdata" {
  value = templatefile("${path.module}/templates/control_plane_userdata.sh.tpl", {
    cluster_name            = var.name
    pod_cidr                = var.pod_cidr
    service_cidr            = var.service_cidr
    controlplane_private_ip = var.controlplane_private_ip
    region                  = var.region
    enable_aws_ccm          = var.enable_aws_ccm
  })
}

# Worker launch template
# Worker launch template
resource "aws_launch_template" "worker_lt" {
  name_prefix   = "${var.name}-worker-"
  image_id      = data.aws_ami.k8s_base.id
  instance_type = var.instance_type

  
  # === NEW ROOT DISK CONFIG ===
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 80
      volume_type = "gp3"
      delete_on_termination = true
    }
  }
  

  # Disable inherited ephemeral disk /dev/sdb
  block_device_mappings {
    device_name = "/dev/sdb"
    no_device   = true
  }

  # Disable inherited ephemeral disk /dev/sdc
  block_device_mappings {
    device_name = "/dev/sdc"
    no_device   = true
  }

  iam_instance_profile { 
    name = aws_iam_instance_profile.worker_profile.name 
  }

  # OPTIONAL: allow SSH access if you want it later
  key_name = var.key_name

  vpc_security_group_ids = [aws_security_group.k8s_sg.id]


  # Required for SSM connectivity + security best practices
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name                             = "${var.name}-worker"
      "kubernetes.io/cluster/${var.name}" = "owned"
      Cluster                          = var.name
      Role                             = "worker"
      # Required for AWS SSM
      "aws:ec2launchtemplate:instancetag/SSM" = "enabled"
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/worker_userdata.sh.tpl", {
    cluster_name            = var.name
    region                  = var.region
    controlplane_private_ip = var.controlplane_private_ip
    enable_aws_ccm          = var.enable_aws_ccm
  }))

  depends_on = [
    aws_instance.control_plane,
    aws_iam_role.worker_role,
    aws_iam_instance_profile.worker_profile,
    aws_iam_role_policy.worker_secrets,
    aws_iam_role_policy_attachment.worker_ssm_core
  ]
}
    # aws_iam_role_policy.worker_aws_ccm,


# Worker ASG
resource "aws_autoscaling_group" "workers" {
  name                = "${var.name}-workers"
  desired_capacity    = var.worker_desired
  min_size            = var.worker_min
  max_size            = var.worker_max
  vpc_zone_identifier = [aws_subnet.k8s_private_subnet.id]
  health_check_type         = "EC2"
  health_check_grace_period = 300
  wait_for_capacity_timeout = "10m"



  launch_template {
    id      = aws_launch_template.worker_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-worker"
    propagate_at_launch = true
  }
  tag {
    key                 = "kubernetes.io/cluster/${var.name}"
    value               = "owned"
    propagate_at_launch = true
  }
  tag {
    key                 = "Cluster"
    value               = var.name
    propagate_at_launch = true
  }

  tag {
    key                 = "Role"
    value               = "worker"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.name}"
    value               = "owned"
    propagate_at_launch = true
  }
  

}

output "controlplane_private_ip" {
  description = "Private IP of the cluster control plane instance"
  value       = var.controlplane_private_ip
}