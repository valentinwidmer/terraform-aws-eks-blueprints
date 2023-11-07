provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

data "aws_availability_zones" "available" {}

locals {
  name   = basename(path.cwd)
  region = "us-west-2"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.16"

  cluster_name                   = local.name
  cluster_version                = "1.28"
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_groups = {
    initial = {
      instance_types = ["m5.large"]

      min_size     = 3
      max_size     = 10
      desired_size = 5
    }
  }

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# IAM Roles for Service Accounts
################################################################################

module "gateway_api_controller_irsa" {
  source = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"

  role_name                            = "gateway-api-controller"
  attach_aws_gateway_controller_policy = true


  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["gateway-api-controller:aws-application-networking-system"]
    }
  }

  tags = local.tags
}

################################################################################
# EKS Addons (gateway api controller and demo apps)
################################################################################

module "addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.0"

  cluster_name      = module.eks.cluster_name
  cluster_endpoint  = module.eks.cluster_endpoint
  cluster_version   = module.eks.cluster_version
  oidc_provider_arn = module.eks.oidc_provider_arn

  # EKS Addons
  eks_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
  }

  # Deploy demo-application
  helm_releases = {
    aws-gateway-controller = {
      name       = "aws-gateway-controller"
      repository = "oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart"
      namespace  = "aws-application-networking-system"
      chart      = "gateway-api-controller"
      version    = "v0.0.17"

      set = [
        {
          name  = "serviceAccount.create"
          value = "false"
        }
      ]
    }

    checkout = {
      description = "A Helm chart to deploy the checkout demo microservice"
      namespace   = "default"
      chart       = "./charts/checkout"
    }

    checkout-v2 = {
      description = "A Helm chart to deploy the checkout v2 demo microservice"
      namespace   = "default"
      chart       = "./charts/checkout-v2"
    }
  }

  tags = local.tags
}

################################################################################
# Restrict traffic flow using Network Policies
################################################################################

# Block all ingress and egress traffic within the stars namespace
resource "kubernetes_network_policy_v1" "default_deny_stars" {
  metadata {
    name      = "default-deny"
    namespace = "stars"
  }
  spec {
    policy_types = ["Ingress"]
    pod_selector {
      match_labels = {}
    }
  }
  depends_on = [module.addons]
}

# Block all ingress and egress traffic within the client namespace
resource "kubernetes_network_policy_v1" "default_deny_client" {
  metadata {
    name      = "default-deny"
    namespace = "client"
  }
  spec {
    policy_types = ["Ingress"]
    pod_selector {
      match_labels = {}
    }
  }
  depends_on = [module.addons]
}

# Allow the management-ui to access the star application pods
resource "kubernetes_network_policy_v1" "allow_ui_to_stars" {
  metadata {
    name      = "allow-ui"
    namespace = "stars"
  }
  spec {
    policy_types = ["Ingress"]
    pod_selector {
      match_labels = {}
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            role = "management-ui"
          }
        }
      }
    }
  }
  depends_on = [module.addons]
}

# Allow the management-ui to access the client application pods
resource "kubernetes_network_policy_v1" "allow_ui_to_client" {
  metadata {
    name      = "allow-ui"
    namespace = "client"
  }
  spec {
    policy_types = ["Ingress"]
    pod_selector {
      match_labels = {}
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            role = "management-ui"
          }
        }
      }
    }
  }
  depends_on = [module.addons]
}

# Allow the frontend pod to access the backend pod within the stars namespace
resource "kubernetes_network_policy_v1" "allow_frontend_to_backend" {
  metadata {
    name      = "backend-policy"
    namespace = "stars"
  }
  spec {
    policy_types = ["Ingress"]
    pod_selector {
      match_labels = {
        role = "backend"
      }
    }
    ingress {
      from {
        pod_selector {
          match_labels = {
            role = "frontend"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "6379"
      }
    }
  }
  depends_on = [module.addons]
}

# Allow the client pod to access the frontend pod within the stars namespace
resource "kubernetes_network_policy_v1" "allow_client_to_backend" {
  metadata {
    name      = "frontend-policy"
    namespace = "stars"
  }

  spec {
    policy_types = ["Ingress"]
    pod_selector {
      match_labels = {
        role = "frontend"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            role = "client"
          }
        }
      }
      ports {
        protocol = "TCP"
        port     = "80"
      }
    }
  }
  depends_on = [module.addons]
}
