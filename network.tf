resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-igw" }
}

# A single public subnet keeps the setup NAT-free (no NAT Gateway cost). Database and
# Redis hosts receive an auto-assigned public IP for outbound package downloads only;
# their security groups accept no traffic from the internet.
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnet_cidr
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
