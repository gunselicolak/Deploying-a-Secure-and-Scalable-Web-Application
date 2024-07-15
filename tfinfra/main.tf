# Create a VPC network
resource "google_compute_network" "vpc-network" {
  provider = google
  project = var.project_name
  name = "vpcnetwork"
  # RESOURCE properties go here
  auto_create_subnetworks = "false"
}

# Create a subnet in the VPC you created. (Region : europe-west1)
resource "google_compute_subnetwork" "vpc-network-subnet" {
  provider = google
  name          = "vpc-network-subnet"
  ip_cidr_range = "10.10.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc-network.id
}

# Configure proxy subnet in europe-west1 region 
resource "google_compute_subnetwork" "proxy-vpc-network-subnet" {
  provider = google
  ip_cidr_range = "10.129.0.0/23"
  name = "proxy-only-subnet1"
  network = google_compute_network.vpc-network.id
  purpose = "GLOBAL_MANAGED_PROXY"
  region = var.region
  role = "ACTIVE"
}

# Create a Cloud Router in the network you created and create a NAT Gateway.
## Create Cloud Router
resource "google_compute_router" "router" {
  project = var.project_name
  name    = "nat-router"
  network = "vpc-network"
  region  = var.region
}

## Create Nat Gateway
resource "google_compute_router_nat" "nat" {
  name                               = "my-router-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
  
  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

/*
Create an Instance template in the subnet you created.
Instance type : e2-micro
Boot disk: debian-11
Startup-script: Apache2 or nginx web server installation and a simple welcome
Add the startup script that creates the index.html file containing the text.
*/
resource "google_compute_instance_template" "my-vm" {
  project      = var.project_name
  name         = "instance-template"
  machine_type = "e2-micro"
  
  disk {
      source_image = "debian-cloud/debian-11"
  }
  
  network_interface {
    network    = google_compute_network.vpc-network.id
    subnetwork = google_compute_subnetwork.vpc-network-subnet.id
    access_config {
      # add internal ip to fetch packages
    }
  }
  
  # install nginx and serve a simple web page
  metadata_startup_script = file("apache2.sh")

  scheduling {
        preemptible = true
        automatic_restart = false
  }

  lifecycle {
    create_before_destroy = true
  }
}

/*
Create a Managed Instance Group using the template you created.
The configuration that the Managed Instance Group to be created must have
settings:
It should not be a public IP address.
Must access the internet via NAT Gateway.
Instance zone : europe-west1-d
*/
resource "google_compute_instance_group_manager" "my-vm" {
  name = "mig-mananger"
  zone = "europe-west1-d"
  base_instance_name = "mig-instance"

  version {
    instance_template = google_compute_instance_template.my-vm.self_link_unique
  }
  target_size = 3
  wait_for_instances = true

  named_port {
    name = "http"
    port = 80
  }

  lifecycle {
  create_before_destroy = true
  }
}

/*
Create autoscaler.
Target CPU utilization: 50%
*/
resource "google_compute_autoscaler" "my-vm" {
  name   = "my-autoscaler"
  project = var.project_name
  zone   = "europe-west1-d"
  target = google_compute_instance_group_manager.my-vm.self_link

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.5
    }
  }
}

#Create a load balancer in front of the instances you created.
# A gloabal HTTP health check.
resource "google_compute_health_check" "default" {
  provider = google
  project     = var.project_name
  name     = "global-http-health-check"

  timeout_sec        = 1
  check_interval_sec = 1
  unhealthy_threshold = 2
  healthy_threshold = 2

  http_health_check {
    port_specification = "USE_SERVING_PORT"
  }
}

#A global backend service with the managed instance groups as the backend.
resource "google_compute_backend_service" "default" {
  name                    = "lb-backend-service"
  provider                = google
  project     = var.project_name
  protocol                = "HTTP"
  load_balancing_scheme   = "INTERNAL_MANAGED"
  timeout_sec             = 10
  health_checks           = [google_compute_health_check.default.id]
  backend {
    group           = google_compute_instance_group_manager.my-vm.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}

# URL Map
resource "google_compute_url_map" "default" {
  name            = "lb-url-map"
  provider        = google
  project     = var.project_name
  default_service = google_compute_backend_service.default.id
}

#A global target http proxy.
resource "google_compute_target_http_proxy" "default" {
  name     = "lb-target-http-proxy"
  provider = google
  url_map  = google_compute_url_map.default.id
}

# reserved IP address
resource "google_compute_global_address" "default" {
  provider = google-beta
  project     = var.project_name
  name     = "static-ip"
}

# forwarding rule
resource "google_compute_global_forwarding_rule" "default" {
  # depends_on = [google_compute_subnetwork.proxy-vpc-network-subnet]
  # ip_address = "10.10.99.99"
  name                  = "lb-forwarding-rule"  
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_target_http_proxy.default.id
  ip_address = google_compute_global_address.default.id
  # subnetwork = google_compute_subnetwork.vpc-network-subnet.id
}


#Firewall Rules

#An ingress rule, applicable to the instances being load balanced, that allows all TCP traffic from the Google Cloud health checking systems (in 130.211.0.0/22 and 35.191.0.0/16). 
resource "google_compute_firewall" "fw_healthcheck" {
  name          = "lb-fw-allow-hc"
  provider      = google
  direction     = "INGRESS"
  network       = google_compute_network.vpc-network.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16", "35.235.240.0/20"]
  allow {
    protocol = "tcp"
  }
}

# An ingress rule, applicable to the instances being load balanced, that allows incoming SSH connectivity on TCP port 22 from any address.
resource "google_compute_firewall" "fw_lb_to_backends" {
  name          = "fw-lb-to-fw"
  provider      = google
  network       = google_compute_network.vpc-network.id
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "8080"]
  }
}

# An ingress rule, applicable to the instances being load balanced, that allows TCP traffic on ports 80, 443, and 8080 from the internal Application Load Balancer's managed proxies.
resource "google_compute_firewall" "fw_backends" {
  name          = "lb-fw-allow-lb-to-backends"
  direction     = "INGRESS"
  network       = google_compute_network.vpc-network.id
  source_ranges = ["10.129.0.0/23", "10.130.0.0/23"]
  target_tags   = ["http-server"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }
}

resource "google_storage_bucket" "gsc" {
  name          = "bucket-from-tfstate"
  force_destroy = false
  location      = "europe-west1"
  storage_class = "STANDARD"
  versioning {
    enabled = true
  }
}