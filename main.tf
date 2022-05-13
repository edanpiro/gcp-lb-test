terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.20.0"
    }
  }
}

provider "google" {
  credentials = file(var.filecredential)
  project     = var.project
  region      = var.region
  zone        = var.zone
}

resource "google_compute_forwarding_rule" "default" {
  provider              = google-beta
  depends_on            = [google_compute_subnetwork.proxy]
  name                  = "website-forwarding-rule"
  region                = var.region
  project               = var.project

  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "80"
  target                = google_compute_region_target_http_proxy.default.id
  network               = google_compute_network.default.id
  ip_address            = google_compute_address.default.id
  network_tier          = "STANDARD"
}

resource "google_compute_region_target_http_proxy" "default" {
  provider = google-beta
  region   = var.region
  project  = var.project
  name     = "website-proxy"
  url_map  = google_compute_region_url_map.default.id
}

resource "google_compute_region_url_map" "default" {
  provider        = google-beta
  region          = var.region
  project         = var.project
  name            = "website-map"
  default_service = google_compute_region_backend_service.default.id
}

resource "google_compute_region_backend_service" "default" {
  provider              = google-beta
  project               = var.project
  load_balancing_scheme = "EXTERNAL_MANAGED"

  backend {
    group           = google_compute_instance_group_manager.rigm.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  region                = var.region
  name                  = "website-backend"
  protocol              = "HTTP"
  timeout_sec           = 10

  health_checks         = [google_compute_region_health_check.default.id]
}

resource "google_compute_autoscaler" "autoscaler" {
  name   = "autoscaler-test"
  zone   = var.zone
  target = google_compute_instance_group_manager.rigm.id

  autoscaling_policy {
    max_replicas    = 4
    min_replicas    = 2
    cooldown_period = 60

    cpu_utilization {
      target = 0.4
    }
  }
}

data "google_compute_image" "debian_image" {
  provider = google-beta
  family   = "debian-10"
  project  = "debian-cloud"
}

resource "google_compute_instance_group_manager" "rigm" {
  provider           = google-beta
  zone               = var.zone
  name               = "website-rigm"
  project            = var.project
  base_instance_name = "vm"
  #target_size        = 1

  version {
    instance_template = google_compute_instance_template.instance_template.id
    name              = "primary"
  }

  named_port {
    name = "http"
    port = 80
  }
}

resource "google_compute_instance_template" "instance_template" {
  provider     = google-beta
  name         = "template-website-backend"
  machine_type = "e2-medium"
  project      = var.project

  network_interface {
    network    = google_compute_network.default.id
    subnetwork = google_compute_subnetwork.default.id
  }

  disk {
    source_image = data.google_compute_image.debian_image.self_link
    auto_delete  = true
    boot         = true
  }

  tags = ["allow-ssh", "load-balanced-backend"]

  metadata = {
    startup-script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y nginx-light jq

      NAME=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/hostname")
      IP=$(curl -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip")

      cat <<EOF > /var/www/html/index.html
      <pre>
      Name: $NAME
      IP: $IP
      </pre>
      EOF
    EOF1
  }
}

resource "google_compute_region_health_check" "default" {
  depends_on  = [google_compute_firewall.fw4]
  provider    = google-beta
  project     = var.project
  region      = var.region
  name        = "website-hc"

  http_health_check {
    port = "80"
  }
}

resource "google_compute_address" "default" {
  name         = "website-ip-1"
  provider     = google-beta
  region       = var.region
  project      = var.project
  network_tier = "STANDARD"
}

resource "google_compute_firewall" "fw1" {
  provider      = google-beta
  name          = "website-fw-1"
  project       = var.project
  network       = google_compute_network.default.id
  source_ranges = ["10.1.2.0/24"]
  direction = "INGRESS"

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}

resource "google_compute_firewall" "fw2" {
  depends_on    = [google_compute_firewall.fw1]
  provider      = google-beta
  name          = "website-fw-2"
  project       = var.project
  network       = google_compute_network.default.id
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["allow-ssh"]
  direction     = "INGRESS"

  allow {
    protocol = "tcp"
    ports = ["22"]
  }
}

resource "google_compute_firewall" "fw3" {
  depends_on    = [google_compute_firewall.fw2]
  provider      = google-beta
  name          = "website-fw-3"
  project       = var.project
  network       = google_compute_network.default.id
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["load-balanced-backend"]
  direction     = "INGRESS"

  allow {
    protocol = "tcp"
  }
}

resource "google_compute_firewall" "fw4" {
  depends_on     = [google_compute_firewall.fw3]
  provider       = google-beta
  name           = "website-fw-4"
  project        = var.project
  network        = google_compute_network.default.id
  source_ranges  = ["10.129.0.0/26"]
  target_tags    = ["load-balanced-backend"]
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports = ["80"]
  }
}

resource "google_compute_network" "default" {
  provider                = google-beta
  name                    = "website-net"
  project                 = var.project
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_router_nat" "nat" {
  name                               = "test-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_router" "router" {
  name    = "my-router"
  region  = var.region
  network = google_compute_network.default.id

  bgp {
    asn = 64514
  }
}

resource "google_compute_subnetwork" "default" {
  provider      = google-beta
  name          = "website-net-default"
  project       = var.project
  ip_cidr_range = "10.1.2.0/24"
  region        = var.region
  network       = google_compute_network.default.id
}

resource "google_compute_subnetwork" "proxy" {
  provider      = google-beta
  name          = "website-net-proxy"
  project       = var.project
  ip_cidr_range = "10.129.0.0/26"
  region        = var.region
  network       = google_compute_network.default.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}
