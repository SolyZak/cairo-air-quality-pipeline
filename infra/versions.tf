terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # State is kept locally and gitignored.
  #
  # The "correct" answer is an S3 backend with a DynamoDB lock table, and on a
  # team it would be. It is omitted here on purpose: it creates a bootstrap
  # chicken-and-egg (Terraform needs a bucket that Terraform has not made yet),
  # and its whole value is coordinating concurrent applies between people.
  # There is one person and one machine. Local state is the honest choice --
  # and losing it is recoverable, because `terraform import` exists and the
  # whole estate is six resources.
}

provider "aws" {
  region = var.region

  default_tags {
    # Every resource gets these. Without them, an AWS bill is a list of
    # anonymous line items and you cannot tell which project spent what.
    tags = {
      Project     = "cairo-air-quality-pipeline"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}
