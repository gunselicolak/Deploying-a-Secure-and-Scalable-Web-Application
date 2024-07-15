terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "5.19.0"
    }
  }
  backend "gcs" {
    bucket = "bucket-from-tfstate"
    prefix = "terraform/state"
  }
}

provider "google" {
  project = var.project_name
  region = var.region
  zone = " europe-west1-d"
  credentials = file("securescalablewebapplication-keys.json")
}